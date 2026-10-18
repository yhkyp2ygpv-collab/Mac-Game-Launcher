// The game's file reads — see anvil_io.h.
//
// Interposed: pread and read (what Wine's NtReadFile comes down to), and close and dup2 (so a descriptor
// number used again for another file is looked at afresh). Each descriptor is looked at once, with fstat:
// a pipe or a socket — the wineserver's requests among them — is passed straight through from then on,
// with nothing but a table read added; a regular file's reads are timed; and in a file of 64 MB or more
// (LEGO Star Wars keeps its 38 GB in nine archives of up to 4.3 GB) the 4 MB pieces each read lands in are
// counted, for the memory warm-up.
#include "anvil_io.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <mutex>
#include <os/lock.h>
#include <string>
#include <sys/param.h>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

constexpr int kFds = 8192;
constexpr int kFiles = 64;
constexpr uint64_t kChunk = 4ull << 20;
constexpr off_t kBigFile = 64ll << 20;
// A descriptor's kind: 0 not looked at yet, 1 not a regular file (passed through), 2 a regular file,
// 3 + n a large one, file n below.
std::atomic<int32_t> g_fdKind[kFds];

struct File {
    std::atomic<bool> used{false};
    dev_t dev = 0;
    ino_t ino = 0;
    off_t size = 0;
    char path[MAXPATHLEN] = {0};
    uint32_t chunks = 0;
    std::atomic<uint32_t>* heat = nullptr;   // reads landing in each piece, this session
};
File g_files[kFiles];
// Locks with nothing to tear down: the save runs at the game's exit too (an atexit handler), after the C++
// objects made since start have been destroyed — a std::mutex there was already gone, and locking it threw
// as the stand-in quit (14 October).
os_unfair_lock g_filesLock = OS_UNFAIR_LOCK_INIT;   // taken only to add a file
os_unfair_lock g_saveLock = OS_UNFAIR_LOCK_INIT;
std::atomic<uint64_t> g_calls{0}, g_bytes{0}, g_ns{0}, g_slow{0}, g_heatReads{0};
uint64_t g_heatSaved = 0;                     // g_heatReads at the last save (the saver's)

double nsPerTick() {
    static const double r = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return (double)t.numer / t.denom; }();
    return r;
}

struct Unfair {
    os_unfair_lock* l;
    explicit Unfair(os_unfair_lock* lock) : l(lock) { os_unfair_lock_lock(l); }
    ~Unfair() { os_unfair_lock_unlock(l); }
};

int registerFile(int fd, const struct stat& st) {
    Unfair h(&g_filesLock);
    for (int i = 0; i < kFiles; ++i)
        if (g_files[i].used.load(std::memory_order_acquire) && g_files[i].dev == st.st_dev && g_files[i].ino == st.st_ino) return 3 + i;
    for (int i = 0; i < kFiles; ++i) {
        File& f = g_files[i];
        if (f.used.load(std::memory_order_acquire)) continue;
        char path[MAXPATHLEN];
        if (fcntl(fd, F_GETPATH, path) == -1) return 2;
        const uint32_t chunks = (uint32_t)((st.st_size + kChunk - 1) / kChunk);
        auto* heat = static_cast<std::atomic<uint32_t>*>(calloc(chunks, sizeof(std::atomic<uint32_t>)));
        if (!heat) return 2;
        f.dev = st.st_dev;
        f.ino = st.st_ino;
        f.size = st.st_size;
        strlcpy(f.path, path, sizeof f.path);
        f.chunks = chunks;
        f.heat = heat;
        f.used.store(true, std::memory_order_release);
        return 3 + i;
    }
    return 2;
}

int kindFor(int fd) {
    if (fd < 0 || fd >= kFds) return 1;
    int k = g_fdKind[fd].load(std::memory_order_relaxed);
    if (k != 0) return k;
    const int saved = errno;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) k = 1;
    else k = st.st_size >= kBigFile ? registerFile(fd, st) : 2;
    errno = saved;
    g_fdKind[fd].store(k, std::memory_order_relaxed);
    return k;
}

void note(int kind, off_t at, ssize_t got, uint64_t t0) {
    const uint64_t ns = (uint64_t)((mach_absolute_time() - t0) * nsPerTick());
    g_calls.fetch_add(1, std::memory_order_relaxed);
    g_ns.fetch_add(ns, std::memory_order_relaxed);
    if (ns >= 20000000) g_slow.fetch_add(1, std::memory_order_relaxed);
    if (got <= 0) return;
    g_bytes.fetch_add((uint64_t)got, std::memory_order_relaxed);
    if (kind < 3 || at < 0) return;
    File& f = g_files[kind - 3];
    const uint64_t first = (uint64_t)at / kChunk, last = ((uint64_t)at + (uint64_t)got - 1) / kChunk;
    for (uint64_t c = first; c <= last && c < f.chunks; ++c) f.heat[c].fetch_add(1, std::memory_order_relaxed);
    g_heatReads.fetch_add(1, std::memory_order_relaxed);
}

void forget(int fd) {
    if (fd >= 0 && fd < kFds) g_fdKind[fd].store(0, std::memory_order_relaxed);
}

// What earlier sessions saw, read from the state file the first time it's saved this session.
struct Prior { off_t size = 0; std::vector<std::pair<uint32_t, float>> chunks; };

std::unordered_map<std::string, Prior> readPrior(const char* path) {
    std::unordered_map<std::string, Prior> out;
    FILE* f = fopen(path, "r");
    if (!f) return out;
    char line[MAXPATHLEN + 64];
    std::string current;
    if (fgets(line, sizeof line, f) && strncmp(line, "anvil-warm 1", 12) == 0) {
        while (fgets(line, sizeof line, f)) {
            line[strcspn(line, "\n")] = 0;
            long long size = 0;
            int pathAt = 0;
            unsigned chunk = 0;
            float count = 0;
            if (sscanf(line, "file %lld %n", &size, &pathAt) == 1 && pathAt > 0) {
                current = line + pathAt;
                out[current].size = (off_t)size;
            } else if (!current.empty() && sscanf(line, "c %u %f", &chunk, &count) == 2 && count > 0 && std::isfinite(count)) {
                out[current].chunks.emplace_back(chunk, count);
            }
        }
    }
    fclose(f);
    return out;
}

}  // namespace

extern "C" void AnvilReadTotalsGet(AnvilReadTotals* out) {
    if (!out) return;
    out->calls = g_calls.load(std::memory_order_relaxed);
    out->bytes = g_bytes.load(std::memory_order_relaxed);
    out->ns = g_ns.load(std::memory_order_relaxed);
    out->slow = g_slow.load(std::memory_order_relaxed);
}

extern "C" int AnvilReadHeatSave(void) {
    const char* path = getenv("ANVIL_WARM_STATE");
    if (!path || !*path) return -1;
    Unfair h(&g_saveLock);
    const uint64_t reads = g_heatReads.load(std::memory_order_relaxed);
    if (reads == g_heatSaved) return 0;
    // Earlier sessions' counts at half their weight, this session's in full: the places played lately
    // count most, and somewhere not visited for a few sessions fades out. Read once, at the first save — the
    // file's later versions hold this session's own counts, which would be counted again.
    // Made once and never destroyed, for the same reason as the locks.
    static std::unordered_map<std::string, Prior>* earlier = nullptr;
    if (!earlier) earlier = new std::unordered_map<std::string, Prior>(readPrior(path));
    std::unordered_map<std::string, Prior> prior = *earlier;
    std::vector<std::pair<std::string, Prior>> files;
    for (int i = 0; i < kFiles; ++i) {
        File& f = g_files[i];
        if (!f.used.load(std::memory_order_acquire)) continue;
        std::vector<float> counts(f.chunks, 0.0f);
        auto it = prior.find(f.path);
        if (it != prior.end() && it->second.size == f.size)
            for (auto& [c, n] : it->second.chunks) if (c < f.chunks) counts[c] += 0.5f * n;
        if (it != prior.end()) prior.erase(it);
        for (uint32_t c = 0; c < f.chunks; ++c) counts[c] += (float)f.heat[c].load(std::memory_order_relaxed);
        Prior p;
        p.size = f.size;
        for (uint32_t c = 0; c < f.chunks; ++c) if (counts[c] >= 0.5f) p.chunks.emplace_back(c, counts[c]);
        files.emplace_back(f.path, std::move(p));
    }
    // Files not opened this session, faded.
    for (auto& [p, pr] : prior) {
        Prior q = pr;
        for (auto& [c, n] : q.chunks) n *= 0.5f;
        q.chunks.erase(std::remove_if(q.chunks.begin(), q.chunks.end(), [](auto& x) { return x.second < 0.5f; }), q.chunks.end());
        if (!q.chunks.empty()) files.emplace_back(p, std::move(q));
    }
    const std::string tmp = std::string(path) + ".new";
    FILE* out = fopen(tmp.c_str(), "w");
    if (!out) return -1;
    fprintf(out, "anvil-warm 1\n");
    int written = 0;
    for (auto& [p, pr] : files) {
        if (pr.chunks.empty()) continue;
        fprintf(out, "file %lld %s\n", (long long)pr.size, p.c_str());
        for (auto& [c, n] : pr.chunks) fprintf(out, "c %u %.1f\n", c, n);
        ++written;
    }
    const bool ok = fclose(out) == 0 && rename(tmp.c_str(), path) == 0;
    if (ok) g_heatSaved = reads;
    return ok ? written : -1;
}

// --- The interposed calls ---------------------------------------------------------------------------

extern "C" ssize_t anvil_pread(int fd, void* buf, size_t n, off_t at) {
    const int kind = kindFor(fd);
    if (kind == 1) return pread(fd, buf, n, at);
    const uint64_t t0 = mach_absolute_time();
    const ssize_t got = pread(fd, buf, n, at);
    const int saved = errno;
    note(kind, at, got, t0);
    errno = saved;
    return got;
}

extern "C" ssize_t anvil_read(int fd, void* buf, size_t n) {
    const int kind = kindFor(fd);
    if (kind == 1) return read(fd, buf, n);
    off_t at = -1;
    if (kind >= 3) {
        const int saved = errno;
        at = lseek(fd, 0, SEEK_CUR);
        errno = saved;
    }
    const uint64_t t0 = mach_absolute_time();
    const ssize_t got = read(fd, buf, n);
    const int saved = errno;
    note(kind, at, got, t0);
    errno = saved;
    return got;
}

extern "C" int anvil_close(int fd) {
    forget(fd);
    const int r = close(fd);
    const int saved = errno;
    forget(fd);
    errno = saved;
    return r;
}

extern "C" int anvil_dup2(int from, int to) {
    const int r = dup2(from, to);
    const int saved = errno;
    forget(to);
    errno = saved;
    return r;
}

#ifndef ANVIL_IO_TEST
__attribute__((used, section("__DATA,__interpose")))
static struct { const void* replacement; const void* original; } anvil_io_interposes[] = {
    {(const void*)anvil_pread, (const void*)pread},
    {(const void*)anvil_read, (const void*)read},
    {(const void*)anvil_close, (const void*)close},
    {(const void*)anvil_dup2, (const void*)dup2},
};
#endif

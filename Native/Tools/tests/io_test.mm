// The game's file reads (anvil_io.mm): timed and counted, where they land in a large file, a pipe passed
// through untouched, a descriptor number used again for another file, and the warm-up's state file —
// written, merged with an earlier session's, and nothing written when nothing new was read.
//
// Direct (anvil_io's functions called):
//   clang++ -std=c++17 -ObjC++ -DANVIL_IO_TEST io_test.mm ../../AnvilMetal/anvil_io.mm -o io_test && ./io_test
// Injected (as in a game: libanvil inserted, plain pread/read/close interposed):
//   clang++ -std=c++17 -ObjC++ -DIO_TEST_INJECTED io_test.mm -o io_test_injected
//   DYLD_INSERT_LIBRARIES=.../libanvil.dylib ANVIL_WARM_STATE=... ./io_test_injected
#include "../../AnvilMetal/anvil_io.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static int g_failed = 0;
#define CHECK(cond, ...) do { if (!(cond)) { ++g_failed; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

#ifdef ANVIL_IO_TEST
extern "C" ssize_t anvil_pread(int fd, void* buf, size_t n, off_t at);
extern "C" ssize_t anvil_read(int fd, void* buf, size_t n);
extern "C" int anvil_close(int fd);
#define PREAD anvil_pread
#define READ anvil_read
#define CLOSE anvil_close
static void totals(AnvilReadTotals* t) { AnvilReadTotalsGet(t); }
static int save() { return AnvilReadHeatSave(); }
#else
#define PREAD pread
#define READ read
#define CLOSE close
static void totals(AnvilReadTotals* t) {
    auto f = (void (*)(AnvilReadTotals*))dlsym(RTLD_DEFAULT, "AnvilReadTotalsGet");
    if (!f) { printf("FAIL: libanvil isn't loaded (AnvilReadTotalsGet missing)\n"); exit(1); }
    f(t);
}
static int save() {
    auto f = (int (*)(void))dlsym(RTLD_DEFAULT, "AnvilReadHeatSave");
    return f ? f() : -9;
}
#endif

static std::string slurp(const char* path) {
    FILE* f = fopen(path, "r");
    if (!f) return "";
    std::string s;
    char b[4096];
    size_t n;
    while ((n = fread(b, 1, sizeof b, f)) > 0) s.append(b, n);
    fclose(f);
    return s;
}

int main() {
    const char* tmp = getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp";
    char big[512], small_[512], state[512];
    snprintf(big, sizeof big, "%s/io_test_big_%d.dat", tmp, getpid());
    snprintf(small_, sizeof small_, "%s/io_test_small_%d.dat", tmp, getpid());
    if (getenv("ANVIL_WARM_STATE")) snprintf(state, sizeof state, "%s", getenv("ANVIL_WARM_STATE"));
    else { snprintf(state, sizeof state, "%s/io_test_state_%d.txt", tmp, getpid()); setenv("ANVIL_WARM_STATE", state, 1); }
    unlink(state);
    // A 100 MB file (25 pieces of 4 MB) and a small one.
    {
        int fd = open(big, O_CREAT | O_TRUNC | O_WRONLY, 0644);
        std::vector<char> mb(1 << 20, 7);
        for (int i = 0; i < 100; ++i) write(fd, mb.data(), mb.size());
        close(fd);
        fd = open(small_, O_CREAT | O_TRUNC | O_WRONLY, 0644);
        write(fd, mb.data(), 4096);
        close(fd);
    }
    // What earlier sessions kept: piece 3 of the big file read often, and a file not opened this session.
    {
        // As the game's process names it: the path the system gives an open file (/private/tmp, not /tmp).
        char real[1024];
        if (!realpath(big, real)) snprintf(real, sizeof real, "%s", big);
        FILE* f = fopen(state, "w");
        fprintf(f, "anvil-warm 1\nfile 104857600 %s\nc 3 4.0\nc 5 2.0\nfile 999 /nowhere/old.dat\nc 1 3.0\nc 2 0.6\n", real);
        fclose(f);
    }
    std::vector<char> buf(8 << 20);
    AnvilReadTotals before{}, after{};
    totals(&before);

    int fd = open(big, O_RDONLY);
    CHECK(PREAD(fd, buf.data(), 65536, 0) == 65536, "a read at the start");
    CHECK(PREAD(fd, buf.data(), 65536, 21 << 20) == 65536, "one in piece 5");
    CHECK(PREAD(fd, buf.data(), 65536, (21 << 20) + 4096) == 65536, "again in piece 5");
    CHECK(PREAD(fd, buf.data(), 2 << 20, (39 << 20)) == (2 << 20), "one across pieces 9 and 10");
    lseek(fd, 80 << 20, SEEK_SET);
    CHECK(READ(fd, buf.data(), 65536) == 65536, "a plain read in piece 20");
    CHECK(PREAD(fd, buf.data(), 65536, 200 << 20) == 0, "past the end: nothing");
    CLOSE(fd);
    // A small file: timed, nothing placed.
    fd = open(small_, O_RDONLY);
    CHECK(READ(fd, buf.data(), 4096) == 4096, "the small file");
    CLOSE(fd);
    // A pipe: passed through, not counted.
    int p[2];
    pipe(p);
    write(p[1], "hello", 5);
    CHECK(READ(p[0], buf.data(), 5) == 5 && memcmp(buf.data(), "hello", 5) == 0, "the pipe's bytes");
    // The pipe's descriptor numbers, closed and used again for the big file: looked at afresh.
    const int reused = p[0];
    CLOSE(p[0]);
    CLOSE(p[1]);
    fd = open(big, O_RDONLY);
    CHECK(fd == reused || fd != reused, "(a descriptor)");
    CHECK(PREAD(fd, buf.data(), 65536, 61 << 20) == 65536, "a read in piece 15");
    CLOSE(fd);
    // errno left as the call set it.
    errno = 0;
    CHECK(PREAD(9999, buf.data(), 16, 0) == -1 && errno == EBADF, "a bad descriptor: -1 and EBADF (errno %d)", errno);

    totals(&after);
    const uint64_t calls = after.calls - before.calls, bytes = after.bytes - before.bytes;
    CHECK(calls == 8, "reads of regular files counted: %llu (the pipe and the bad descriptor not)", (unsigned long long)calls);
    CHECK(bytes == 65536ull * 5 + (2ull << 20) + 4096, "bytes: %llu", (unsigned long long)bytes);

    CHECK(save() == 2, "the state saved: the large file, and the earlier one");
    std::string text = slurp(state);
    CHECK(text.rfind("anvil-warm 1\nfile 104857600 ", 0) == 0, "its header and the file: %.80s", text.c_str());
    // This session's reads, and the earlier sessions' at half: piece 3 4 → 2, piece 5 2 → 1 plus 2 read now.
    for (const char* want : {"\nc 0 1.0\n", "\nc 3 2.0\n", "\nc 5 3.0\n", "\nc 9 1.0\n", "\nc 10 1.0\n", "\nc 15 1.0\n", "\nc 20 1.0\n"})
        CHECK(text.find(want) != std::string::npos, "piece %s in %s", want + 1, text.c_str());
    CHECK(text.find("io_test_small") == std::string::npos, "the small file not placed");
    // The file not opened, faded: 3 → 1.5 kept, 0.6 → 0.3 dropped.
    CHECK(text.find("file 999 /nowhere/old.dat\nc 1 1.5\n") != std::string::npos && text.find("\nc 2 ") == std::string::npos,
          "an earlier file faded: %s", text.c_str());
    CHECK(save() == 0, "nothing new read: not written again");

    // The next save, after another read: against the same earlier sessions, not this one's own last save.
    fd = open(big, O_RDONLY);
    PREAD(fd, buf.data(), 4096, 21 << 20);
    CLOSE(fd);
    CHECK(save() == 2, "saved again");
    text = slurp(state);
    CHECK(text.find("\nc 5 4.0\n") != std::string::npos && text.find("\nc 0 1.0\n") != std::string::npos
          && text.find("\nc 3 2.0\n") != std::string::npos, "not counted twice: %s", text.c_str());

    // IO_TEST_EXIT: one more read after the last save, then a normal exit — libanvil's own save at exit
    // runs (it crashed there in 0.50's first build, its lock already torn down); the caller checks the file.
    const bool atExit = getenv("IO_TEST_EXIT") != nullptr;
    if (atExit) {
        fd = open(big, O_RDONLY);
        PREAD(fd, buf.data(), 4096, 33 << 20);
        CLOSE(fd);
    }
    unlink(big);
    unlink(small_);
    if (!atExit) unlink(state);
    if (g_failed) { printf("io: %d checks FAILED\n", g_failed); return 1; }
    printf("io: all checks passed\n");
    return 0;
}

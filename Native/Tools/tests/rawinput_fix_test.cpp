// Tests Anvil's corrected get_rawinput_buffer against a message queue laid out the way
// the Wine 7.7 server lays it out, and reads the reply back with Wine 7.7's own client
// loop (user32 GetRawInputBuffer), so a report is only counted as delivered if the game
// would actually see its bytes.
//
//   clang++ -std=c++17 -arch x86_64 -x c++ rawinput_fix_test.cpp -o rawinput_fix_test && ./rawinput_fix_test

#define ANVIL_WINESERVER_TEST 1
#include "../../AnvilMetal/anvil_wineserver.mm"
#include <vector>
#include <algorithm>

namespace {

int g_failures = 0;
[[maybe_unused]] void** g_originalSlot = nullptr;
#define CHECK(cond, ...) do { if (!(cond)) { ++g_failures; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

struct Fixture {
    alignas(16) uint8_t thread[0x200] = {};
    alignas(16) uint8_t queue[0x100] = {};
    alignas(16) uint8_t input[0x100] = {};
    void* current = nullptr;
    List* head() { return reinterpret_cast<List*>(input + kInputMsgList); }

    Fixture(uint32_t replyMax = 4096) {
        uint8_t* q = queue; memcpy(thread + kThreadQueue, &q, 8);
        uint8_t* in = input; memcpy(queue + kQueueInput, &in, 8);
        head()->next = head()->prev = head();
        write32(thread + kThreadReplyMax, replyMax);
        current = thread;
        g_current = &current;
    }
    // A message as the server allocates one: list entry first, data separately.
    void push(uint32_t code, uint32_t reportLen, uint8_t fill) {
        auto* msg = static_cast<uint8_t*>(calloc(1, 0x60));
        write32(msg + kMessageCode, code);
        auto* data = static_cast<uint8_t*>(calloc(1, kHwDataHeader + reportLen));
        write32(data + kHwDataSize, kHwDataHeader + reportLen);
        // rawinput.type at 0x18 in hardware_msg_data: 0 mouse, 1 keyboard, 2 HID.
        write32(data + 0x18, reportLen ? 2 : 1);
        write32(data + 0x20, reportLen);            // hid.length
        write32(data + 0x24, 1);                    // hid.count
        memset(data + kHwDataHeader, fill, reportLen);
        memcpy(msg + kMessageData, &data, 8);
        auto* e = reinterpret_cast<List*>(msg);
        e->prev = head()->prev; e->next = head();
        head()->prev->next = e; head()->prev = e;
    }
    size_t queued() { size_t n = 0; for (List* p = head()->next; p != head(); p = p->next) ++n; return n; }
    uint8_t* replyData() { return readPtr<uint8_t*>(thread + kThreadReplyData); }
    uint32_t replySize() { return read32(thread + kThreadReplySize); }
};

struct Result { uint32_t nextSize, count; };
using Handler = void (*)(const uint8_t*, uint8_t*);
Result call(Fixture&, uint32_t bufferSize, Handler handler = AnvilGetRawinputBuffer) {
    uint8_t req[0x18] = {}; write32(req + 0x0c, 0x30); write32(req + 0x10, bufferSize);
    uint8_t reply[0x10] = {};
    handler(req, reply);
    return { read32(reply + 0x08), read32(reply + 0x0c) };
}

// Wine 7.7 user32: walk the reply by each message's own size, as the client does.
std::vector<std::vector<uint8_t>> clientReports(uint8_t* reply, uint32_t replySize, uint32_t count) {
    std::vector<std::vector<uint8_t>> out;
    uint8_t* p = reply;
    for (uint32_t i = 0; i < count; ++i) {
        if (p + kHwDataHeader > reply + replySize) { out.push_back({}); break; }   // client would read past the reply
        const uint32_t sz = read32(p + kHwDataSize);
        if (sz < kHwDataHeader || p + sz > reply + replySize) { out.push_back({}); break; }
        out.emplace_back(p + kHwDataHeader, p + sz);
        p += sz;
    }
    return out;
}

} // namespace

#if defined(__x86_64__)
#include <sys/mman.h>
void fakeStoreResult(void*, long, unsigned) { printf("original settled a message result\n"); abort(); }
void fakeAssert(const char* fn, const char*, int, const char* what) { printf("original asserted: %s %s\n", fn, what); abort(); }
void* fakeMemAlloc(size_t n) { return malloc(n); }

// Wine's get_rawinput_buffer, copied out of the wineserver binary and relinked against
// this process: its calls go to libc and its reads of `current` to a slot of ours.
Handler loadOriginal(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return nullptr;
    std::vector<uint8_t> file(0x32500 + kHandlerLength);
    const bool ok = fread(file.data(), 1, file.size(), f) == file.size();
    fclose(f);
    if (!ok) return nullptr;
    const uint8_t* code = file.data() + 0x32500;
    if (fnv1a(code, kHandlerLength) != kHandlerFingerprint) return nullptr;

    auto* page = static_cast<uint8_t*>(mmap(nullptr, 0x2000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0));
    if (page == MAP_FAILED) return nullptr;
    uint8_t* text = page; uint8_t* tramp = page + 0x300; uint8_t* data = page + 0x1000;
    memcpy(text, code, kHandlerLength);
    auto rel = [&](size_t at, const uint8_t* target) {
        const int32_t d = int32_t(target - (text + at + 4)); memcpy(text + at, &d, 4);
    };
    int n = 0;
    auto via = [&](void* target) {
        uint8_t* t = tramp + 16 * n++;
        t[0] = 0x48; t[1] = 0xb8; memcpy(t + 2, &target, 8); t[10] = 0xff; t[11] = 0xe0;   // movabs rax; jmp rax
        return t;
    };
    const struct { size_t at; uint8_t op; } calls[] = {
        {0x3e, 0xe8}, {0x125, 0xe8}, {0x15e, 0xe8}, {0x198, 0xe8}, {0x1a1, 0xe8}, {0x1a9, 0xe8}, {0x265, 0xe8}};
    for (auto c : calls) if (text[c.at] != c.op) return nullptr;
    rel(0x3e + 1, via((void*)fakeMemAlloc));
    rel(0x125 + 1, via((void*)realloc));
    rel(0x15e + 1, via((void*)memcpy));
    rel(0x198 + 1, via((void*)fakeStoreResult));
    uint8_t* freeT = via((void*)free);
    rel(0x1a1 + 1, freeT); rel(0x1a9 + 1, freeT);
    rel(0x265 + 1, via((void*)fakeAssert));
    for (size_t at : {0x14, 0xd8, 0x1f5, 0x230}) { if (text[at] != 0x48 || text[at + 1] != 0x8d) return nullptr; rel(at + 3, data); }
    rel(0x223 + 3, data + 8);                                       // global_error
    for (size_t at : {0x24b, 0x252, 0x259}) rel(at + 3, data + 16); // assert strings
    memcpy(data + 16, "?", 2);
    if (mprotect(page, 0x1000, PROT_READ | PROT_EXEC)) return nullptr;
    // `current` is read through the slot at data[0]; point it at this process's variable.
    g_originalSlot = reinterpret_cast<void**>(data);
    return reinterpret_cast<Handler>(text);
}
#endif

int main(int argc, char** argv) {
    (void)argc; (void)argv;
    // 1. Size query: nothing is removed, the next message's size is reported.
    {
        Fixture f; f.push(kWmInput, 20, 0xA1);
        Result r = call(f, 0);
        CHECK(r.count == 0 && r.nextSize == 0x30 + 20, "probe: count %u next %u", r.count, r.nextSize);
        CHECK(f.queued() == 1, "probe removed a message");
        CHECK(!f.replyData() && f.replySize() == 0, "probe produced reply data");
    }
    // 2. Empty queue and a queue with no WM_INPUT.
    {
        Fixture f; Result r = call(f, 4096);
        CHECK(r.count == 0 && r.nextSize == 0 && f.replySize() == 0, "empty queue");
        f.push(0x100 /* WM_KEYDOWN */, 0, 0); r = call(f, 4096);
        CHECK(r.count == 0 && r.nextSize == 0 && f.queued() == 1, "non-WM_INPUT touched");
    }
    // 3. Mixed batch: keyboard, a key message, two controller reports, keyboard.
    {
        Fixture f;
        f.push(kWmInput, 0, 0); f.push(0x100, 0, 0);
        f.push(kWmInput, 20, 0xB1); f.push(kWmInput, 20, 0xB2); f.push(kWmInput, 0, 0);
        Result r = call(f, 4096);
        CHECK(r.count == 4, "mixed: count %u", r.count);
        CHECK(f.queued() == 1, "mixed: %zu left (only the key message should remain)", f.queued());
        CHECK(f.replySize() == 2 * kHwDataHeader + 2 * (kHwDataHeader + 20), "mixed: reply %u", f.replySize());
        auto reports = clientReports(f.replyData(), f.replySize(), r.count);
        CHECK(reports.size() == 4, "mixed: client parsed %zu", reports.size());
        if (reports.size() == 4) {
            CHECK(reports[1] == std::vector<uint8_t>(20, 0xB1), "first controller report corrupted");
            CHECK(reports[2] == std::vector<uint8_t>(20, 0xB2), "second controller report corrupted");
        }
        free(f.replyData());
    }
    // 4. The game's buffer holds two controller reports; the third waits.
    {
        Fixture f; for (int i = 0; i < 3; ++i) f.push(kWmInput, 20, uint8_t(0xC0 + i));
        Result r = call(f, 2 * (0x30 + 20));
        CHECK(r.count == 2 && r.nextSize == 0x30 + 20 && f.queued() == 1, "budget: count %u left %zu", r.count, f.queued());
        auto reports = clientReports(f.replyData(), f.replySize(), r.count);
        CHECK(reports.size() == 2 && reports[1] == std::vector<uint8_t>(20, 0xC1), "budget: second report wrong");
        free(f.replyData());
        r = call(f, 4096);
        reports = clientReports(f.replyData(), f.replySize(), r.count);
        CHECK(r.count == 1 && reports.size() == 1 && reports[0] == std::vector<uint8_t>(20, 0xC2), "budget: third report wrong");
        free(f.replyData());
    }
    // 5. The client's reply space is the limit.
    {
        Fixture f(2 * (kHwDataHeader + 20)); for (int i = 0; i < 3; ++i) f.push(kWmInput, 20, 0xD0);
        Result r = call(f, 100000);
        CHECK(r.count == 2 && f.replySize() <= 2 * (kHwDataHeader + 20) && f.queued() == 1, "reply max: count %u", r.count);
        free(f.replyData());
    }
    // 6. More than the initial 16-message buffer: it grows and every report survives.
    {
        Fixture f(1 << 20); for (int i = 0; i < 60; ++i) f.push(kWmInput, 27, uint8_t(i));
        Result r = call(f, 1 << 20);
        auto reports = clientReports(f.replyData(), f.replySize(), r.count);
        bool intact = reports.size() == 60;
        for (size_t i = 0; intact && i < reports.size(); ++i) intact = reports[i] == std::vector<uint8_t>(27, uint8_t(i));
        CHECK(r.count == 60 && intact && f.queued() == 0, "growth: count %u parsed %zu", r.count, reports.size());
        free(f.replyData());
    }
#if defined(__x86_64__)
    // 7. Wine's own handler, run from the wineserver binary on the same queues. Every
    // structure offset the corrected handler uses is proved here: the original must
    // remove the same messages and report the same counts — and differ only in the
    // reply, where it keeps the headers and loses the reports.
    if (argc > 1) {
        Handler original = loadOriginal(argv[1]);
        CHECK(original, "could not load the handler from %s", argv[1]);
        if (original) {
            struct Case { const char* name; std::vector<uint32_t> reports; uint32_t budget; uint32_t replyMax; };
            const Case cases[] = {
                {"probe", {20}, 0, 4096},
                {"mixed", {0, 20, 20, 0}, 4096, 4096},
                {"budget", {20, 20, 20}, 2 * (0x30 + 20), 4096},
                {"reply max", {20, 20, 20}, 100000, 2 * (0x38 + 20)},
                {"growth", std::vector<uint32_t>(60, 27), 1 << 20, 1 << 20},
            };
            for (const Case& c : cases) {
                Fixture a(c.replyMax), b(c.replyMax);
                for (size_t i = 0; i < c.reports.size(); ++i) {
                    a.push(kWmInput, c.reports[i], uint8_t(i)); b.push(kWmInput, c.reports[i], uint8_t(i));
                }
                *g_originalSlot = a.thread;
                Result ra = call(a, c.budget, original);
                g_current = &b.current;
                Result rb = call(b, c.budget);
                CHECK(ra.count == rb.count && ra.nextSize == rb.nextSize, "%s: original %u/%u, corrected %u/%u",
                      c.name, ra.count, ra.nextSize, rb.count, rb.nextSize);
                CHECK(a.queued() == b.queued(), "%s: original left %zu, corrected %zu", c.name, a.queued(), b.queued());
                CHECK(a.replySize() == ra.count * kHwDataHeader, "%s: original reply %u", c.name, a.replySize());
                // Headers the original kept match the corrected reply's headers.
                uint32_t pos = 0; bool same = true;
                for (uint32_t i = 0; i < rb.count && same; ++i) {
                    same = !memcmp(a.replyData() + i * kHwDataHeader, b.replyData() + pos, kHwDataHeader);
                    pos += read32(b.replyData() + pos + kHwDataSize);
                }
                CHECK(same, "%s: headers differ between original and corrected", c.name);
                // What the game can read back, report by report.
                auto intact = [&](Fixture& f, uint32_t count) {
                    auto got = clientReports(f.replyData(), f.replySize(), count);
                    uint32_t good = 0, want = 0;
                    for (size_t i = 0; i < c.reports.size() && want < count; ++i, ++want)
                        if (i < got.size() && got[i] == std::vector<uint8_t>(c.reports[i], uint8_t(i))) ++good;
                    return good;
                };
                const uint32_t hid = uint32_t(std::count_if(c.reports.begin(), c.reports.begin() + rb.count,
                                                            [](uint32_t r) { return r > 0; }));
                const uint32_t goodOld = intact(a, ra.count), goodNew = intact(b, rb.count);
                CHECK(goodNew == rb.count, "%s: corrected reply readable for %u of %u", c.name, goodNew, rb.count);
                printf("  %-9s %2u messages (%2u controller): Wine 7.7 sent %4u bytes, game reads %2u intact; corrected %4u bytes, %2u intact\n",
                       c.name, rb.count, hid, a.replySize(), goodOld, b.replySize(), goodNew);
                free(a.replyData()); free(b.replyData());
            }
        }
    }
#endif
    printf(g_failures ? "%d FAILED\n" : "all raw-input batch tests passed\n", g_failures);
    return g_failures ? 1 : 0;
}

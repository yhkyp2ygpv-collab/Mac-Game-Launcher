// The winebus side of the virtual Pro Controller, without Wine.
//
// 1. The real winebus.so from an installed engine, laid out in memory the way dyld maps
//    it: every symbol found, every fingerprint matching, the SDL bus's queue located.
// 2. The bridge driven by a stand-in winebus that behaves like the real one — events
//    queued and popped in order, each holding a reference on its device, released when
//    the next wait begins — through a pad connecting, the game's handshake, buttons,
//    rumble and the pad being unplugged, with every reference accounted for.
//
//   clang++ -std=c++17 -I Native/AnvilMetal Native/Tools/tests/switchpro_bridge_test.cpp \
//       -o /tmp/bridge_test && /tmp/bridge_test <path to winebus.so>
#include "../../AnvilMetal/anvil_switchpro.mm"

#include <deque>
#include <fstream>
#include <iterator>

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { ++failures; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

// --- 1. The real winebus -------------------------------------------------------------

static void testRealWinebus(const char* path) {
    std::ifstream in(path, std::ios::binary);
    std::vector<uint8_t> file((std::istreambuf_iterator<char>(in)), {});
    CHECK(file.size() > 0x1000, "cannot read %s", path);
    if (file.size() < 0x1000) return;
    const auto* fh = reinterpret_cast<const mach_header_64*>(file.data());
    size_t span = 0;
    const auto* cmd = reinterpret_cast<const load_command*>(fh + 1);
    for (uint32_t i = 0; i < fh->ncmds; ++i) {
        if (cmd->cmd == LC_SEGMENT_64) {
            const auto* seg = reinterpret_cast<const segment_command_64*>(cmd);
            span = std::max<size_t>(span, seg->vmaddr + seg->vmsize);
        }
        cmd = reinterpret_cast<const load_command*>(reinterpret_cast<const uint8_t*>(cmd) + cmd->cmdsize);
    }
    std::vector<uint8_t> image(span);
    cmd = reinterpret_cast<const load_command*>(fh + 1);
    for (uint32_t i = 0; i < fh->ncmds; ++i) {
        if (cmd->cmd == LC_SEGMENT_64) {
            const auto* seg = reinterpret_cast<const segment_command_64*>(cmd);
            memcpy(image.data() + seg->vmaddr, file.data() + seg->fileoff, seg->filesize);
        }
        cmd = reinterpret_cast<const load_command*>(reinterpret_cast<const uint8_t*>(cmd) + cmd->cmdsize);
    }
    const uintptr_t base = reinterpret_cast<uintptr_t>(image.data());
    Image img{reinterpret_cast<const mach_header_64*>(image.data()), static_cast<intptr_t>(base)};

    static const char* const names[] = {"_sdl_bus_wait", "_bus_event_queue_pop", "___wine_unix_call_funcs"};
    uintptr_t found[3] = {};
    uintptr_t queues[4] = {};
    int queueCount = 0;
    resolve(img, names, found, 3, queues, 4, &queueCount);
    CHECK(found[0] && found[1] && found[2], "symbols not all found");
    CHECK(queueCount == 3, "expected winebus's three event queues, found %d", queueCount);

    // Every function the bridge depends on matches its fingerprint.
    for (const Fingerprint& f : kFingerprints) {
        const char* one[] = {f.symbol};
        uintptr_t at[1] = {};
        int unused = 0;
        uintptr_t q[4];
        resolve(img, one, at, 1, q, 4, &unused);
        CHECK(at[0] && fnv1a(reinterpret_cast<const uint8_t*>(at[0]), f.length) == f.fnv,
              "%s does not match its fingerprint", f.symbol);
    }
    const uintptr_t queue = sdlQueue(found[0], queues, queueCount);
    CHECK(queue == base + 0x10698, "SDL queue found at %#lx, expected base+0x10698", (unsigned long)(queue - base));

    // dyld rebases the call table as it maps it; do the same, then find the wait in it.
    auto** table = reinterpret_cast<void**>(found[2]);
    for (int i = 0; i < 20; ++i) table[i] = reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(table[i]) + base);
    int slot = -1;
    for (int i = 0; i < 64; ++i) if (table[i] == reinterpret_cast<void*>(found[0])) { slot = i; break; }
    CHECK(slot == 1, "sdl_bus_wait found at table index %d", slot);
    printf("real winebus: symbols, fingerprints, queue and call table all as expected\n");
}

// --- 2. A stand-in winebus -----------------------------------------------------------

struct FakeEvent { uint32_t type; void* device; std::vector<uint8_t> payload; };
static std::deque<FakeEvent> g_fakeQueue;      // what winebus has queued
static std::deque<FakeEvent> g_script;         // SDL events still to come, as winebus would turn them into bus events
static void* g_lastReturned = nullptr;         // the device whose event the caller now holds
static int g_started = 0, g_removed = 0;
static std::vector<std::vector<uint8_t>> g_reportsForOurs;

// A device of winebus's own: vtable, and the reference count at 0x18.
struct FakeSdlDevice { void* vtable; void* list[2]; int32_t refcount; int32_t pad; uint8_t rest[0x4190 - 0x20]; void* controller; };

static int32_t* refOf(void* device) { return reinterpret_cast<int32_t*>(static_cast<uint8_t*>(device) + 0x18); }

static void dropRef(void* device) {
    if (!device) return;
    if (--*refOf(device) == 0) {
        if (isOurs(device) || reinterpret_cast<VDevice*>(device)->magic == kMagic) {
            vDestroy(static_cast<VDevice*>(device));
            free(device);
        }
    }
}

static int fakeQueueInput(void* queue, void* device, const void* report, uint32_t length) {
    CHECK(queue == g_wb.queue, "reports queued on the wrong queue");
    if (*refOf(device) == 0) return 0;
    ++*refOf(device);
    const auto* r = static_cast<const uint8_t*>(report);
    g_fakeQueue.push_back({3, device, std::vector<uint8_t>(r, r + length)});
    return 1;
}
static int fakeQueueCreated(void*, void* device, const void* desc) {
    ++*refOf(device);
    const auto* d = static_cast<const uint8_t*>(desc);
    g_fakeQueue.push_back({2, device, std::vector<uint8_t>(d, d + kDescSize)});
    return 1;
}
static int fakeQueueRemoved(void*, void* device) {
    ++*refOf(device);
    g_fakeQueue.push_back({1, device, {}});
    return 1;
}
static uint32_t fakeStart(void* params) { (void)params; ++g_started; return kStatusSuccess; }
static uint32_t fakeRemove(void* params) {
    void* device = *static_cast<void**>(params);
    ++g_removed;
    dropRef(device);
    return kStatusSuccess;
}
static uint32_t fakeWait(void* args) {
    auto* event = static_cast<uint8_t*>(args);
    dropRef(g_lastReturned);                   // bus_event_cleanup of the event handed out last
    g_lastReturned = nullptr;
    if (g_fakeQueue.empty() && !g_script.empty()) {
        FakeEvent e = g_script.front();
        g_script.pop_front();
        ++*refOf(e.device);
        g_fakeQueue.push_back(e);
    }
    if (g_fakeQueue.empty()) return kStatusSuccess;
    FakeEvent e = g_fakeQueue.front();
    g_fakeQueue.pop_front();
    memset(event, 0, 0x640);
    writeAt<uint32_t>(event, kEventType, e.type);
    writeAt<void*>(event, kEventDevice, e.device);
    if (e.type == 2) memcpy(event + kEventDesc, e.payload.data(), kDescSize);
    if (e.type == 3) {
        writeAt<uint16_t>(event, 0x10, static_cast<uint16_t>(e.payload.size()));
        memcpy(event + 0x12, e.payload.data(), e.payload.size());
    }
    g_lastReturned = e.device;
    return kStatusPending;
}

// A stand-in SDL pad, read by the bridge.
static uint8_t g_buttons[21];
static int16_t g_axes[6];
static int g_controllerToken, g_joystickToken;
static void* fakeOpen(int) { return &g_controllerToken; }
static void* fakeJoystick(void*) { return &g_joystickToken; }
static uint16_t fakeVendor(void*) { return 0x20d6; }
static uint16_t fakeProduct(void*) { return 0xa720; }
static uint8_t fakeButton(void*, int b) { return b >= 0 && b < 21 ? g_buttons[b] : 0; }
static int16_t fakeAxis(void*, int a) { return a >= 0 && a < 6 ? g_axes[a] : 0; }
static float g_rumbleLow = -1;
static int fakeRumble(void*, uint16_t low, uint16_t, uint32_t) { g_rumbleLow = low / 65535.f; return 0; }

// Everything the caller of the wait receives, as Windows would.
static std::vector<FakeEvent> pump(uint8_t* args) {
    std::vector<FakeEvent> seen;
    for (int i = 0; i < 64; ++i) {
        const uint32_t status = anvilSdlBusWait(args);
        if (status != kStatusPending) break;
        FakeEvent e{readAt<uint32_t>(args, kEventType), readAt<void*>(args, kEventDevice), {}};
        if (e.type == 3) {
            const uint16_t n = readAt<uint16_t>(args, 0x10);
            e.payload.assign(args + 0x12, args + 0x12 + n);
        }
        if (e.type == 2) e.payload.assign(args + kEventDesc, args + kEventDesc + kDescSize);
        seen.push_back(e);
        // The bus thread goes round again; the bridge ticks inside SDL's wait.
        AnvilSwitchProTick();
    }
    return seen;
}

static void testBridge() {
    setenv("ANVIL_VIRTUAL_PRO", "20d6:a720", 1);
    g_wb = {fakeWait, fakeStart, fakeRemove, fakeQueueInput, fakeQueueCreated, fakeQueueRemoved, &g_fakeQueue};
    g_sdl = {fakeOpen, fakeJoystick, fakeVendor, fakeProduct, fakeButton, fakeAxis, fakeRumble};
    g_ready.store(true);

    // winebus opens the pad through the wrapper, then announces the device.
    void* controller = AnvilSwitchProControllerOpen(0);
    auto* pad = static_cast<FakeSdlDevice*>(calloc(1, sizeof(FakeSdlDevice)));
    pad->refcount = 1;
    pad->controller = controller;
    std::vector<uint8_t> desc(kDescSize, 0);
    writeAt<uint32_t>(desc.data(), kDescVid, 0x20d6);
    writeAt<uint32_t>(desc.data(), kDescPid, 0xa720);
    writeAt<uint32_t>(desc.data(), kDescIsGamepad, 1);
    setWide(desc.data(), kDescProduct, "PowerA Advantage Wired Controller for Nintendo Switch 2");
    g_script.push_back({2, pad, desc});
    // Two reports of the pad's own, which must never reach Windows.
    g_script.push_back({3, pad, std::vector<uint8_t>(20, 0xAB)});
    g_script.push_back({3, pad, std::vector<uint8_t>(20, 0xCD)});

    std::vector<uint8_t> argsBuffer(0x640 + 64);
    uint8_t* args = argsBuffer.data();
    std::vector<FakeEvent> seen = pump(args);

    CHECK(!seen.empty() && seen[0].type == 2, "Windows was not told of a device first");
    void* pro = seen.empty() ? nullptr : seen[0].device;
    CHECK(pro && pro != pad, "the device announced is the pad itself");
    if (!seen.empty() && seen[0].type == 2) {
        const uint8_t* d = seen[0].payload.data();
        CHECK(readAt<uint32_t>(d, kDescVid) == 0x057E && readAt<uint32_t>(d, kDescPid) == 0x2009,
              "announced as %04x:%04x", readAt<uint32_t>(d, kDescVid), readAt<uint32_t>(d, kDescPid));
        CHECK(readAt<uint32_t>(d, kDescIsGamepad) == 0, "the Pro Controller would get an XInput copy");
    }
    for (const FakeEvent& e : seen) CHECK(e.device != pad, "an event of the hidden pad reached Windows (type %u)", e.type);
    CHECK(g_started == 1, "the hidden pad was started %d times", g_started);

    // Windows starts the device and reads its descriptor.
    auto** vt = *reinterpret_cast<void***>(pro);
    uint32_t written = 0;
    uint8_t descriptorBuffer[256];
    CHECK(reinterpret_cast<uint32_t (*)(void*)>(vt[1])(pro) == kStatusSuccess, "start failed");
    CHECK(reinterpret_cast<uint32_t (*)(void*, uint8_t*, uint32_t, uint32_t*)>(vt[3])(pro, descriptorBuffer, 4, &written)
          == kStatusBufferTooSmall && written > 4, "a short buffer must be refused with the size");
    CHECK(reinterpret_cast<uint32_t (*)(void*, uint8_t*, uint32_t, uint32_t*)>(vt[3])(pro, descriptorBuffer, 256, &written)
          == kStatusSuccess, "descriptor refused");

    // LEGO's handshake through the vtable, answered on the next pass of the bus.
    auto write = [&](std::vector<uint8_t> bytes) {
        bytes.resize(64, 0);
        uint8_t packet[16] = {}, io[16] = {};
        uint8_t* buffer = bytes.data();
        memcpy(packet, &buffer, 8);
        const uint32_t len = 64;
        memcpy(packet + 8, &len, 4);
        packet[0xc] = bytes[0];
        reinterpret_cast<void (*)(void*, uint8_t*, uint8_t*)>(vt[4])(pro, packet, io);
        CHECK(readAt<uint32_t>(io, 0) == kStatusSuccess && readAt<uint64_t>(io, 8) == 64, "write not completed");
    };
    write({0x80, 0x01});
    AnvilSwitchProTick();
    seen = pump(args);
    bool status = false;
    for (const FakeEvent& e : seen) if (e.type == 3 && e.device == pro && e.payload[0] == 0x81 && e.payload[1] == 0x01) status = true;
    CHECK(status, "status reply never reached Windows");
    write({0x80, 0x02});
    write({0x80, 0x04});
    AnvilSwitchProTick();
    seen = pump(args);

    // A button: the pad's A, which SDL reports as its A under a mapping by label.
    g_buttons[0] = 1;
    AnvilSwitchProTick();
    seen = pump(args);
    bool sawA = false;
    for (const FakeEvent& e : seen) if (e.type == 3 && e.device == pro && e.payload[0] == 0x30 && (e.payload[3] & 0x08)) sawA = true;
    CHECK(sawA, "pressing A did not produce a report with Nintendo's A bit");
    g_buttons[0] = 0;

    // Rumble from the game reaches SDL.
    write({0x10, 0x01, 0x80, 0x20, 0x62, 0xFF, 0x80, 0x00, 0x00, 0x00});
    AnvilSwitchProTick();
    CHECK(g_rumbleLow > 0.99f, "rumble reached SDL as %.2f", g_rumbleLow);

    // The pad is unplugged: its Pro Controller is removed, the pad released.
    g_script.push_back({1, pad, {}});
    seen = pump(args);
    bool removed = false;
    for (const FakeEvent& e : seen) if (e.type == 1 && e.device == pro) removed = true;
    CHECK(removed, "Windows was not told the Pro Controller went away");
    CHECK(g_removed == 1, "the hidden pad was released %d times", g_removed);

    // Windows removes the Pro Controller as it would: stop, then its reference goes.
    reinterpret_cast<void (*)(void*)>(vt[2])(pro);
    dropRef(pro);
    AnvilSwitchProTick();                      // the bridge lets go of its own
    pump(args);                                // and the last event it held is cleaned up
    bool slotsFree = true;
    for (Slot& s : g_slots) if (s.state.load() != 0) slotsFree = false;
    CHECK(slotsFree, "the Pro Controller's slot was never freed — a reference leaked");
    CHECK(*refOf(pad) == 0, "the hidden pad still holds %d references", *refOf(pad));
    printf("bridge: connect, handshake, buttons, rumble and unplug behave, references balance\n");
}

int main(int argc, char** argv) {
    if (argc > 1) testRealWinebus(argv[1]);
    testBridge();
    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("switchpro bridge: all checks passed\n");
    return 0;
}

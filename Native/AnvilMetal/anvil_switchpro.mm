// A pad shown to the game as a Nintendo Switch Pro Controller that it can actually use.
//
// Until 0.14 Anvil only changed the id and name Wine gives a Switch-style pad. LEGO Star
// Wars saw a "Pro Controller", switched to Nintendo prompts, opened it with its own
// Switch Pro driver — and got nothing: that driver speaks Nintendo's USB protocol, and
// the device Wine makes from an SDL pad answers none of it. Its handshake failed, it
// closed the device and started over, several times a second, for the whole session
// (a thread in every stall capture from 0.12.2 on). The buttons it did act on came
// through XInput from a second copy of the same pad, which the game treats as an Xbox
// pad even while it shows Nintendo prompts — so confirm, cancel and half the buttons
// never matched what was on screen.
//
// Now the pad itself is hidden from Windows, and a Pro Controller made by Anvil takes its
// place: it answers the handshake and every command a game sends, and reports the pad in
// Nintendo's own format (see anvil_switchpro.h). The game's own Switch Pro support then
// does exactly what it does with a real one — prompts, confirm and cancel, all of it.
//
// It lives in winebus, the Wine driver that makes Windows devices out of SDL pads, in the
// winedevice process. Only in a winebus whose code matches, byte for byte, the build this
// was read from (Wine 7.7 as Mythic Engine 2.6 and Whisky 2.5 ship it); anywhere else pads
// are shown as they are.

#include "anvil_switchpro.h"

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <unistd.h>
#include <atomic>
#include <chrono>
#include <cstdarg>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>

using namespace anvil::switchpro;

namespace {

// --- winebus, as read from its machine code ------------------------------------------
//
// struct bus_event      type @0, device @8, then a device_desc, or a length (u16) @0x10
//                       and the report @0x12
// struct device_desc    vid @0, pid @4, version @8, input @0xc, uid @0x10, is_gamepad @0x14,
//                       manufacturer @0x18, product @0x220, serial @0x428 (WCHAR[260] each)
// struct unix_device    vtable @0, reference count @0x18
// struct sdl_device     SDL_GameController* @0x4190
// HID_XFER_PACKET       buffer @0, length @8, report id @0xc
// IO_STATUS_BLOCK       status @0, information @8
constexpr uint32_t kStatusSuccess = 0, kStatusPending = 0x103;
constexpr uint32_t kStatusBufferTooSmall = 0xC0000023, kStatusNotImplemented = 0xC0000002;
constexpr uint32_t kEventRemoved = 1, kEventCreated = 2;
constexpr size_t kEventType = 0x00, kEventDevice = 0x08, kEventDesc = 0x10;
constexpr size_t kDescVid = 0x00, kDescPid = 0x04, kDescVersion = 0x08, kDescIsGamepad = 0x14;
constexpr size_t kDescManufacturer = 0x18, kDescProduct = 0x220, kDescSerial = 0x428, kDescSize = 0x630;
constexpr size_t kDescStringChars = 260;
constexpr size_t kDeviceRefcount = 0x18;
constexpr size_t kSdlDeviceController = 0x4190;

struct Fingerprint { const char* symbol; uint32_t length; uint64_t fnv; };
// FNV-1a of each function this depends on, identical in Mythic Engine 2.6.1 and Whisky 2.5.
constexpr Fingerprint kFingerprints[] = {
    {"_sdl_bus_wait",                      0x0ad0, 0xf45375e4c2f388c5ULL},
    {"_unix_device_remove",                0x0040, 0x7d041efbb09ef712ULL},
    {"_unix_device_start",                 0x0010, 0xc6e5f6303ea33ff0ULL},
    {"_unix_device_get_report_descriptor", 0x0020, 0xe287494770e62eacULL},
    {"_unix_device_set_output_report",     0x0020, 0x39ee621c2f35d750ULL},
    {"_bus_event_cleanup",                 0x0040, 0x8492251f5336b734ULL},
    {"_bus_event_queue_device_removed",    0x0070, 0x510ed83b2e365070ULL},
    {"_bus_event_queue_device_created",    0x0090, 0x800f5ab55515b131ULL},
    {"_bus_event_queue_input_report",      0x00b0, 0x9e8f4546503312eeULL},
    {"_bus_event_queue_pop",               0x0060, 0xd1c878cf92f145caULL},
};

using UnixCall = uint32_t (*)(void* args);
using QueueInputFn = int (*)(void* queue, void* device, const void* report, uint32_t length);
using QueueCreatedFn = int (*)(void* queue, void* device, const void* desc);
using QueueRemovedFn = int (*)(void* queue, void* device);

struct Winebus {
    UnixCall sdlBusWait = nullptr;
    UnixCall deviceStart = nullptr;
    UnixCall deviceRemove = nullptr;
    QueueInputFn queueInput = nullptr;
    QueueCreatedFn queueCreated = nullptr;
    QueueRemovedFn queueRemoved = nullptr;
    void* queue = nullptr;            // the SDL bus's event queue
};
Winebus g_wb;
std::atomic<bool> g_ready{false};
std::atomic<bool> g_tried{false};

// --- SDL -------------------------------------------------------------------------------
using CtrlOpenFn = void* (*)(int);
using CtrlJoystickFn = void* (*)(void*);
using JoyU16Fn = uint16_t (*)(void*);
using CtrlButtonFn = uint8_t (*)(void*, int);
using CtrlAxisFn = int16_t (*)(void*, int);
using CtrlRumbleFn = int (*)(void*, uint16_t, uint16_t, uint32_t);

struct Sdl {
    CtrlOpenFn open = nullptr;
    CtrlJoystickFn joystick = nullptr;
    JoyU16Fn vendor = nullptr, product = nullptr;
    CtrlButtonFn button = nullptr;
    CtrlAxisFn axis = nullptr;
    CtrlRumbleFn rumble = nullptr;
};
Sdl g_sdl;

// Controllers winebus has opened, so a pointer read out of its device can be checked.
constexpr int kMaxOpened = 16;
std::atomic<void*> g_opened[kMaxOpened];
std::atomic<int> g_openedCount{0};

// --- Which pads -------------------------------------------------------------------------
struct Rule { uint16_t vendor, product; };
Rule g_rules[8];
int g_ruleCount = -1;

void loadRules() {
    if (g_ruleCount >= 0) return;
    g_ruleCount = 0;
    const char* spec = getenv("ANVIL_VIRTUAL_PRO");
    if (!spec) return;
    for (const char* p = spec; *p && g_ruleCount < 8;) {
        unsigned v, pr; int used = 0;
        if (sscanf(p, "%4x:%4x%n", &v, &pr, &used) == 2 && used > 0) {
            g_rules[g_ruleCount++] = {static_cast<uint16_t>(v), static_cast<uint16_t>(pr)};
            p += used;
        }
        const char* next = strpbrk(p, ",;");
        if (!next) break;
        p = next + 1;
    }
}

bool wanted(uint32_t vendor, uint32_t product) {
    loadRules();
    for (int i = 0; i < g_ruleCount; ++i)
        if (g_rules[i].vendor == vendor && g_rules[i].product == product) return true;
    return false;
}

void padLog(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void padLog(const char* fmt, ...) {
    const char* path = getenv("ANVIL_LOG");
    if (!path) return;
    FILE* f = fopen(path, "a");
    if (!f) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(f, fmt, args);
    va_end(args);
    fputc('\n', f);
    fclose(f);
}

double now() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

template <typename T> T readAt(const void* base, size_t offset) {
    T v; memcpy(&v, static_cast<const uint8_t*>(base) + offset, sizeof v); return v;
}
template <typename T> void writeAt(void* base, size_t offset, T v) {
    memcpy(static_cast<uint8_t*>(base) + offset, &v, sizeof v);
}

// --- The virtual device ------------------------------------------------------------------

// What winebus holds. Only the vtable and the reference count are winebus's business.
struct VDevice {
    const void* const* vtable;   // @0
    void* unused[2];             // @8: winebus's list entry, never linked for this device
    int32_t refcount;            // @0x18
    int32_t slot;                // @0x1c
    uint64_t magic;              // @0x20
};
static_assert(offsetof(VDevice, refcount) == kDeviceRefcount, "winebus reads the count at 0x18");
constexpr uint64_t kMagic = 0x6f72702d6c69766eULL;   // "nvil-pro"

constexpr int kSlots = 4;
struct Slot {
    std::atomic<int> state{0};            // 0 free, 1 in use
    std::mutex lock;                      // the emulator and replies: written from any thread
    Emulator emu;
    std::vector<Report> replies;
    VDevice* device = nullptr;            // ours
    void* hidden = nullptr;               // the pad's own device, which Windows never sees
    void* controller = nullptr;           // SDL, read on winebus's thread only
    std::atomic<bool> stopped{false};
    bool released = false;
    PadState last;
    double lastSent = 0, openedAt = 0;
    bool announcedOpen = false, announcedHandshake = false, announcedTraffic = false;
    char name[96] = {};
    uint16_t vendor = 0, product = 0;
};
Slot g_slots[kSlots];

Slot* slotOf(VDevice* d) {
    if (!d || d->magic != kMagic || d->slot < 0 || d->slot >= kSlots) return nullptr;
    return &g_slots[d->slot];
}

bool isOurs(void* device) {
    for (Slot& s : g_slots)
        if (s.state.load() == 1 && s.device == device) return true;
    return false;
}

Slot* hiddenSlot(void* device) {
    for (Slot& s : g_slots)
        if (s.state.load() == 1 && s.hidden == device) return &s;
    return nullptr;
}

// winebus calls these through the vtable, from whichever thread handles the request.
void vDestroy(VDevice* d) {
    if (Slot* s = slotOf(d)) {
        std::lock_guard<std::mutex> hold(s->lock);
        s->device = nullptr;
        s->replies.clear();
        s->state.store(0);
    }
}
uint32_t vStart(VDevice*) { return kStatusSuccess; }
void vStop(VDevice* d) {
    if (Slot* s = slotOf(d)) s->stopped.store(true);
}
uint32_t vDescriptor(VDevice*, uint8_t* buffer, uint32_t length, uint32_t* written) {
    size_t size = 0;
    const uint8_t* d = descriptor(&size);
    *written = static_cast<uint32_t>(size);
    if (size > length) return kStatusBufferTooSmall;
    memcpy(buffer, d, size);
    return kStatusSuccess;
}
void vOutput(VDevice* d, uint8_t* packet, uint8_t* io) {
    const uint8_t* buffer = readAt<const uint8_t*>(packet, 0);
    const uint32_t length = readAt<uint32_t>(packet, 8);
    const uint8_t id = readAt<uint8_t>(packet, 0xc);
    if (Slot* s = slotOf(d); s && buffer && length) {
        // The buffer starts with the report id for a device that numbers its reports; a
        // caller that left it off gets it put back, so the protocol code sees one form.
        uint8_t copy[64] = {};
        const uint8_t* data = buffer;
        size_t n = length;
        if (buffer[0] != id) {
            copy[0] = id;
            n = length + 1 > sizeof copy ? sizeof copy : length + 1;
            memcpy(copy + 1, buffer, n - 1);
            data = copy;
        }
        std::lock_guard<std::mutex> hold(s->lock);
        s->emu.output(data, n, s->replies);
    }
    writeAt<uint32_t>(io, 0, kStatusSuccess);
    writeAt<uint64_t>(io, 8, length);
}
void vFeature(VDevice*, uint8_t*, uint8_t* io) {
    writeAt<uint64_t>(io, 8, 0);
    writeAt<uint32_t>(io, 0, kStatusNotImplemented);
}

const void* const kVtable[] = {
    reinterpret_cast<const void*>(&vDestroy),
    reinterpret_cast<const void*>(&vStart),
    reinterpret_cast<const void*>(&vStop),
    reinterpret_cast<const void*>(&vDescriptor),
    reinterpret_cast<const void*>(&vOutput),
    reinterpret_cast<const void*>(&vFeature),
    reinterpret_cast<const void*>(&vFeature),
};

void releaseOurs(VDevice* d) {
    if (__atomic_sub_fetch(&d->refcount, 1, __ATOMIC_SEQ_CST) == 0) {
        vDestroy(d);
        free(d);
    }
}

void setWide(uint8_t* desc, size_t offset, const char* text) {
    uint16_t wide[kDescStringChars] = {};
    for (size_t i = 0; text[i] && i < kDescStringChars - 1; ++i) wide[i] = static_cast<uint8_t>(text[i]);
    memcpy(desc + offset, wide, sizeof wide);
}

void narrow(const uint8_t* desc, size_t offset, char* out, size_t size) {
    size_t i = 0;
    for (; i + 1 < size && i < kDescStringChars; ++i) {
        const uint16_t c = readAt<uint16_t>(desc, offset + 2 * i);
        if (!c) break;
        out[i] = c < 0x80 ? static_cast<char>(c) : '?';
    }
    out[i] = 0;
}

void* controllerOf(void* device, uint32_t vendor, uint32_t product) {
    void* c = readAt<void*>(device, kSdlDeviceController);
    const int count = g_openedCount.load();
    for (int i = 0; i < count && i < kMaxOpened; ++i)
        if (c && g_opened[i].load() == c) return c;
    // Not one winebus opened through us: take the newest opened controller for this pad.
    for (int i = (count < kMaxOpened ? count : kMaxOpened) - 1; i >= 0; --i) {
        void* candidate = g_opened[i].load();
        if (!candidate || !g_sdl.joystick || !g_sdl.vendor || !g_sdl.product) continue;
        void* joy = g_sdl.joystick(candidate);
        if (joy && g_sdl.vendor(joy) == vendor && g_sdl.product(joy) == product) {
            bool taken = false;
            for (Slot& s : g_slots) if (s.state.load() == 1 && s.controller == candidate) taken = true;
            if (!taken) return candidate;
        }
    }
    return nullptr;
}

/// Hide a newly connected pad from Windows and put a Pro Controller in its place.
bool virtualize(void* device, const uint8_t* desc) {
    const uint32_t vendor = readAt<uint32_t>(desc, kDescVid), product = readAt<uint32_t>(desc, kDescPid);
    if (!wanted(vendor, product) || !g_sdl.button || !g_sdl.axis) return false;
    void* controller = controllerOf(device, vendor, product);
    if (!controller) {
        padLog("[anvil] %04x:%04x connected, but not as a game controller SDL knows — shown as it is", vendor, product);
        return false;
    }
    Slot* slot = nullptr;
    int index = 0;
    for (; index < kSlots; ++index) {
        int expected = 0;
        if (g_slots[index].state.compare_exchange_strong(expected, 1)) { slot = &g_slots[index]; break; }
    }
    if (!slot) return false;

    auto* v = static_cast<VDevice*>(calloc(1, sizeof(VDevice)));
    if (!v) { slot->state.store(0); return false; }
    v->vtable = kVtable;
    v->refcount = 2;              // one for Windows, one held here until it is stopped
    v->slot = index;
    v->magic = kMagic;
    {
        std::lock_guard<std::mutex> hold(slot->lock);
        slot->emu = Emulator(static_cast<uint8_t>(index + 1));
        slot->replies.clear();
        slot->device = v;
        slot->hidden = device;
        slot->controller = controller;
        slot->stopped.store(false);
        slot->released = false;
        slot->last = PadState{};
        slot->lastSent = 0;
        slot->openedAt = now();
        slot->announcedOpen = slot->announcedHandshake = slot->announcedTraffic = false;
        slot->vendor = static_cast<uint16_t>(vendor);
        slot->product = static_cast<uint16_t>(product);
        narrow(desc, kDescProduct, slot->name, sizeof slot->name);
    }

    uint8_t pro[kDescSize];
    memcpy(pro, desc, kDescSize);
    writeAt<uint32_t>(pro, kDescVid, 0x057E);
    writeAt<uint32_t>(pro, kDescPid, 0x2009);
    writeAt<uint32_t>(pro, kDescVersion, 0x0200);
    writeAt<uint32_t>(pro, kDescIsGamepad, 0);     // no XInput copy of this one either
    setWide(pro, kDescManufacturer, "Nintendo Co., Ltd.");
    setWide(pro, kDescProduct, "Pro Controller");
    char serial[16];
    snprintf(serial, sizeof serial, "00000000000%d", index + 1);
    setWide(pro, kDescSerial, serial);

    if (!g_wb.queueCreated(g_wb.queue, v, pro)) {
        std::lock_guard<std::mutex> hold(slot->lock);
        slot->device = nullptr;
        slot->state.store(0);
        free(v);
        return false;
    }
    // The pad's own device is started as Windows would start it, so that winebus has
    // somewhere to put its state: a device that was never started has no report buffer,
    // and winebus writes the first stick movement through that null pointer.
    struct { void* device; } params{device};
    const uint32_t started = g_wb.deviceStart(&params);
    if (started != kStatusSuccess) {
        // Take the Pro Controller back and show the pad as it is.
        slot->controller = nullptr;
        g_wb.queueRemoved(g_wb.queue, v);
        slot->stopped.store(true);
        g_wb.queueCreated(g_wb.queue, device, desc);
        slot->hidden = nullptr;
        padLog("[anvil] %s could not be prepared (status %08x) — shown as it is", slot->name, started);
        return true;   // the original announcement is queued again, so this one is dropped
    }
    padLog("[anvil] %s (%04x:%04x) is shown to the game as a Nintendo Switch Pro Controller that speaks "
           "Nintendo's protocol; the pad itself and its XInput copy are hidden", slot->name, vendor, product);
    return true;
}

/// A hidden pad was unplugged: its Pro Controller goes with it.
void unplug(Slot& s, void* device) {
    s.controller = nullptr;              // SDL closes it as the device stops
    g_wb.queueRemoved(g_wb.queue, s.device);
    // Released the way Windows would release a device it had been shown.
    struct { void* device; } params{device};
    g_wb.deviceRemove(&params);
    s.hidden = nullptr;
    padLog("[anvil] %s disconnected — the Pro Controller made from it is gone too", s.name);
}

uint32_t anvilSdlBusWait(void* args) {
    auto* event = static_cast<uint8_t*>(args);
    for (;;) {
        const uint32_t status = g_wb.sdlBusWait(args);
        if (status != kStatusPending) return status;      // the bus is stopping
        const uint32_t type = readAt<uint32_t>(event, kEventType);
        void* device = readAt<void*>(event, kEventDevice);
        if (isOurs(device)) return status;
        if (type == kEventCreated) {
            if (virtualize(device, event + kEventDesc)) continue;
            return status;
        }
        if (Slot* s = hiddenSlot(device)) {
            if (type == kEventRemoved) unplug(*s, device);
            continue;                                    // the pad's own reports go nowhere
        }
        return status;
    }
}

PadState readPad(void* c) {
    PadState p;
    // SDL's controller buttons, by the letter printed on the pad: Anvil hands SDL a
    // mapping by label for these pads, so SDL's A is the pad's A.
    static const uint32_t order[] = {A, B, X, Y, Minus, Home, Plus, LStick, RStick, L, R, Up, Down, Left, Right, Capture};
    for (int i = 0; i < 16; ++i)
        if (g_sdl.button(c, i)) p.buttons |= order[i];
    if (g_sdl.axis(c, 4) > 9830) p.buttons |= ZL;
    if (g_sdl.axis(c, 5) > 9830) p.buttons |= ZR;
    // SDL has down and right positive; Nintendo has up and right.
    p.lx = clampf(g_sdl.axis(c, 0) / 32767.f, -1.f, 1.f);
    p.ly = clampf(-g_sdl.axis(c, 1) / 32767.f, -1.f, 1.f);
    p.rx = clampf(g_sdl.axis(c, 2) / 32767.f, -1.f, 1.f);
    p.ry = clampf(-g_sdl.axis(c, 3) / 32767.f, -1.f, 1.f);
    return p;
}

// --- Finding winebus ---------------------------------------------------------------------

uint64_t fnv1a(const uint8_t* bytes, size_t length) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < length; ++i) { h ^= bytes[i]; h *= 0x100000001b3ULL; }
    return h;
}

struct Image { const mach_header_64* header; intptr_t slide; };

bool findWinebus(Image& out) {
    const uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        const char* name = _dyld_get_image_name(i);
        if (!name) continue;
        const size_t n = strlen(name);
        if (n < 11 || strcmp(name + n - 11, "/winebus.so") != 0) continue;
        const auto* h = reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(i));
        if (!h || h->magic != MH_MAGIC_64) continue;
        out = {h, _dyld_get_image_vmaddr_slide(i)};
        return true;
    }
    return false;
}

/// Every symbol wanted, local ones included — winebus exports almost nothing.
void resolve(const Image& image, const char* const* names, uintptr_t* found, int count,
             uintptr_t* queues, int maxQueues, int* queueCount) {
    const segment_command_64* linkedit = nullptr;
    const symtab_command* symtab = nullptr;
    const auto* cmd = reinterpret_cast<const load_command*>(image.header + 1);
    for (uint32_t i = 0; i < image.header->ncmds; ++i) {
        if (cmd->cmd == LC_SEGMENT_64) {
            const auto* seg = reinterpret_cast<const segment_command_64*>(cmd);
            if (!strcmp(seg->segname, SEG_LINKEDIT)) linkedit = seg;
        } else if (cmd->cmd == LC_SYMTAB) {
            symtab = reinterpret_cast<const symtab_command*>(cmd);
        }
        cmd = reinterpret_cast<const load_command*>(reinterpret_cast<const uint8_t*>(cmd) + cmd->cmdsize);
    }
    if (!linkedit || !symtab) return;
    const uintptr_t base = linkedit->vmaddr + image.slide - linkedit->fileoff;
    const auto* syms = reinterpret_cast<const nlist_64*>(base + symtab->symoff);
    const char* strings = reinterpret_cast<const char*>(base + symtab->stroff);
    for (uint32_t i = 0; i < symtab->nsyms; ++i) {
        const nlist_64& s = syms[i];
        if ((s.n_type & N_STAB) || (s.n_type & N_TYPE) != N_SECT || s.n_un.n_strx >= symtab->strsize) continue;
        const char* name = strings + s.n_un.n_strx;
        if (!strcmp(name, "_event_queue")) {
            if (*queueCount < maxQueues) queues[(*queueCount)++] = s.n_value + image.slide;
            continue;
        }
        for (int k = 0; k < count; ++k)
            if (!found[k] && !strcmp(name, names[k])) found[k] = s.n_value + image.slide;
    }
}

/// The queue sdl_bus_wait pops from: the `lea reg, [rip + x]` near its start whose
/// target is one of winebus's three event queues.
uintptr_t sdlQueue(uintptr_t wait, const uintptr_t* queues, int queueCount) {
    const auto* code = reinterpret_cast<const uint8_t*>(wait);
    for (int i = 0; i + 7 <= 0x80; ++i) {
        if ((code[i] != 0x48 && code[i] != 0x4c) || code[i + 1] != 0x8d || (code[i + 2] & 0xc7) != 0x05) continue;
        int32_t disp;
        memcpy(&disp, code + i + 3, 4);
        const uintptr_t target = wait + i + 7 + disp;
        for (int q = 0; q < queueCount; ++q)
            if (queues[q] == target) return target;
    }
    return 0;
}

bool writeWord(void** slot, void* value) {
    const mach_vm_address_t page = reinterpret_cast<mach_vm_address_t>(slot) & ~static_cast<mach_vm_address_t>(vm_page_size - 1);
    mach_vm_address_t regionAddr = page;
    mach_vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    if (mach_vm_region(mach_task_self(), &regionAddr, &regionSize, VM_REGION_BASIC_INFO_64,
                       reinterpret_cast<vm_region_info_t>(&info), &infoCount, &object) != KERN_SUCCESS) return false;
    const vm_prot_t original = info.protection;
    if (!(original & VM_PROT_WRITE)
        && mach_vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS
        && mach_vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
        return false;
    __atomic_store_n(slot, value, __ATOMIC_SEQ_CST);
    if (!(original & VM_PROT_WRITE)) mach_vm_protect(mach_task_self(), page, vm_page_size, FALSE, original);
    return *slot == value;
}

} // namespace

// Where anvil_input.mm hands over. -------------------------------------------------------

/// The pad changed: anvil_input.mm reads it every millisecond while it is in use.
extern "C" void AnvilInputNoteActivity();

extern "C" void* AnvilSwitchProControllerOpen(int index) {
    void* c = g_sdl.open ? g_sdl.open(index) : nullptr;
    if (c) {
        const int i = g_openedCount.fetch_add(1);
        g_opened[i % kMaxOpened].store(c);
    }
    return c;
}

/// Called as winebus resolves each SDL function; returns what winebus should be given.
extern "C" void* AnvilSwitchProSDLSymbol(void* handle, const char* symbol, void* real) {
    if (!getenv("ANVIL_VIRTUAL_PRO")) return real;
    if (!g_sdl.button) {
        g_sdl.joystick = reinterpret_cast<CtrlJoystickFn>(dlsym(handle, "SDL_GameControllerGetJoystick"));
        g_sdl.vendor = reinterpret_cast<JoyU16Fn>(dlsym(handle, "SDL_JoystickGetVendor"));
        g_sdl.product = reinterpret_cast<JoyU16Fn>(dlsym(handle, "SDL_JoystickGetProduct"));
        g_sdl.axis = reinterpret_cast<CtrlAxisFn>(dlsym(handle, "SDL_GameControllerGetAxis"));
        g_sdl.rumble = reinterpret_cast<CtrlRumbleFn>(dlsym(handle, "SDL_GameControllerRumble"));
        g_sdl.button = reinterpret_cast<CtrlButtonFn>(dlsym(handle, "SDL_GameControllerGetButton"));
    }
    if (!strcmp(symbol, "SDL_GameControllerOpen")) {
        g_sdl.open = reinterpret_cast<CtrlOpenFn>(real);
        return reinterpret_cast<void*>(&AnvilSwitchProControllerOpen);
    }
    return real;
}

/// Once, as winebus starts its SDL bus: check winebus is the build this was read from,
/// and take over the wait that hands its events to Windows.
extern "C" void AnvilSwitchProInstall() {
    if (!getenv("ANVIL_VIRTUAL_PRO") || g_tried.exchange(true)) return;
    Image image{};
    if (!findWinebus(image)) { padLog("[anvil] Pro Controller: winebus not found — pads shown as they are"); return; }

    static const char* const names[] = {
        "_sdl_bus_wait", "_unix_device_remove", "_unix_device_start", "_unix_device_get_report_descriptor",
        "_unix_device_set_output_report", "_bus_event_cleanup", "_bus_event_queue_device_removed",
        "_bus_event_queue_device_created", "_bus_event_queue_input_report", "_bus_event_queue_pop",
        "___wine_unix_call_funcs",
    };
    constexpr int kNames = sizeof names / sizeof names[0];
    uintptr_t found[kNames] = {};
    uintptr_t queues[4] = {};
    int queueCount = 0;
    resolve(image, names, found, kNames, queues, 4, &queueCount);

    for (const Fingerprint& f : kFingerprints) {
        uintptr_t address = 0;
        for (int k = 0; k < kNames; ++k) if (!strcmp(names[k], f.symbol)) address = found[k];
        if (!address || fnv1a(reinterpret_cast<const uint8_t*>(address), f.length) != f.fnv) {
            padLog("[anvil] Pro Controller: this engine's winebus is a build Anvil has not checked (%s) — "
                   "pads shown as they are", f.symbol + 1);
            return;
        }
    }
    const uintptr_t queue = sdlQueue(found[0], queues, queueCount);
    auto** table = reinterpret_cast<void**>(found[kNames - 1]);
    void** entry = nullptr;
    for (int i = 0; table && i < 64; ++i)
        if (table[i] == reinterpret_cast<void*>(found[0])) { entry = &table[i]; break; }
    if (!queue || !entry) {
        padLog("[anvil] Pro Controller: winebus's event queue not found — pads shown as they are");
        return;
    }
    g_wb.sdlBusWait = reinterpret_cast<UnixCall>(found[0]);
    g_wb.deviceRemove = reinterpret_cast<UnixCall>(found[1]);
    g_wb.deviceStart = reinterpret_cast<UnixCall>(found[2]);
    g_wb.queueRemoved = reinterpret_cast<QueueRemovedFn>(found[6]);
    g_wb.queueCreated = reinterpret_cast<QueueCreatedFn>(found[7]);
    g_wb.queueInput = reinterpret_cast<QueueInputFn>(found[8]);
    g_wb.queue = reinterpret_cast<void*>(queue);
    g_ready.store(true);
    if (!writeWord(entry, reinterpret_cast<void*>(&anvilSdlBusWait))) {
        g_ready.store(false);
        padLog("[anvil] Pro Controller: winebus's call table is not writable — pads shown as they are");
        return;
    }
    padLog("[anvil] winedevice (pid %d): Pro Controller support ready — winebus matches the checked build", getpid());
}

/// On winebus's own thread, about once a millisecond: answers to what the game wrote,
/// and the pad's state whenever it changes — and every 15 ms regardless, as the real
/// controller streams, so a game waiting on a report never waits long.
extern "C" void AnvilSwitchProTick() {
    if (!g_ready.load(std::memory_order_relaxed)) return;
    const double t = now();
    for (Slot& s : g_slots) {
        if (s.state.load() != 1 || !s.device) continue;
        VDevice* d = s.device;
        if (s.stopped.load()) {
            if (!s.released) { s.released = true; releaseOurs(d); }
            continue;
        }
        if (!s.controller) continue;
        const PadState pad = readPad(s.controller);
        std::vector<Report> out;
        float left = 0, right = 0;
        bool rumble = false, opened = false, handshake = false;
        uint64_t reports = 0, commands = 0;
        {
            std::lock_guard<std::mutex> hold(s.lock);
            out.swap(s.replies);
            if (pad != s.last) AnvilInputNoteActivity();
            if (pad != s.last || t - s.lastSent >= 0.015) {
                s.emu.setState(pad);
                out.push_back(s.emu.inputReport());
                s.last = pad;
                s.lastSent = t;
            }
            rumble = s.emu.takeRumble(left, right);
            opened = s.emu.gotStatusRequest();
            handshake = s.emu.handshakeDone();
            reports = s.emu.reportsSent();
            commands = s.emu.subcommandsSeen();
        }
        for (const Report& r : out) g_wb.queueInput(g_wb.queue, d, r.data(), static_cast<uint32_t>(r.size()));
        if (rumble && g_sdl.rumble)
            g_sdl.rumble(s.controller, static_cast<uint16_t>(left * 65535.f), static_cast<uint16_t>(right * 65535.f),
                         (left > 0 || right > 0) ? 5000 : 0);
        if (opened && !s.announcedOpen) {
            s.announcedOpen = true;
            padLog("[anvil] the game opened the Pro Controller and asked for its status");
        }
        if (handshake && !s.announcedHandshake) {
            s.announcedHandshake = true;
            padLog("[anvil] the game completed the Pro Controller's USB handshake — it now reads the pad through "
                   "its own Switch Pro support");
        }
        if (!s.announcedTraffic && t - s.openedAt > 20.0) {
            s.announcedTraffic = true;
            padLog("[anvil] Pro Controller after 20 s: %llu reports sent, %llu commands from the game answered%s",
                   (unsigned long long)reports, (unsigned long long)commands,
                   s.announcedHandshake ? "" : " — the game never completed the handshake");
        }
    }
}

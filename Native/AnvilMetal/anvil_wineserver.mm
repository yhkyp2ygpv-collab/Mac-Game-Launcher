// Controller reports read in a batch arrive without their data — a Wine 7.7 server bug.
//
// A game reads raw input two ways: GetRawInputData for the WM_INPUT message in hand,
// and GetRawInputBuffer for everything still queued behind it. Rewired, the input
// library in many Unity games, uses both: the message it was handed, then the backlog.
//
// Wine 7.7's server answers GetRawInputBuffer by copying each queued message — a
// 0x38-byte header followed by the HID report — into a reply buffer, and then moving
// its write position forward by the header alone. The next message is written over
// the previous one's report, and the reply length counts headers only, so the report
// bytes of every batched message are lost or replaced by the header of the one after.
// The game reads stale memory and garbage as button and stick state. Keyboard and
// mouse messages have no report bytes, which is why they were never affected.
//
// It only bites when messages are queued, which is when the game is briefly behind —
// the moment a controller "lags". Then it reads garbage as input (the inputs the
// player never made), garbage device handles make Wine rebuild its device list on the
// game's main thread (the multi-second freezes), and buttons whose release was lost
// stay held until a focus change resets input (the cmd-tab that "fixed" it).
//
// Wine 8.0 fixed it in the server: the position advances by the whole message
// (`pos += sizeof(*data) + extra_size`). The client side of 7.7 already expects that.
// Anvil's library is loaded into wineserver like every Wine process, so it replaces
// that one request handler with the corrected one before the server starts — but only
// in a wineserver whose handler matches, byte for byte, the build this was read from.
// Any other build is left exactly as it is.

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <unistd.h>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <atomic>

namespace {

// Layout of the Wine 7.7 wineserver shipped by Whisky 2.5 and Mythic Engine 2.6, taken
// from the handler's own machine code. Valid only when the fingerprint below matches.
constexpr size_t   kThreadQueue      = 0xa8;    // struct thread: struct msg_queue *queue
constexpr size_t   kThreadReplyMax   = 0x168;   // struct thread: req.request_header.reply_size
constexpr size_t   kThreadReplyData  = 0x1b0;   // struct thread: void *reply_data
constexpr size_t   kThreadReplySize  = 0x1b8;   // struct thread: data_size_t reply_size
constexpr size_t   kQueueInput       = 0xf0;    // struct msg_queue: struct thread_input *input
constexpr size_t   kInputMsgList     = 0x88;    // struct thread_input: struct list msg_list
constexpr size_t   kMessageCode      = 0x18;    // struct message: unsigned int msg
constexpr size_t   kMessageData      = 0x40;    // struct message: void *data
constexpr size_t   kMessageResult    = 0x50;    // struct message: struct message_result *result
constexpr size_t   kHwDataSize       = 0x08;    // struct hardware_msg_data: data_size_t size
constexpr uint32_t kHwDataHeader     = 0x38;    // sizeof(struct hardware_msg_data)
constexpr uint32_t kWmInput          = 0x00ff;
// get_rawinput_buffer request: rawinput_size @0x0c, buffer_size @0x10.
// get_rawinput_buffer reply:   next_size @0x08, count @0x0c.

constexpr size_t   kHandlerLength      = 0x26a;
constexpr uint64_t kHandlerFingerprint = 0x826dddb6a80a1b35ULL;   // FNV-1a of those bytes

struct List { List* next; List* prev; };

void** g_current = nullptr;                     // &current, the thread whose request this is
std::atomic<uint64_t> g_reportsBatched{0};      // controller reports that went out intact
std::atomic<uint64_t> g_nextReport{1};

inline uint32_t read32(const void* p) { uint32_t v; memcpy(&v, p, 4); return v; }
inline void write32(void* p, uint32_t v) { memcpy(p, &v, 4); }
template <typename T> inline T readPtr(const void* p) { T v; memcpy(&v, p, sizeof v); return v; }

void serverLog(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void serverLog(const char* fmt, ...) {
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

[[maybe_unused]] uint64_t fnv1a(const uint8_t* bytes, size_t length) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < length; ++i) { h ^= bytes[i]; h *= 0x100000001b3ULL; }
    return h;
}

} // namespace

// Wine 8.0's get_rawinput_buffer, over this build's structures. Same order, same limits,
// same messages removed; the only change from 7.7 is where the next message is written.
extern "C" void AnvilGetRawinputBuffer(const uint8_t* req, uint8_t* reply) {
    uint8_t* thread = g_current ? static_cast<uint8_t*>(*g_current) : nullptr;
    if (!thread) return;
    uint8_t* queue = readPtr<uint8_t*>(thread + kThreadQueue);
    if (!queue) return;
    uint8_t* input = readPtr<uint8_t*>(queue + kQueueInput);
    if (!input) return;

    const uint32_t rawinputSize = read32(req + 0x0c);
    const uint32_t bufferSize   = read32(req + 0x10);
    const uint32_t replyMax     = read32(thread + kThreadReplyMax);

    uint32_t size = 0, nextSize = 0, pos = 0, count = 0, hid = 0;
    uint32_t bufCapacity = 16 * kHwDataHeader;
    char* buf = nullptr;
    if (bufferSize && !(buf = static_cast<char*>(malloc(bufCapacity)))) return;

    List* head = reinterpret_cast<List*>(input + kInputMsgList);
    for (List* ptr = head->next; ptr && ptr != head;) {
        uint8_t* msg = reinterpret_cast<uint8_t*>(ptr);
        List* following = ptr->next;
        if (read32(msg + kMessageCode) != kWmInput) { ptr = following; continue; }

        uint8_t* data = readPtr<uint8_t*>(msg + kMessageData);
        if (!data) break;
        const uint32_t dataSize = read32(data + kHwDataSize);
        if (dataSize < kHwDataHeader) break;
        const uint32_t extra = dataSize - kHwDataHeader;

        nextSize = rawinputSize + extra;
        if (size + nextSize > bufferSize) break;
        if (pos + dataSize > replyMax) break;
        // Hardware messages never carry a sender's result. If one ever did, settling it
        // is the server's business, so the message is left where it is.
        if (readPtr<void*>(msg + kMessageResult)) break;
        if (pos + dataSize > bufCapacity) {
            uint32_t grown = bufCapacity;
            while (pos + dataSize > grown) grown += grown / 2 + extra;
            char* larger = static_cast<char*>(realloc(buf, grown));
            if (!larger) break;              // send what fits rather than nothing
            buf = larger; bufCapacity = grown;
        }

        memcpy(buf + pos, data, dataSize);
        ptr->next->prev = ptr->prev;         // list_remove
        ptr->prev->next = ptr->next;
        free(data);                          // free_message, for a message with no result
        free(msg);

        size += nextSize;
        pos  += dataSize;                    // 7.7 advanced by kHwDataHeader here
        ++count;
        if (extra) ++hid;
        ptr = following;
    }

    write32(reply + 0x08, nextSize);
    write32(reply + 0x0c, count);
    if (!pos) { free(buf); buf = nullptr; }
    memcpy(thread + kThreadReplyData, &buf, sizeof buf);
    write32(thread + kThreadReplySize, pos);

    if (hid) {
        const uint64_t total = g_reportsBatched.fetch_add(hid, std::memory_order_relaxed) + hid;
        uint64_t due = g_nextReport.load(std::memory_order_relaxed);
        if (total >= due && g_nextReport.compare_exchange_strong(due, due * 4)) {
            serverLog("[anvil] wineserver: %llu queued controller reports delivered with their data "
                      "(Wine 7.7 would have sent them without it)", (unsigned long long)total);
        }
    }
}

#ifndef ANVIL_WINESERVER_TEST
namespace {

// The handler table is a static array of function pointers in the server's data. It
// is not exported, so it is found by value: the one slot that holds the handler.
void** findHandlerSlot(void* handler) {
    const auto* header = reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(0));
    const intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    if (!header || header->magic != MH_MAGIC_64) return nullptr;

    void** found = nullptr;
    int matches = 0;
    const auto* cmd = reinterpret_cast<const load_command*>(header + 1);
    for (uint32_t i = 0; i < header->ncmds; ++i) {
        if (cmd->cmd == LC_SEGMENT_64) {
            const auto* seg = reinterpret_cast<const segment_command_64*>(cmd);
            if (!strcmp(seg->segname, "__DATA") || !strcmp(seg->segname, "__DATA_CONST")) {
                const auto* sect = reinterpret_cast<const section_64*>(seg + 1);
                for (uint32_t s = 0; s < seg->nsects; ++s, ++sect) {
                    const uint32_t type = sect->flags & SECTION_TYPE;
                    if (type == S_ZEROFILL || type == S_GB_ZEROFILL || type == S_THREAD_LOCAL_ZEROFILL) continue;
                    auto** slot = reinterpret_cast<void**>(sect->addr + slide);
                    const size_t n = sect->size / sizeof(void*);
                    for (size_t k = 0; k < n; ++k) {
                        if (slot[k] == handler) { found = &slot[k]; ++matches; }
                    }
                }
            }
        }
        cmd = reinterpret_cast<const load_command*>(reinterpret_cast<const uint8_t*>(cmd) + cmd->cmdsize);
    }
    return matches == 1 ? found : nullptr;
}

bool isRequestHandler(void* fn) {
    Dl_info info;
    return fn && dladdr(fn, &info) && info.dli_sname && !strncmp(info.dli_sname, "req_", 4);
}

bool writeSlot(void** slot, void* value) {
    const mach_vm_address_t page = reinterpret_cast<mach_vm_address_t>(slot) & ~static_cast<mach_vm_address_t>(vm_page_size - 1);
    mach_vm_address_t regionAddr = page;
    mach_vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    if (mach_vm_region(mach_task_self(), &regionAddr, &regionSize, VM_REGION_BASIC_INFO_64,
                       reinterpret_cast<vm_region_info_t>(&info), &infoCount, &object) != KERN_SUCCESS) return false;
    const vm_prot_t original = info.protection;
    if (!(original & VM_PROT_WRITE)) {
        if (mach_vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS &&
            mach_vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
            return false;
    }
    *slot = value;
    if (!(original & VM_PROT_WRITE)) mach_vm_protect(mach_task_self(), page, vm_page_size, FALSE, original);
    return *slot == value;
}

__attribute__((constructor))
void anvilFixRawinputBuffer() {
    void* handler = dlsym(RTLD_MAIN_ONLY, "req_get_rawinput_buffer");
    if (!handler) return;                                   // not a wineserver
    const char* enabled = getenv("ANVIL_RAWINPUT_FIX");
    if (!enabled || enabled[0] != '1') {
        serverLog("[anvil] wineserver: raw-input batch fix off for this session");
        return;
    }
    const uint64_t print = fnv1a(static_cast<const uint8_t*>(handler), kHandlerLength);
    if (print != kHandlerFingerprint) {
        serverLog("[anvil] wineserver: raw-input handler is a different build (%016llx) — left unchanged",
                  (unsigned long long)print);
        return;
    }
    g_current = static_cast<void**>(dlsym(RTLD_MAIN_ONLY, "current"));
    if (!g_current) { serverLog("[anvil] wineserver: 'current' not found — left unchanged"); return; }

    void** slot = findHandlerSlot(handler);
    if (!slot || !isRequestHandler(slot[-1]) || !isRequestHandler(slot[1])) {
        serverLog("[anvil] wineserver: request table not found — left unchanged");
        return;
    }
    if (!writeSlot(slot, reinterpret_cast<void*>(&AnvilGetRawinputBuffer))) {
        serverLog("[anvil] wineserver: request table not writable — left unchanged");
        return;
    }
    serverLog("[anvil] wineserver (pid %d): Wine 7.7 raw-input batch read corrected — queued controller "
              "reports now reach the game with their data", getpid());
}

} // namespace
#endif

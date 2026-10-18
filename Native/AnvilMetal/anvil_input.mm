// Controller input latency.
//
// Wine's winebus drives controllers through SDL, and SDL's macOS joystick backend
// polls: it reads each element with IOHIDDeviceGetValue rather than taking the
// input-value callback. So a pad's state is only observed when SDL is pumped, and
// winebus pumps it from a SDL_WaitEventTimeout loop. That timeout is the polling
// interval, and it is the floor on controller latency — while keyboard and mouse
// bypass all of this, arriving as events through Wine's Mac driver, which is why
// only the controller feels late.
//
// winebus resolves SDL through dlsym rather than linking it, so the function cannot
// be interposed directly. dlsym itself can be: when winebus asks for
// SDL_WaitEventTimeout it is handed a wrapper that shortens the timeout, and every
// other symbol passes through untouched.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <cstring>
#import <cstdio>
#import <cstdlib>
#import <cmath>
#import <atomic>
#import <chrono>
#import <os/log.h>
#import <notify.h>
#import <algorithm>
#import <ctime>

extern "C" const char* anvil_front_notify_name(void);

// --- A pad shown as a Switch Pro Controller ----------------------------------------
// See anvil_switchpro.mm. It needs a few of SDL's functions, one wrapped, and a tick on
// winebus's own thread, which this wait is.
extern "C" void* AnvilSwitchProSDLSymbol(void* handle, const char* symbol, void* real);
extern "C" void AnvilSwitchProInstall();
extern "C" void AnvilSwitchProTick();

namespace {

using WaitEventTimeoutFn = int (*)(void* event, int timeout);
std::atomic<WaitEventTimeoutFn> g_realWait{nullptr};

/// Milliseconds. Wine's own loop asks for a considerably longer wait; this is the
/// value it gets instead. One millisecond against a pad that reports every four is
/// enough to never be the limiting factor, and the loop is idle in between rather
/// than spinning — SDL_WaitEventTimeout sleeps until an event or the timeout.
int g_pollMs = 1;
std::atomic<uint64_t> g_waitCalls{0};
std::atomic<int> g_observedTimeout{-1};

// --- How often the pad is read ------------------------------------------------------
// SDL started without its video part, as winebus starts it, reads every pad once a
// millisecond while it waits, whatever the wait — through IOKit, one element at a time,
// under Rosetta. On 3 October that thread in winedevice took a quarter of a core for the
// whole session, LEGO Star Wars paused behind another app included, and woke the Mac a
// thousand times a second. So the waiting is done here: one read of the pad after
//   - g_pollMs (1 ms) while it is in use, which is how it has always felt;
//   - 4 ms once it has been left alone for five seconds — the first press after that is
//     at most 4 ms later, and everything after it is read every millisecond again;
//   - Wine's own wait (10 ms) while the game isn't the app in front.
constexpr int kRestingPollMs = 4;
constexpr double kRestingAfterSec = 5.0;
std::atomic<double> g_lastActivity{0.0};

// --- Controller event filter -------------------------------------------------------
// Every controller event Wine receives becomes one HID report, and in Wine 7.7 every
// HID report becomes a WM_INPUT message whose data arrives empty. Unity rejects each
// one with "Invalid raw input data size: 0 bytes", walks the stack and writes it to
// its log, on the game's main thread — 2,004 times in 32 seconds of Cat Quest II,
// during which the game fell below 30 fps. Keyboard and mouse raw input arrives
// intact, which is why they never lagged and the controller always did.
//
// This drops the events that carry nothing: an axis resting inside a small zone
// around centre (a hall-effect stick flickers between adjacent values while
// untouched), and exact repeats. Buttons are never touched. Movement out of the zone,
// and the return to it, always go through.
//
// SDL_ControllerAxisEvent, stable across SDL 2.x: type u32 @0, which s32 @8,
// axis u8 @12, value s16 @16.
constexpr uint32_t kControllerAxisMotion = 0x650;
constexpr size_t kEventSize = 56;               // sizeof(SDL_Event) in SDL 2.x

// Per axis: the value Wine last received, when, and the newest value waiting to go.
struct AxisState {
    int16_t last = 0; bool seen = false;
    double lastSentAt = 0;
    bool pending = false; uint8_t pendingEvent[kEventSize];
};
AxisState g_axes[8][8];
std::atomic<uint64_t> g_delivered{0};
std::atomic<uint64_t> g_dropped{0};
std::atomic<uint64_t> g_merged{0};
std::atomic<int> g_filterState{-1};
double g_intervalSec = 0.008;                   // one stick update per axis per 8 ms

double nowSec() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

bool filterEnabled() {
    int s = g_filterState.load(std::memory_order_relaxed);
    if (s < 0) {
        const char* e = getenv("ANVIL_INPUT_FILTER");
        s = (e && e[0] == '1') ? 1 : 0;
        if (const char* hz = getenv("ANVIL_INPUT_AXIS_HZ")) {
            const int v = atoi(hz);
            if (v >= 30 && v <= 1000) g_intervalSec = 1.0 / v;
        }
        g_filterState.store(s, std::memory_order_relaxed);
    }
    return s == 1;
}


// What to do with an axis event just read from SDL.
enum class Verdict { deliver, drop, hold };
Verdict classify(const uint8_t* ev, double now) {
    uint32_t type; memcpy(&type, ev, 4);
    if (type != kControllerAxisMotion) return Verdict::deliver;
    int32_t which; memcpy(&which, ev + 8, 4);
    const uint8_t axis = ev[12];
    int16_t value; memcpy(&value, ev + 16, 2);
    if (axis >= 8) return Verdict::deliver;
    AxisState& a = g_axes[static_cast<uint32_t>(which) & 7][axis];
    const bool trigger = (axis == 4 || axis == 5);
    // Only exact repeats are dropped. A rule that also dropped small moves inside a
    // resting zone around centre was removed after a scripted test caught it leaving a
    // released stick at 1000 instead of 0: the final steps back to centre all fell
    // inside the zone. The pad sends nothing at true rest, so it bought nothing.
    (void)trigger;
    if (a.seen && !a.pending && value == a.last) return Verdict::drop;
    if (a.seen && now - a.lastSentAt < g_intervalSec) {
        // Too soon after the last update for this axis: keep only the newest value.
        // It goes out when the interval is up, so a released stick still returns to
        // centre — it is never lost, only merged with the values it superseded.
        if (a.pending) g_merged.fetch_add(1, std::memory_order_relaxed);
        memcpy(a.pendingEvent, ev, kEventSize);
        a.pending = true;
        return Verdict::hold;
    }
    a.last = value; a.seen = true; a.lastSentAt = now; a.pending = false;
    return Verdict::deliver;
}

// A held value whose interval has passed, copied out for delivery.
bool takeDue(void* out, double now) {
    for (auto& row : g_axes) for (auto& a : row) {
        if (!a.pending || now - a.lastSentAt < g_intervalSec) continue;
        memcpy(out, a.pendingEvent, kEventSize);
        int16_t value; memcpy(&value, a.pendingEvent + 16, 2);
        a.last = value; a.seen = true; a.lastSentAt = now; a.pending = false;
        return true;
    }
    return false;
}

void reportFilter() {
    static std::atomic<uint64_t> lastReport{0};
    const uint64_t total = g_delivered.load(std::memory_order_relaxed) + g_dropped.load(std::memory_order_relaxed)
                         + g_merged.load(std::memory_order_relaxed);
    uint64_t prev = lastReport.load(std::memory_order_relaxed);
    if (total < prev + 2000) return;
    if (!lastReport.compare_exchange_strong(prev, total)) return;
    if (const char* logPath = getenv("ANVIL_LOG")) {
        if (FILE* f = fopen(logPath, "a")) {
            fprintf(f, "[anvil] controller events: %llu passed to Wine, %llu merged into newer stick values, %llu dropped as resting or repeats%s\n",
                    (unsigned long long)g_delivered.load(), (unsigned long long)g_merged.load(),
                    (unsigned long long)g_dropped.load(), filterEnabled() ? "" : " (filter off)");
            fclose(f);
        }
    }
}

void noteActivity() { g_lastActivity.store(nowSec(), std::memory_order_relaxed); }

/// The game's process says whether it is in front (anvil_window.mm); 0, never said, is in front.
bool gameInFront() {
    static int token = -1;
    static bool registered = false, front = true;
    if (!registered) {
        registered = true;
        if (notify_register_check(anvil_front_notify_name(), &token) != NOTIFY_STATUS_OK) token = -1;
    }
    int changed = 0;
    if (token >= 0 && notify_check(token, &changed) == NOTIFY_STATUS_OK && changed) {
        uint64_t state = 0;
        if (notify_get_state(token, &state) == NOTIFY_STATUS_OK) front = state != 1;
    }
    return front;
}

int pollIntervalMs(int timeout) {
    if (!gameInFront()) return std::max(g_pollMs, std::min(timeout, 16));
    if (nowSec() - g_lastActivity.load(std::memory_order_relaxed) > kRestingAfterSec)
        return std::max(g_pollMs, std::min(kRestingPollMs, timeout));
    return std::min(g_pollMs, timeout);
}

/// One read of the pads after the interval above, or at once when the last read left
/// more events waiting. Only winebus's own thread calls this.
int readPads(WaitEventTimeoutFn real, void* event, int timeout) {
    static bool more = false;
    if (timeout <= 0) return real(event, 0);
    if (more) {
        const int got = real(event, 0);
        if (got != 0) return got;
    }
    const int ms = pollIntervalMs(timeout);
    struct timespec nap{0, static_cast<long>(ms) * 1000000L};
    nanosleep(&nap, nullptr);
    const int got = real(event, 0);
    more = got != 0;
    if (got == 1) noteActivity();
    return got;
}

int waitAndFilter(void* event, int timeout) {
    auto real = g_realWait.load(std::memory_order_acquire);
    if (!real) return 0;
    g_waitCalls.fetch_add(1, std::memory_order_relaxed);
    // Record what Wine asks for, once, so the size of the change is known rather
    // than assumed.
    int none = -1;
    if (g_observedTimeout.compare_exchange_strong(none, timeout)) {
        if (const char* logPath = getenv("ANVIL_LOG")) {
            if (FILE* f = fopen(logPath, "a")) {
                fprintf(f, "[anvil] Wine asked SDL to wait %d ms; the pad is read every %d ms while it's in use, "
                           "%d ms once left alone, %d ms while the game is behind another app\n",
                        timeout, std::min(g_pollMs, timeout), std::max(g_pollMs, std::min(kRestingPollMs, timeout)),
                        std::max(g_pollMs, std::min(timeout, 16)));
                fclose(f);
            }
        }
    }
    if (!filterEnabled() || !event) return readPads(real, event, timeout);

    // A held stick value that is now due goes first, before waiting for anything new.
    const double now = nowSec();
    if (takeDue(event, now)) { g_delivered.fetch_add(1, std::memory_order_relaxed); reportFilter(); return 1; }

    const int got = readPads(real, event, timeout);
    if (got != 1) return got;
    switch (classify(static_cast<const uint8_t*>(event), nowSec())) {
    case Verdict::deliver:
        g_delivered.fetch_add(1, std::memory_order_relaxed); reportFilter(); return 1;
    case Verdict::drop:
        g_dropped.fetch_add(1, std::memory_order_relaxed); reportFilter(); return 0;
    case Verdict::hold:
        return 0;   // Wine treats 0 as "nothing yet" and asks again within a millisecond
    }
    return got;
}

int anvilWaitEventTimeout(void* event, int timeout) {
    const int got = waitAndFilter(event, timeout);
    // After the wait, so a change SDL has just read goes out in this same pass.
    AnvilSwitchProTick();
    return got;
}

} // namespace

extern "C" uint64_t AnvilInputWaitCalls() { return g_waitCalls.load(); }
/// The Switch Pro emulation saw the pad change: it is in use.
extern "C" void AnvilInputNoteActivity() { noteActivity(); }
extern "C" int AnvilInputPollMs() { return g_pollMs; }
extern "C" int AnvilInputObservedTimeout() { return g_observedTimeout.load(); }

extern "C" void* anvil_dlsym(void* handle, const char* symbol) {
    void* result = dlsym(handle, symbol);
    if (!result || !symbol) return result;

    // Only when Anvil asked for it, so nothing changes for anyone else.
    if (!strncmp(symbol, "SDL_", 4) && getenv("ANVIL_VIRTUAL_PRO")) {
        result = AnvilSwitchProSDLSymbol(handle, symbol, result);
        // winebus asks for this as its SDL bus starts, before any pad is seen.
        if (!strcmp(symbol, "SDL_WaitEventTimeout")) AnvilSwitchProInstall();
    }

    if (strcmp(symbol, "SDL_WaitEventTimeout") == 0) {
        WaitEventTimeoutFn expected = nullptr;
        g_realWait.compare_exchange_strong(expected,
                                           reinterpret_cast<WaitEventTimeoutFn>(result));
        if (const char* p = getenv("ANVIL_INPUT_POLL_MS")) {
            const int v = atoi(p);
            if (v >= 1 && v <= 16) g_pollMs = v;
        }
        os_log(OS_LOG_DEFAULT, "[anvil] SDL_WaitEventTimeout intercepted, poll %dms", g_pollMs);
        if (const char* logPath = getenv("ANVIL_LOG")) {
            if (FILE* f = fopen(logPath, "a")) {
                fprintf(f, "[anvil] SDL_WaitEventTimeout intercepted — controller poll %d ms\n",
                        g_pollMs);
                fclose(f);
            }
        }
        return reinterpret_cast<void*>(&anvilWaitEventTimeout);
    }
    return result;
}

// dlsym is in libdyld, which is two-level namespaced, so an interpose record is the
// way to replace it for everyone in the process.
__attribute__((used, section("__DATA,__interpose")))
static struct {
    void* replacement;
    void* original;
} anvil_dlsym_interpose = {
    reinterpret_cast<void*>(&anvil_dlsym),
    reinterpret_cast<void*>(&dlsym),
};

// ---------------------------------------------------------------------------------
// Game threads at interactive priority.
//
// Wine creates every Windows thread with pthread_create and gives it macOS's default
// quality of service. On Apple silicon that lets the scheduler run a game's main and
// render threads on efficiency cores, and a CPU-bound game — which a Windows game
// through Rosetta usually is — misses frames when it lands there. Measured on Cat
// Quest II: the game held 120 fps on the title screen but fell to 80–109 fps rendered
// in real play, at half resolution, so the GPU was not the limit.
//
// Wrapping the start routine rather than editing the thread attributes: an attributes
// object must not be copied, and the start routine is ours to wrap. Each thread
// raises itself to user-interactive before running Wine's code. A thread that Wine
// has given an explicit scheduling policy refuses the change, which is harmless.
#import <pthread.h>
#import <pthread/qos.h>

namespace {
struct AnvilThreadStart { void* (*fn)(void*); void* arg; };
std::atomic<int> g_qosState{-1};           // -1 unread, 0 off, 1 on
std::atomic<int> g_qosRaised{0};

bool qosEnabled() {
    int s = g_qosState.load(std::memory_order_relaxed);
    if (s < 0) {
        const char* e = getenv("ANVIL_THREAD_QOS");
        s = (e && e[0] == '1') ? 1 : 0;
        g_qosState.store(s, std::memory_order_relaxed);
    }
    return s == 1;
}

void* anvilThreadTrampoline(void* p) {
    AnvilThreadStart start = *static_cast<AnvilThreadStart*>(p);
    free(p);
    if (pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) == 0) {
        if (g_qosRaised.fetch_add(1, std::memory_order_relaxed) == 0) {
            if (const char* logPath = getenv("ANVIL_LOG")) {
                if (FILE* f = fopen(logPath, "a")) {
                    fprintf(f, "[anvil] game threads raised to interactive priority (pid %d)\n", getpid());
                    fclose(f);
                }
            }
        }
    }
    return start.fn(start.arg);
}
} // namespace

extern "C" void anvil_ensure_setup(const char* where);

extern "C" int anvil_pthread_create(pthread_t* thread, const pthread_attr_t* attr,
                                    void* (*fn)(void*), void* arg) {
    // The interceptor's set-up, the first chance there is in a process Wine started
    // (see anvil_ensure_setup): a game makes threads long before its first frame.
    anvil_ensure_setup("first thread");
    if (!fn || !qosEnabled()) return pthread_create(thread, attr, fn, arg);
    auto* start = static_cast<AnvilThreadStart*>(malloc(sizeof(AnvilThreadStart)));
    if (!start) return pthread_create(thread, attr, fn, arg);
    start->fn = fn;
    start->arg = arg;
    int r = pthread_create(thread, attr, anvilThreadTrampoline, start);
    if (r != 0) free(start);
    return r;
}

__attribute__((used, section("__DATA,__interpose")))
static struct { void* replacement; void* original; } anvil_pthread_interpose = {
    reinterpret_cast<void*>(&anvil_pthread_create),
    reinterpret_cast<void*>(&pthread_create),
};

// The process's first thread is not created by pthread_create, so raise it here.
__attribute__((constructor))
static void anvilRaiseInitialThread() {
    if (qosEnabled()) pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
}

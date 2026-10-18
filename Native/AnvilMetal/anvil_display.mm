// Keep the display's own mode when a game only asks for a different refresh rate.
//
// A game in exclusive full screen asks Windows for a display mode — LEGO Star Wars asks
// for its resolution at 60 Hz, or at 120 once changed in its options. Wine's Mac driver
// honours that by capturing every display and switching to the matching macOS mode.
// On a MacBook Pro that switch takes the panel out of ProMotion: every macOS mode with a
// stated rate is a fixed one. Measured: in LEGO Star Wars Anvil read the panel as fixed
// refresh (NSScreen, after the switch), while Cat Quest II, which never switches, showed
// displayed gaps of exactly 12.5 ms at 80 fps — the panel following the game. Below 120
// a fixed panel rounds every frame to 8.3 or 16.7 ms, which is the stutter in heavy
// scenes; at 60 Hz it also capped the game at 60.
//
// So when the mode a game asks for has the same size in points and in pixels as the one
// the display is already in — only the rate or flags differ — the switch is skipped and
// reported as done. The capture Wine makes first is held back until a switch that
// actually changes the resolution needs it, so a real resolution change still gets
// macOS's capture and its automatic restore if the game dies.

#import <CoreGraphics/CoreGraphics.h>
#import <atomic>
#import <cstdio>
#import <cstdlib>

namespace {

std::atomic<int> g_keepState{-1};          // -1 unread, 0 off, 1 on
bool g_captureWanted = false;              // Wine asked to capture; not yet done
bool g_captured = false;                   // capture actually made
std::atomic<bool> g_reported{false};

bool keepEnabled() {
    int s = g_keepState.load(std::memory_order_relaxed);
    if (s < 0) {
        const char* e = getenv("ANVIL_KEEP_DISPLAY_MODE");
        s = (e && e[0] == '0') ? 0 : 1;
        g_keepState.store(s, std::memory_order_relaxed);
    }
    return s == 1;
}

void note(const char* fmt, double a, double b, double c) {
    const char* path = getenv("ANVIL_LOG");
    if (!path) return;
    if (FILE* f = fopen(path, "a")) { fprintf(f, fmt, a, b, c); fputc('\n', f); fclose(f); }
}

bool sameSize(CGDisplayModeRef a, CGDisplayModeRef b) {
    return CGDisplayModeGetWidth(a) == CGDisplayModeGetWidth(b)
        && CGDisplayModeGetHeight(a) == CGDisplayModeGetHeight(b)
        && CGDisplayModeGetPixelWidth(a) == CGDisplayModeGetPixelWidth(b)
        && CGDisplayModeGetPixelHeight(a) == CGDisplayModeGetPixelHeight(b);
}

} // namespace

extern "C" CGError anvil_CGCaptureAllDisplays(void) {
    if (!keepEnabled()) return CGCaptureAllDisplays();
    g_captureWanted = true;                 // made for real only if a switch needs it
    return kCGErrorSuccess;
}

extern "C" CGError anvil_CGReleaseAllDisplays(void) {
    if (!keepEnabled()) return CGReleaseAllDisplays();
    g_captureWanted = false;
    if (!g_captured) return kCGErrorSuccess;
    g_captured = false;
    return CGReleaseAllDisplays();
}

extern "C" CGError anvil_CGDisplaySetDisplayMode(CGDirectDisplayID display, CGDisplayModeRef mode,
                                                 CFDictionaryRef options) {
    if (keepEnabled() && mode) {
        if (CGDisplayModeRef current = CGDisplayCopyDisplayMode(display)) {
            const bool same = sameSize(current, mode);
            const double from = CGDisplayModeGetRefreshRate(current);
            CGDisplayModeRelease(current);
            if (same) {
                if (!g_reported.exchange(true)) {
                    note("[anvil] game asked for %.0fx%.0f at %.0f Hz — the display already shows that size, "
                         "so it keeps its own mode (ProMotion stays on)",
                         (double)CGDisplayModeGetWidth(mode), (double)CGDisplayModeGetHeight(mode),
                         CGDisplayModeGetRefreshRate(mode));
                }
                (void)from;
                return kCGErrorSuccess;
            }
        }
        // A real resolution change: take the capture Wine asked for, so macOS puts the
        // display back if the game exits without doing so.
        if (g_captureWanted && !g_captured && CGCaptureAllDisplays() == kCGErrorSuccess) g_captured = true;
    }
    return CGDisplaySetDisplayMode(display, mode, options);
}

__attribute__((used, section("__DATA,__interpose")))
static struct { const void* replacement; const void* original; } anvil_display_interposes[] = {
    { (const void*)&anvil_CGCaptureAllDisplays,    (const void*)&CGCaptureAllDisplays },
    { (const void*)&anvil_CGReleaseAllDisplays,    (const void*)&CGReleaseAllDisplays },
    { (const void*)&anvil_CGDisplaySetDisplayMode, (const void*)&CGDisplaySetDisplayMode },
};

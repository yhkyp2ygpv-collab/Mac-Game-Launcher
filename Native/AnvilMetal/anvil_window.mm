// Whether the game's window fills the screen, said once per session in the game log.
//
// A game set to fullscreen can still not fill the screen under Wine: on 1 October LEGO Star
// Wars on Wine 9 had its left edge cut off in exclusive fullscreen, and sat below the menu
// bar as a borderless window. Anvil reads this line after the session and, when the window
// didn't fill the screen, sets the game up the next way to try for that kind of engine (see
// GameTuning.fitDisplay). AppKit is reached through the runtime: libanvil is inserted into
// every Wine process, and only the game's needs it.
#import <AppKit/AppKit.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <atomic>

extern "C" void anvil_report_window_fit(void) {
    static std::atomic<bool> done{false};
    if (done.exchange(true)) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        Class appClass = NSClassFromString(@"NSApplication");
        if (!appClass) return;
        NSApplication* app = [appClass sharedApplication];
        NSWindow* best = nil;
        CGFloat bestArea = 0;
        for (NSWindow* w in app.windows) {
            if (!w.isVisible) continue;
            const CGFloat area = w.frame.size.width * w.frame.size.height;
            if (area > bestArea) { bestArea = area; best = w; }
        }
        if (!best) return;
        NSScreen* screen = best.screen ?: [(Class)NSClassFromString(@"NSScreen") mainScreen];
        if (!screen) return;
        const NSRect f = best.frame, s = screen.frame;
        const CGFloat tol = 1.5;
        const bool covers = f.origin.x <= s.origin.x + tol && f.origin.y <= s.origin.y + tol
            && NSMaxX(f) >= NSMaxX(s) - tol && NSMaxY(f) >= NSMaxY(s) - tol;
        const bool larger = f.size.width > s.size.width + tol || f.size.height > s.size.height + tol;
        const bool menuBar = (app.presentationOptions & (NSApplicationPresentationHideMenuBar | NSApplicationPresentationAutoHideMenuBar)) == 0
            && NSMaxY(f) <= NSMaxY(screen.visibleFrame) + tol && NSMaxY(screen.visibleFrame) < NSMaxY(s) - tol;
        const char* verdict = larger ? "larger than the screen — its edges are cut off"
            : covers ? "fills it"
            : menuBar ? "doesn't fill it — below the menu bar"
            : "doesn't fill it — smaller than the screen";
        const char* path = getenv("ANVIL_LOG");
        if (!path) return;
        if (FILE* out = fopen(path, "a")) {
            fprintf(out, "[anvil] window: %.0fx%.0f at (%.0f, %.0f) on a %.0fx%.0f screen — %s\n",
                    f.size.width, f.size.height, f.origin.x - s.origin.x, f.origin.y - s.origin.y,
                    s.size.width, s.size.height, verdict);
            fclose(out);
        }
    });
}

// Every window the game has open, 15, 45 and 90 seconds after its first frame, so a game that
// sits on one screen says why: a Windows message box behind the fullscreen picture shows here
// as a second, smaller window. On 1 October LEGO Star Wars, started offline, stayed on one
// screen and was closed after half a minute, twice, with nothing in any log to say what it
// was waiting for.
extern "C" void anvil_report_windows_later(void) {
    static std::atomic<bool> done{false};
    if (done.exchange(true)) return;
    const char* path = getenv("ANVIL_LOG");
    if (!path) return;
    char* logPath = strdup(path);
    static const int delays[] = {15, 45, 90};
    for (int seconds : delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)seconds * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            Class appClass = NSClassFromString(@"NSApplication");
            if (!appClass) return;
            NSApplication* app = [appClass sharedApplication];
            NSMutableString* list = [NSMutableString string];
            int visible = 0;
            for (NSWindow* w in app.windows) {
                if (!w.isVisible) continue;
                visible++;
                [list appendFormat:@" | “%@” %.0fx%.0f%@", w.title.length ? w.title : @"untitled",
                                   w.frame.size.width, w.frame.size.height, w.isKeyWindow ? @", has the keyboard" : @""];
            }
            if (FILE* out = fopen(logPath, "a")) {
                fprintf(out, "[anvil] windows after %d s: %d open%s%s\n", seconds, visible,
                        app.isActive ? "" : " (the game isn't the app in front)", list.UTF8String);
                fclose(out);
            }
        });
    }
}

// ---------------------------------------------------------------------------------
// Whether the game is the app in front.
//
// A game started with its own keep-running switch (LEGO Star Wars' -NoFocus_Process)
// carries on behind other apps instead of pausing, so its load finishes while the player
// is elsewhere. Behind them it is held to 30 frames a second (anvil_inject.mm): nobody is
// looking, and the Mac shouldn't run hot for it. winebus, in winedevice, has no window of
// its own to ask, so the answer is published through notify(3) under a name made from the
// prefix, and anvil_input.mm polls the controller less often while the game is behind.
//
// The state is the pid of the process in front, or 1 when the game's process stepped
// back; 0 (never set) counts as in front.
#include <notify.h>
#include <unistd.h>

static std::atomic<bool> g_inFront{true};

extern "C" bool anvil_game_in_front(void) { return g_inFront.load(std::memory_order_relaxed); }

extern "C" const char* anvil_front_notify_name(void) {
    static char name[64] = "";
    static std::atomic<bool> made{false};
    if (!made.load(std::memory_order_acquire)) {
        uint64_t h = 1469598103934665603ULL;      // FNV-1a of the prefix
        const char* prefix = getenv("WINEPREFIX");
        for (const char* p = prefix ? prefix : ""; *p; ++p) { h ^= (unsigned char)*p; h *= 1099511628211ULL; }
        snprintf(name, sizeof name, "dev.anvil.front.%016llx", (unsigned long long)h);
        made.store(true, std::memory_order_release);
    }
    return name;
}

static void publishFront(bool front) {
    static int token = -1;
    if (token < 0 && notify_register_check(anvil_front_notify_name(), &token) != NOTIFY_STATUS_OK) { token = -1; return; }
    const uint64_t me = (uint64_t)getpid();
    if (front) {
        notify_set_state(token, me);
    } else {
        uint64_t now = 0;
        notify_get_state(token, &now);
        if (now != me && now != 0) return;      // another of the game's processes is in front
        notify_set_state(token, 1);
    }
    notify_post(anvil_front_notify_name());
}

extern "C" void anvil_watch_front(void) {
    static std::atomic<bool> done{false};
    if (done.exchange(true)) return;
    // Anvil's stand-in games, run from a terminal that keeps the focus (tests only): always in front.
    if (getenv("ANVIL_TEST_FRONT")) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        Class appClass = NSClassFromString(@"NSApplication");
        if (!appClass) return;
        NSApplication* app = [appClass sharedApplication];
        const char* logPath = getenv("ANVIL_LOG");
        char* path = logPath ? strdup(logPath) : nullptr;
        void (^changed)(bool) = ^(bool front) {
            if (g_inFront.exchange(front) == front) return;
            publishFront(front);
            if (!path) return;
            if (FILE* out = fopen(path, "a")) {
                fprintf(out, front ? "[anvil] back in front — full frame rate again\n"
                                   : "[anvil] another app is in front — held to 30 fps until the game is back\n");
                fclose(out);
            }
        };
        g_inFront.store(app.isActive);
        publishFront(app.isActive);
        NSNotificationCenter* centre = [NSNotificationCenter defaultCenter];
        // The notifications' names are their values; written out so AppKit needn't be linked.
        [centre addObserverForName:@"NSApplicationDidBecomeActiveNotification" object:nil
                             queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification*) { changed(true); }];
        [centre addObserverForName:@"NSApplicationDidResignActiveNotification" object:nil
                             queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification*) { changed(false); }];
    });
}

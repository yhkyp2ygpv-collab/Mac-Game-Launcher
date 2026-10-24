// Whether the game's window fills the screen, said once per session in the game log.
//
// A game set to fullscreen can still not fill the screen under Wine: on 1 October LEGO Star
// Wars on Wine 9 had its left edge cut off in exclusive fullscreen, and sat below the menu
// bar as a borderless window. Anvil reads this line after the session and, when the window
// didn't fill the screen, sets the game up the next way to try for that kind of engine (see
// GameTuning.fitDisplay). AppKit is reached through the runtime: libanvil is inserted into
// every Wine process, and only the game's needs it.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
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
// The screen locked, or the displays asleep: nobody is watching, whichever app is in front. On 22 October Hogwarts
// Legacy drew 28 frames a second for three hours behind a locked screen, on battery.
static std::atomic<bool> g_screenAway{false};
// When the game last went behind another app (or the screen away), on CACurrentMediaTime's clock; 0 in front.
static std::atomic<double> g_behindSince{0.0};

extern "C" bool anvil_game_in_front(void) {
    return g_inFront.load(std::memory_order_relaxed) && !g_screenAway.load(std::memory_order_relaxed);
}
extern "C" bool anvil_screen_away(void) { return g_screenAway.load(std::memory_order_relaxed); }
/// How long the game has been behind another app or the screen away; 0 in front.
extern "C" double anvil_behind_seconds(double now) {
    const double since = g_behindSince.load(std::memory_order_relaxed);
    return since > 0.0 && !anvil_game_in_front() ? now - since : 0.0;
}

static void noteBehind(void) {
    if (anvil_game_in_front()) g_behindSince.store(0.0);
    else if (g_behindSince.load() <= 0.0) g_behindSince.store(CACurrentMediaTime());
}

// The game in front as the screen went away (or until just before: the lock can come a moment after another app):
// in front again once the screen is back. On 23 October, three seconds after the lid of a MacBook was opened on
// Hogwarts Legacy, Anvil's own (hidden) window took the front, and the game — on screen, played — was held to 30
// and then 10 fps for 23 minutes, until it was switched away from and back to.
static std::atomic<bool> g_frontAtAway{false};
static std::atomic<double> g_resignedAt{0.0};

/// Back in front, if what took the front is nothing the player chose: Anvil's own hidden window, the login window or
/// the Finder's desktop. Looked at a second after the screen is back, and again at four.
static void reclaimFront(NSApplication* app, const char* path) {
    static const double kAfter[] = {1.0, 4.0};
    for (double after : kAfter) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (g_inFront.load() || g_screenAway.load()) return;
            Class wsClass = NSClassFromString(@"NSWorkspace");
            NSString* front = wsClass ? [[wsClass sharedWorkspace] frontmostApplication].bundleIdentifier : nil;
            if (front && ![front isEqualToString:@"dev.anvil.launcher"] && ![front isEqualToString:@"com.apple.loginwindow"]
                && ![front isEqualToString:@"com.apple.finder"]) return;
            if ([app respondsToSelector:@selector(activate)]) [app performSelector:@selector(activate)];
            else [app activateIgnoringOtherApps:YES];
            if (FILE* out = path ? fopen(path, "a") : nullptr) {
                fprintf(out, "[anvil] the screen is back with %s in front — the game brought back to the front\n",
                        front ? front.UTF8String : "nothing");
                fclose(out);
            }
        });
    }
}

// The pointer, hidden while it's left alone with the game in front — over a game played with a controller it sat in
// the middle of the picture (23 October). It's back as soon as the mouse moves; a game holding the mouse for itself
// hides it anyway. ANVIL_HIDE_POINTER=0 leaves it.
static void hideIdlePointer(const char* path) {
    const char* want = getenv("ANVIL_HIDE_POINTER");
    if (want && want[0] == '0') return;
    Class eventClass = NSClassFromString(@"NSEvent"), cursorClass = NSClassFromString(@"NSCursor");
    if (!eventClass || !cursorClass) return;
    static NSPoint last = {-1, -1};
    static int still = 0;
    static bool hidden = false, said = false;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{
        const NSPoint p = [eventClass mouseLocation];
        if (p.x != last.x || p.y != last.y) { last = p; still = 0; hidden = false; return; }
        if (!anvil_game_in_front() || hidden || ++still < 2) return;
        [cursorClass setHiddenUntilMouseMoves:YES];
        hidden = true;
        if (!said && path) {
            said = true;
            if (FILE* out = fopen(path, "a")) {
                fprintf(out, "[anvil] the pointer hidden while the mouse is left alone — it's back as soon as the mouse moves\n");
                fclose(out);
            }
        }
    });
    dispatch_resume(timer);
}

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
            if (!front) g_resignedAt.store(CACurrentMediaTime());
            publishFront(front);
            noteBehind();
            if (!path) return;
            if (FILE* out = fopen(path, "a")) {
                fprintf(out, front ? "[anvil] back in front — full frame rate again\n"
                                   : "[anvil] another app is in front — held to 30 fps after two seconds until the game is back (10 fps after two minutes)\n");
                fclose(out);
            }
        };
        void (^away)(bool) = ^(bool gone) {
            if (g_screenAway.exchange(gone) == gone) return;
            if (gone) g_frontAtAway.store(g_inFront.load() || CACurrentMediaTime() - g_resignedAt.load() < 3.0);
            noteBehind();
            if (!gone && g_frontAtAway.exchange(false)) reclaimFront(app, path);
            if (!path) return;
            if (FILE* out = fopen(path, "a")) {
                fprintf(out, gone ? "[anvil] the screen is locked or asleep — the game held to 5 fps until it's back\n"
                                  : "[anvil] the screen is back\n");
                fclose(out);
            }
        };
        g_inFront.store(app.isActive);
        publishFront(app.isActive);
        noteBehind();
        hideIdlePointer(path);
        // The screen locked and unlocked (loginwindow's own notices), and the displays asleep and awake (NSWorkspace's,
        // by their values: AppKit isn't linked).
        NSDistributedNotificationCenter* distributed = [NSDistributedNotificationCenter defaultCenter];
        [distributed addObserverForName:@"com.apple.screenIsLocked" object:nil queue:[NSOperationQueue mainQueue]
                             usingBlock:^(NSNotification*) { away(true); }];
        [distributed addObserverForName:@"com.apple.screenIsUnlocked" object:nil queue:[NSOperationQueue mainQueue]
                             usingBlock:^(NSNotification*) { away(false); }];
        if (Class wsClass = NSClassFromString(@"NSWorkspace")) {
            NSWorkspace* ws = [wsClass sharedWorkspace];
            [ws.notificationCenter addObserverForName:@"NSWorkspaceScreensDidSleepNotification" object:nil
                                                queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification*) { away(true); }];
            [ws.notificationCenter addObserverForName:@"NSWorkspaceScreensDidWakeNotification" object:nil
                                                queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification*) {
                // Awake again, but maybe still locked: the unlock says so then.
                NSDictionary* session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
                away([session[@"CGSSessionScreenIsLocked"] boolValue]);
            }];
        }
        NSNotificationCenter* centre = [NSNotificationCenter defaultCenter];
        // The notifications' names are their values; written out so AppKit needn't be linked.
        [centre addObserverForName:@"NSApplicationDidBecomeActiveNotification" object:nil
                             queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification*) { changed(true); }];
        [centre addObserverForName:@"NSApplicationDidResignActiveNotification" object:nil
                             queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification*) { changed(false); }];
    });
}

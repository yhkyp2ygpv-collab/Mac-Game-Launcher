// Steady 80's decisions, run on the library's own code against a simulated game.
//
// The game works a scheduled time per frame; presenting is what the library does on a
// ProMotion panel: shown on the 240 Hz grid, no faster than 120, and in the held mode
// on the 80 Hz cadence. Checks that each kind of scene ends where it should, that the
// hold never keeps a game from 120 for long, and that held frames are evenly spaced.
//
//   clang++ -std=c++17 -ObjC++ -DANVIL_INJECT_TEST -framework Foundation -framework QuartzCore \
//     -framework Metal -framework MetalFX -framework CoreGraphics -framework IOKit \
//     Native/Tools/tests/steady_test.mm -o /tmp/steady_test && /tmp/steady_test
#include "../../AnvilMetal/anvil_inject.mm"
extern "C" ssize_t anvil_pread(int fd, void* buf, size_t n, off_t at);
#include <cstdio>
#include <fcntl.h>
#include <unistd.h>
#include <vector>
#include <map>
#include <cmath>

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { ++failures; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

struct Scene { const char* name; double workMs; double seconds; double jitter; };
struct Result { double fps; double even; Steady endMode; double secondsTo120; };

static uint32_t rng = 12345;
static double rnd() { rng = rng * 1664525u + 1013904223u; return (rng >> 8) / 16777216.0; }

// A ProMotion panel by default: frames on a 240 Hz grid, 120 at most. An external
// variable-refresh display shows a frame whenever it arrives, up to its top rate.
static std::vector<Result> simulate(const std::vector<Scene>& scenes, double refreshHz = 120.0, double gridHz = 240.0) {
    g_promotedAt = -1.0; g_gpuMisled = false; g_overSince = -1.0; g_holdBackoff = 0.0; g_nextHoldAt = 0.0;
    g_lastPresentCallAt = -1.0; g_lastPresentWall = -1.0;
    const double tick = 1.0 / gridHz;
    g_steadyWanted = true; g_vrrState = 1; g_generating = false; g_refreshPeriod = 1.0 / refreshHz;
    g_nextProbeAt = 0; g_lastProbeAt = 0; g_probeBackoff = 0; g_gpuNow = -1; g_gpuNowAt = 0; g_gpuAskedAt = 0;
    g_steady = Steady::off; g_resumedAt = 0; g_workEma = 0; g_cadence = 0; g_presentCount = 0; g_presentHead = 0;
    double t = 0.0, lastShown = -1.0;
    std::vector<Result> out;
    for (const Scene& sc : scenes) {
        const double end = t + sc.seconds;
        std::vector<double> gaps;
        double first120 = -1;
        while (t < end) {
            g_hookWaitSec = 0.0;
            const double work = sc.workMs / 1000.0 * (1.0 + sc.jitter * (2 * rnd() - 1));
            double callAt = t + work;
            // As ready, the panel lets a frame go no sooner than 8.33 ms after the last;
            // with three drawables the game waits for one if it runs ahead (a nextDrawable wait).
            steadyOnPresent(callAt);
            double presentAt = callAt, minGap = g_refreshPeriod;
            if (g_steady == Steady::hold) {
                presentAt = std::max(callAt, steadyHoldTarget(callAt));
                minGap = steadyHoldMinGap();
            }
            double shownAt = std::ceil((lastShown < 0 ? presentAt : std::max(presentAt, lastShown + minGap)) / tick - 1e-9) * tick;
            if (lastShown >= 0 && t > end - sc.seconds + 1.0) gaps.push_back(shownAt - lastShown);
            // Throttled by the pool: the game cannot run more than a frame or two ahead.
            const double poolFree = shownAt - 2 * g_refreshPeriod;
            double resumed = presentAt + 0.0002;
            if (poolFree > resumed) { g_hookWaitSec = 0; resumed = poolFree; }
            lastShown = shownAt;
            g_resumedAt = presentAt + 0.0002;
            t = resumed;
            if (first120 < 0 && g_steady == Steady::full && t > end - sc.seconds + 0.2) first120 = t - (end - sc.seconds);
        }
        double sum = 0; std::map<long, int> hist;
        for (double g : gaps) { sum += g; hist[lround(g * 10000)]++; }
        int top = 0; for (auto& h : hist) top = std::max(top, h.second);
        out.push_back({gaps.empty() ? 0 : gaps.size() / sum, gaps.empty() ? 0 : (double)top / gaps.size(), g_steady, first120});
        printf("  %-28s %6.1f fps shown, %5.1f%% of gaps equal, ends %s\n", sc.name, out.back().fps, 100 * out.back().even, steadyName(g_steady));
    }
    return out;
}

// GPU-bound scenes. The game's thread waits inside the D3D runtime for the GPU to
// finish its previous frame, so a GPU-bound wait counts as the game's own work — as
// D3DMetal's WaitUntilSubmission does in the stall captures. Held at 80, a frame the
// GPU needs 10.5 ms for leaves time to spare and the work reads as the CPU's alone.
struct GpuScene { const char* name; double cpuMs; double gpuMs; double seconds; bool gpuKnown; };
struct GpuResult { double fps; double even; Steady endMode; int probes; double secondsTo120; };

static std::vector<GpuResult> simulateGpu(const std::vector<GpuScene>& scenes) {
    g_promotedAt = -1.0; g_gpuMisled = false; g_overSince = -1.0; g_holdBackoff = 0.0; g_nextHoldAt = 0.0;
    const double tick = 1.0 / 240.0;
    g_steadyWanted = true; g_vrrState = 1; g_generating = false; g_refreshPeriod = 1.0 / 120.0;
    g_steady = Steady::off; g_resumedAt = 0; g_workEma = 0; g_cadence = 0; g_presentCount = 0; g_presentHead = 0;
    g_nextProbeAt = 0; g_lastProbeAt = 0; g_probeBackoff = 0; g_gpuNow = -1; g_gpuNowAt = 0; g_gpuAskedAt = 0;
    double t = 0.0, lastShown = -1.0, gpuDonePrev = 0.0, lastReading = 0.0;
    std::vector<double> gpuDone;   // completion times, for the utilisation reading
    std::vector<GpuResult> out;
    for (const GpuScene& sc : scenes) {
        const double begin = t, end = t + sc.seconds;
        std::vector<double> gaps;
        int probes = 0;
        double first120 = -1;
        while (t < end) {
            g_hookWaitSec = 0.0;
            const double start = t;
            const double cpu = sc.cpuMs / 1000.0 * (1.0 + 0.05 * (2 * rnd() - 1));
            const double gpu = sc.gpuMs / 1000.0 * (1.0 + 0.05 * (2 * rnd() - 1));
            const double gpuStart = std::max(start, gpuDonePrev);
            const double done = gpuStart + gpu;
            const double callAt = std::max(start + cpu, gpuDonePrev);   // one frame queued at most
            gpuDonePrev = done;
            gpuDone.push_back(done);

            // The GPU reading, every half second: its share of the last second.
            if (callAt - lastReading >= 0.5) {
                lastReading = callAt;
                int busy = 0;
                for (double d : gpuDone) if (d > callAt - 1.0 && d <= callAt) busy++;
                g_gpuNow = sc.gpuKnown ? (int)std::min(100.0, busy * sc.gpuMs / 10.0 + 0.5) : -1;
                g_gpuNowAt = callAt;
                if (gpuDone.size() > 400) gpuDone.erase(gpuDone.begin(), gpuDone.begin() + 200);
            }

            const Steady before = g_steady;
            steadyOnPresent(callAt);
            if (g_steady == Steady::probe && before != Steady::probe) probes++;
            double presentAt = callAt, minGap = g_refreshPeriod;
            if (g_steady == Steady::hold) {
                presentAt = std::max(callAt, steadyHoldTarget(callAt));
                minGap = steadyHoldMinGap();
            }
            const double ready = std::max(presentAt, done);
            const double shownAt = std::ceil((lastShown < 0 ? ready : std::max(ready, lastShown + minGap)) / tick - 1e-9) * tick;
            if (lastShown >= 0 && callAt > begin + 3.0) gaps.push_back(shownAt - lastShown);
            lastShown = shownAt;
            g_resumedAt = presentAt + 0.0002;
            t = g_resumedAt;
            if (first120 < 0 && g_steady == Steady::full && t > begin + 0.2) first120 = t - begin;
        }
        double sum = 0; std::map<long, int> hist;
        for (double g : gaps) { sum += g; hist[lround(g * 10000)]++; }
        int top = 0; for (auto& h : hist) top = std::max(top, h.second);
        out.push_back({gaps.empty() ? 0 : gaps.size() / sum, gaps.empty() ? 0 : (double)top / gaps.size(), g_steady, probes, first120});
        printf("  %-40s %6.1f fps shown, %5.1f%% of gaps equal, %2d probes, ends %s\n", sc.name, out.back().fps,
               100 * out.back().even, probes, steadyName(g_steady));
    }
    return out;
}

// simulate(), counting state changes instead of printing each scene.
static std::vector<Result> simulateCounting(const std::vector<Scene>& scenes, int* switches, std::vector<int>* perScene = nullptr) {
    g_promotedAt = -1.0; g_gpuMisled = false; g_overSince = -1.0; g_holdBackoff = 0.0; g_nextHoldAt = 0.0;
    const double tick = 1.0 / 240.0;
    g_steadyWanted = true; g_vrrState = 1; g_generating = false; g_refreshPeriod = 1.0 / 120.0;
    g_steady = Steady::off; g_resumedAt = 0; g_workEma = 0; g_cadence = 0; g_presentCount = 0; g_presentHead = 0;
    g_nextProbeAt = 0; g_lastProbeAt = 0; g_probeBackoff = 0; g_gpuNow = -1; g_gpuNowAt = 0; g_gpuAskedAt = 0;
    double t = 0.0, lastShown = -1.0;
    Steady last = Steady::off;
    std::vector<Result> out;
    for (const Scene& sc : scenes) {
        const double end = t + sc.seconds;
        while (t < end) {
            g_hookWaitSec = 0.0;
            const double work = sc.workMs / 1000.0 * (1.0 + sc.jitter * (2 * rnd() - 1));
            double callAt = t + work;
            steadyOnPresent(callAt);
            if (g_steady != last) { if (last != Steady::off) ++*switches; last = g_steady; }
            double presentAt = callAt, minGap = g_refreshPeriod;
            if (g_steady == Steady::hold) {
                presentAt = std::max(callAt, steadyHoldTarget(callAt));
                minGap = steadyHoldMinGap();
            }
            double shownAt = std::ceil((lastShown < 0 ? presentAt : std::max(presentAt, lastShown + minGap)) / tick - 1e-9) * tick;
            const double poolFree = shownAt - 2 * g_refreshPeriod;
            double resumed = presentAt + 0.0002;
            if (poolFree > resumed) resumed = poolFree;
            lastShown = shownAt;
            g_resumedAt = presentAt + 0.0002;
            t = resumed;
        }
        out.push_back({0, 0, g_steady, 0});
        if (perScene) perScene->push_back(*switches);
    }
    return out;
}

int main() {
    setenv("ANVIL_LOG", getenv("STEADY_LOG") ? getenv("STEADY_LOG") : "/dev/null", 1);
    // The scenes below are the game after its start has settled; the start is tested on its own.
    g_steadySettleSec = 0.0;
    std::vector<Scene> scenes = {
        {"light (143 fps)", 7.0, 6, 0.1},
        {"medium (90 fps)", 11.1, 8, 0.15},
        {"light again (139 fps)", 7.2, 6, 0.1},
        {"heavy (70 fps)", 14.3, 6, 0.15},
        {"medium (87 fps)", 11.5, 8, 0.1},
        {"light (143 fps)", 7.0, 6, 0.1},
        {"fast edge (116 fps)", 8.6, 6, 0.05},
        {"medium (90 fps)", 11.1, 8, 0.15},
        {"able to make 105", 9.5, 8, 0.1},
    };
    std::vector<Result> r = simulate(scenes);
    CHECK(r[0].endMode == Steady::full && r[0].fps > 118, "light scene should run at 120 (%.1f)", r[0].fps);
    CHECK(r[1].endMode == Steady::hold && r[1].even > 0.95 && r[1].fps > 79 && r[1].fps < 81, "90 fps scene should hold an even 80 (%.1f fps, %.0f%% even)", r[1].fps, 100 * r[1].even);
    CHECK(r[2].endMode == Steady::full && r[2].fps > 112, "after a medium scene a light one must get back to 120 (%.1f)", r[2].fps);
    CHECK(r[3].endMode == Steady::low, "a 70 fps scene cannot be held at 80 and must be let go");
    CHECK(r[4].endMode == Steady::hold && r[4].even > 0.9, "87 fps scene should hold 80 (%.0f%% even)", 100 * r[4].even);
    CHECK(r[5].fps > 112, "the last light scene must return to 120 (%.1f)", r[5].fps);
    CHECK(r[6].endMode == Steady::full, "a game near 116 fps is left at its own rate");
    printf("  able to make 105: free to run at its own rate after %.1f s\n", r[8].secondsTo120);
    CHECK(r[8].endMode == Steady::full && r[8].secondsTo120 > 0 && r[8].secondsTo120 < 6.0,
          "a game able to make 105 is let go to run at its own rate within a few seconds (%.1f s, ends %s)", r[8].secondsTo120, steadyName(r[8].endMode));

    printf("144 Hz variable-refresh display:\n");
    std::vector<Result> e = simulate({
        {"light (180 fps)", 5.5, 6, 0.1},
        {"medium (107 fps)", 9.3, 8, 0.1},
        {"light again (180 fps)", 5.5, 6, 0.1},
    }, 144.0, 100000.0);
    CHECK(e[0].endMode == Steady::full && e[0].fps > 140, "144 Hz: a light scene runs at 144 (%.1f)", e[0].fps);
    CHECK(e[1].endMode == Steady::hold && e[1].fps > 95 && e[1].fps < 97.5 && e[1].even > 0.9,
          "144 Hz: a 107 fps scene holds an even 96 (%.1f fps, %.0f%% even)", e[1].fps, 100 * e[1].even);
    CHECK(e[2].endMode == Steady::full && e[2].fps > 135, "144 Hz: back to 144 in a light scene (%.1f)", e[2].fps);

    // LEGO Star Wars on 30 September, 0.16: a game whose own rate swings between about 95
    // and 125 every second or two, and whose frame time sits right at the 80 fps line in
    // heavy stretches. Counted: how often Steady changes its mind.
    printf("Swinging scenes:\n");
    {
        g_steady = Steady::off;
        int switches = 0;
        std::vector<Scene> swing;
        for (int i = 0; i < 12; ++i) { swing.push_back({"fast 1 s", 8.0, 1.0, 0.05}); swing.push_back({"slow 1.5 s", 10.6, 1.5, 0.08}); }
        // Count transitions by wrapping steadyEnter's effect: sample the state each scene.
        Steady last = Steady::off;
        const double tick = 1.0 / 240.0; (void)tick;
        std::vector<Result> r1 = simulateCounting(swing, &switches);
        printf("  swinging 95↔125 fps for 30 s: %d switches, ends %s\n", switches, steadyName(g_steady));
        CHECK(switches <= 12, "a game swinging around 110 should not switch more than ~12 times in 30 s — it was 34 (%d)", switches);
        (void)last; (void)r1;
        int edge = 0;
        std::vector<Scene> heavy;
        for (int i = 0; i < 10; ++i) { heavy.push_back({"12.3 ms", 12.3, 1.2, 0.12}); heavy.push_back({"13.4 ms", 13.4, 1.2, 0.12}); }
        simulateCounting(heavy, &edge);
        printf("  heavy, frame time around 12.5–13.5 ms for 24 s: %d switches, ends %s\n", edge, steadyName(g_steady));
        CHECK(edge <= 6, "a game at the 80 fps line should not flip between held and below more than ~6 times in 24 s (%d)", edge);
        // 2 October: a heavy stretch swinging between about 45 and 97 fps every second or two.
        int lurch = 0;
        std::vector<Scene> heavySwing;
        for (int i = 0; i < 12; ++i) { heavySwing.push_back({"97 fps 1.6 s", 10.3, 1.6, 0.08}); heavySwing.push_back({"45 fps 1.2 s", 22.0, 1.2, 0.1}); }
        simulateCounting(heavySwing, &lurch);
        printf("  heavy, swinging 45↔97 fps for 34 s: %d switches, ends %s\n", lurch, steadyName(g_steady));
        CHECK(lurch <= 10, "a game swinging between 45 and 97 should not be held and let go every second or two (%d switches)", lurch);
        // 10 October, on battery: LEGO between 64 and 86 fps, held 1–7 s at a time and let go —
        // 74 changes in 40 minutes, ten in one minute.
        int hover = 0;
        std::vector<Scene> battery;
        const double lengths[] = {4, 3, 6, 5, 3, 7, 5, 2.5, 8, 4, 3, 6};
        for (int round = 0; round < 3; ++round)
            for (int i = 0; i < 12; ++i)
                battery.push_back(i % 2 == 0 ? Scene{"lighter (90 fps)", 10.8, lengths[i], 0.08}
                                             : Scene{"heavier (66 fps)", 15.0, lengths[i], 0.08});
        double total = 0; for (const Scene& sc : battery) total += sc.seconds;
        simulateCounting(battery, &hover);
        printf("  hovering 66↔90 fps in 2–8 s stretches for %.0f s: %d switches (%.1f a minute)\n", total, hover, hover * 60.0 / total);
        CHECK(hover * 60.0 / total <= 4.0, "held and let go no more than a few times a minute where it hovers around 80 (%.1f a minute)", hover * 60.0 / total);
    }

    printf("GPU-bound scenes:\n");
    std::vector<GpuResult> g = simulateGpu({
        {"GPU-bound 88 fps, GPU read (30 s)", 8.2, 11.4, 30, true},
        {"lighter: GPU 6 ms, CPU 7 ms (8 s)", 7.0, 6.0, 8, true},
        {"GPU-bound 88 fps again (20 s)", 8.2, 11.4, 20, true},
        {"GPU-bound 102 fps (20 s)", 7.0, 9.8, 20, true},
    });
    CHECK(g[0].endMode == Steady::hold && g[0].even > 0.95, "a GPU-bound 88 fps scene should hold an even 80 (%.0f%% even)", 100 * g[0].even);
    CHECK(g[0].probes <= 2, "with the GPU read, a GPU-bound scene should hardly probe (%d probes in 30 s)", g[0].probes);
    CHECK(g[1].endMode == Steady::full && g[1].secondsTo120 > 0 && g[1].secondsTo120 < 3.0,
          "a scene the GPU has room for should reach 120 within 3 s (%.1f s)", g[1].secondsTo120);
    CHECK(g[2].endMode == Steady::hold && g[2].probes <= 2, "back to GPU-bound: hold again without flapping (%d probes)", g[2].probes);
    CHECK(g[3].endMode == Steady::full && g[3].fps > 98, "a GPU-bound 102 fps scene runs at its own rate (%.1f fps, ends %s)", g[3].fps, steadyName(g[3].endMode));

    std::vector<GpuResult> u = simulateGpu({
        {"GPU-bound 88 fps, no GPU reading (30 s)", 8.2, 11.4, 30, false},
    });
    CHECK(u[0].probes <= 6, "without a GPU reading, failed probes should back off (%d probes in 30 s)", u[0].probes);
    CHECK(u[0].even > 0.85, "with back-off the held scene stays mostly even (%.0f%%)", 100 * u[0].even);

    // A display that doesn't follow the game: 2 October, LEGO Star Wars held at 80 in its
    // first second, the display then judged fixed, and every frame after held — 60 shown.
    printf("Fixed-refresh display:\n");
    {
        const int before = failures;
        simulate({{"medium (90 fps)", 11.1, 4, 0.1}});
        CHECK(g_steady == Steady::hold, "set-up: a 90 fps scene is held (%s)", steadyName(g_steady));
        g_vrrState = 0;
        g_vrrRetryAt = 0.0;
        steadyAtPresent(100.0, true);
        CHECK(g_steady == Steady::off, "on a display judged fixed nothing is held (%s)", steadyName(g_steady));
        g_vrrRetryAt = 130.0;
        steadyAtPresent(120.0, true);
        CHECK(g_vrrState == 0 && g_steady == Steady::off, "no fresh look before it is due");
        steadyAtPresent(131.0, true);
        CHECK(g_vrrState == 2 && g_steady == Steady::off, "a fresh look at the display holds nothing while it lasts");
        g_vrrState = 1;
        steadyAtPresent(132.0, true);
        CHECK(g_steady == Steady::full, "confirmed following again, Steady starts over from the full rate (%s)", steadyName(g_steady));
        printf("  held at 80, then the display judged fixed: %s\n", failures > before ? "FAILED" : "let go, looked at again, back");
        // 10 October: judged fixed 3 s into the first hold, following on the next look 30 s later.
        CHECK(vrrRetryDelay(0) == 10.0 && vrrRetryDelay(1) == 30.0 && vrrRetryDelay(2) == 60.0 && vrrRetryDelay(5) == 480.0,
              "looked at again after 10 s, then 30 s, 1, 2, 4 and 8 minutes (%.0f, %.0f, %.0f … %.0f)",
              vrrRetryDelay(0), vrrRetryDelay(1), vrrRetryDelay(2), vrrRetryDelay(5));
    }

    // Cat Quest II on 10 October: its first 30 s swing between 70 and 117 fps through logos, an
    // intro and loading — held to 80 and let go nine times — then an unbroken 120.
    printf("The start:\n");
    {
        g_steadyStartAt = -1.0; g_steadySettled = false; g_steadySettleSec = 30.0;
        int switches = 0;
        std::vector<int> per;
        std::vector<Scene> start;
        for (int i = 0; i < 4; ++i) {
            start.push_back({"intro (71 fps)", 14.0, 2.4, 0.1});
            start.push_back({"logo (117 fps)", 8.5, 2.4, 0.05});
            start.push_back({"loading (88 fps)", 11.3, 2.4, 0.1});
        }
        start.push_back({"its menu (90 fps)", 11.1, 8, 0.1});
        std::vector<Result> r = simulateCounting(start, &switches, &per);
        CHECK(per[11] == 0, "nothing held or let go in the first 30 s, however the game swings (%d changes)", per[11]);
        CHECK(r.back().endMode == Steady::hold, "settled, a 90 fps menu is held to an even 80 (%s)", steadyName(r.back().endMode));
        printf("  first 30 s: %d changes of pace; after: %d\n", per[11], switches - per[11]);
        g_steadyStartAt = -1.0; g_steadySettled = false; g_steadySettleSec = 0.0;
    }

    // LEGO Star Wars on 3 October: hovering between about 90 and 105 fps. Each probe found
    // 120, held it for five to twelve seconds and fell back to 80, and the back-off never grew:
    // the rate changed every few seconds for minutes. A fall within 15 s is a failed probe now.
    printf("Hovering scenes:\n");
    {
        g_vrrState = 1;
        int switches = 0;
        std::vector<int> after;
        std::vector<Scene> hover;
        for (int i = 0; i < 12; ++i) { hover.push_back({"105 fps 9 s", 9.5, 9.0, 0.06}); hover.push_back({"90 fps 4 s", 11.1, 4.0, 0.08}); }
        simulateCounting(hover, &switches, &after);
        const int late = switches - after[11];          // the last 6 of the 12 rounds, 78 s
        printf("  hovering 90↔105 fps for 156 s: %d switches, %d in the last 78 s, ends %s\n", switches, late, steadyName(g_steady));
        CHECK(switches <= 22, "a game hovering between 90 and 105 should settle — it was 36 switches in 156 s (%d)", switches);
        CHECK(late <= 4, "settled: hardly a switch in the last 78 s (%d)", late);
    }

    // Long sessions: on battery, an even 80 even where the game could make 143, and no probes.
    printf("Long sessions:\n");
    {
        g_endurance = true;
        int switches = 0;
        std::vector<Result> l = simulateCounting({{"light (143 fps), on battery", 7.0, 10, 0.1}}, &switches);
        printf("  light scene on battery: ends %s, %d switches\n", steadyName(g_steady), switches);
        CHECK(l[0].endMode == Steady::hold && switches <= 1, "on battery a light scene is held to an even 80 (%s, %d switches)",
              steadyName(l[0].endMode), switches);
        std::vector<Result> l2 = simulate({{"light (143 fps), on battery", 7.0, 6, 0.1}});
        CHECK(l2[0].fps > 79 && l2[0].fps < 81 && l2[0].even > 0.95, "held at 80 on battery, evenly (%.1f fps, %.0f%% even)",
              l2[0].fps, 100 * l2[0].even);
        g_endurance = false;
        std::vector<Result> l3 = simulate({{"light (143 fps), plugged in", 7.0, 10, 0.1}});
        CHECK(l3[0].endMode == Steady::full && l3[0].fps > 112, "plugged in again, back to 120 (%.1f, %s)", l3[0].fps, steadyName(l3[0].endMode));
        CHECK(enduranceFor(2, kOnBattery) && enduranceFor(2, kLowPower) && enduranceFor(2, kHot) && !enduranceFor(2, 0),
              "automatic: on battery, in Low Power Mode or hot, not plugged in and cool");
        CHECK(enduranceFor(1, 0) && !enduranceFor(0, kOnBattery | kHot), "always is always; never is never");
        // A game set to run up to the display's rate is held in a long session too; one held to
        // 60 keeps its 60.
        g_steadyWanted = false; g_vrrState = 1; g_generating = false; g_steady = Steady::off;
        g_endurance = true; g_targetFPS = 0;
        steadyAtPresent(500.0, true);
        CHECK(g_steady != Steady::off, "up to 120, on battery: Steady runs (%s)", steadyName(g_steady));
        g_steady = Steady::off; g_targetFPS = 60;
        steadyAtPresent(501.0, true);
        CHECK(g_steady == Steady::full || g_steady == Steady::off, "held to 60, on battery: not taken over (%s)", steadyName(g_steady));
        CHECK(!(g_steadyWanted || (enduranceOn() && g_targetFPS <= 0)), "held to 60: no Steady of its own");
        g_endurance = false; g_targetFPS = 0; g_steadyWanted = true;
    }

    // FSR 3 within the frame's budget: FSR 1 after 2 s short of 80 with the GPU full, FSR 3
    // again after 3 s of room for its share — not before the back-off — and the back-off grows
    // when it has to ease again soon after.
    printf("FSR 3 budget:\n");
    {
        g_refreshPeriod = 1.0 / 120.0;
        g_endurance = false;
        auto reset = [] {
            g_fsr3Eased = false; g_fsr3ShortSince = g_fsr3RoomSince = -1.0; g_fsr3BackAt = -1.0;
            g_fsr3NextBackAt = 0.0; g_fsr3EaseBackoff = 0.0; g_fsr3GpuBefore = -1; g_fsr3ExtraMs = 2.3;
        };
        auto run = [](double from, double to, double rate, int gpu, bool hot = false) {
            for (double t = from; t <= to + 1e-9; t += 0.25) fsr3GovernStep(t, rate, gpu, hot);
        };
        reset();
        run(0.0, 1.75, 70, 97);
        CHECK(!g_fsr3Eased.load(), "not eased within 2 s of being short");
        run(2.0, 2.0, 70, 97);
        CHECK(g_fsr3Eased.load(), "eased to FSR 1 after 2 s at 70 fps with the GPU 97%% busy");
        run(2.25, 9.75, 80, 60);
        CHECK(g_fsr3Eased.load(), "not back before the 8 s back-off");
        run(10.0, 12.75, 80, 60);
        CHECK(g_fsr3Eased.load(), "not back before 3 s of room");
        run(13.0, 13.0, 80, 60);
        CHECK(!g_fsr3Eased.load(), "back to FSR 3 with room for it (7.5 ms a frame + 2.3 inside 11.25)");
        run(13.25, 17.0, 70, 97);
        CHECK(g_fsr3Eased.load() && g_fsr3EaseBackoff >= 16.0, "eased again soon after: the back-off doubles (%.0f s)", g_fsr3EaseBackoff);
        reset();
        run(0.0, 30.0, 80, 85);
        CHECK(!g_fsr3Eased.load(), "at an even 80 it stays FSR 3, however busy the GPU");
        run(30.25, 33.0, 75, 85);
        CHECK(!g_fsr3Eased.load(), "short of 80 with the GPU not full: not FSR 3's doing, kept");
        reset();
        run(0.0, 2.25, 70, 97);
        run(2.5, 40.0, 80, 75);
        CHECK(g_fsr3Eased.load(), "no room at 75%% busy at 80: 9.4 ms + 2.3 is past 11.25 — FSR 1 stays");
        reset();
        g_endurance = true;
        run(0.0, 2.25, 70, 97);
        run(2.5, 40.0, 80, 65);
        CHECK(g_fsr3Eased.load(), "a long session wants more spare: 8.1 ms + 2.3 is past 10");
        g_endurance = false;
        run(40.25, 44.0, 80, 65);
        CHECK(!g_fsr3Eased.load(), "plugged in, 8.1 ms + 2.3 is inside 11.25");
        reset();
        run(0.0, 0.0, 120, 50, true);
        CHECK(g_fsr3Eased.load(), "a hot Mac gets FSR 1 at once");
        run(0.25, 30.0, 120, 50, true);
        CHECK(g_fsr3Eased.load(), "and keeps it while hot");
        run(30.25, 34.0, 80, 60, false);
        CHECK(!g_fsr3Eased.load(), "cooled, with room (7.5 ms + 2.3): FSR 3 again");
        // Its cost as seen: 60% at 80 fps before, 80% at 80 fps after — 2.5 ms a frame.
        run(34.25, 36.5, 80, 80);
        printf("  learned FSR 3's cost: %.2f ms a frame (Graphics Prep said 2.3, the GPU showed 2.5)\n", g_fsr3ExtraMs);
        CHECK(fabs(g_fsr3ExtraMs - 2.4) < 0.01, "its cost learned from the GPU either side of coming back (%.2f ms)", g_fsr3ExtraMs);
        CHECK(fabs(gpuMsPerFrame(80, 80) - 10.0) < 1e-9 && gpuMsPerFrame(80, -1) < 0.0, "80%% busy at 80 fps is 10 ms a frame");
        // LEGO, 4 and 5 October on 0.30.0: eased in a heavy stretch, then at 105–115 fps with the
        // GPU 83–86% busy it never came back — judged as a share of a second, 2 ms at 110 fps was
        // 22% more. A frame at a time: 7.7 ms + 2.0 fits 80 with room.
        reset();
        g_fsr3ExtraMs = 2.0;
        run(0.0, 2.25, 73, 88);
        CHECK(g_fsr3Eased.load(), "73 fps with the GPU 88%% busy: FSR 1's 2 ms less reaches 80 — eased");
        run(2.5, 20.0, 110, 85);
        CHECK(!g_fsr3Eased.load(), "then 110 fps with the GPU 85%% busy: FSR 3 back (7.7 + 2.0 inside 11.25)");
        // And where FSR 1 couldn't reach 80 either, FSR 3 stays: the same frames, the better picture.
        reset();
        run(0.0, 20.0, 50, 88);
        CHECK(!g_fsr3Eased.load(), "50 fps with the GPU 88%% busy: 17.6 ms less 2.3 is still past 80 — FSR 3 kept");
        run(20.25, 40.0, 49, 99);
        CHECK(!g_fsr3Eased.load(), "49 fps, GPU 99%%: FSR 3 kept");
        // Eased at 73 fps, then a heavier place at 50 (0.55): FSR 1 can't make 80 there, and with Smooth Motion chosen
        // its frames between need FSR 3's pictures — back after 2 s, whatever the back-off. LEGO, 16 October: eased at
        // 72–76, then 47–56 for minutes with 0.47's frames made ahead over FSR 1, 63 of 910 windows.
        {
            const bool smoothWas = g_smoothMotion, forceWas = g_genForce, guardianWas = g_guardian;
            const int vrrWas = g_vrrState;
            g_smoothMotion = true; g_genForce = true; g_midWanted = true; g_vrrState = 1; g_midAvailableForTest = 1; g_guardian = false;
            reset();
            g_fsr3ExtraMs = 2.0;
            run(0.0, 2.25, 73, 88);
            CHECK(g_fsr3Eased.load(), "73 fps, GPU 88%%: eased");
            run(2.5, 4.25, 50, 95);
            CHECK(g_fsr3Eased.load(), "50 fps for under 2 s: still eased");
            run(4.5, 5.0, 50, 95);
            CHECK(!g_fsr3Eased.load(), "50 fps for 2 s with Smooth Motion chosen: FSR 3 back for its frames between, inside the 8 s back-off");
            run(5.25, 12.0, 50, 95);
            CHECK(!g_fsr3Eased.load(), "and kept at 50: FSR 1's saving couldn't make 80 there");
            reset();
            g_smoothMotion = false;
            run(0.0, 2.25, 73, 88);
            run(2.5, 20.0, 50, 95);
            CHECK(g_fsr3Eased.load(), "Smooth Motion not chosen: FSR 1's quicker frames kept at 50");
            g_smoothMotion = true;
            reset();
            run(0.0, 2.25, 73, 88);
            run(2.5, 20.0, 65, 95);
            CHECK(g_fsr3Eased.load(), "65 fps, above Smooth Motion's band: FSR 1 kept");
            reset();
            run(0.0, 2.25, 73, 88);
            g_midAvailableForTest = 0;
            g_midWanted = false;
            run(2.5, 20.0, 50, 95);
            CHECK(g_fsr3Eased.load(), "no frames between to make (0.47's chosen instead): FSR 1 kept");
            g_midWanted = true;
            g_smoothMotion = smoothWas; g_genForce = forceWas; g_vrrState = vrrWas; g_midAvailableForTest = -1; g_guardian = guardianWas;
        }
    }

    // Generated frames, the player's choice, on LEGO Star Wars' 11 October sessions: begun on a
    // loading screen 46 s in and kept for the session — Steady and the battery's 80 stood aside,
    // frames on the fixed grid at 50–60 fps, and later half of everything shown a guess at 23–45.
    printf("Generated frames, chosen by the player:\n");
    {
        g_refreshPeriod = 1.0 / 120.0; g_fullSlotPeriod = g_realSlotPeriod = 1.0 / 120.0;
        g_frameGenRequested = true; g_adaptive = true; g_genForce = true; g_steadyWanted = true;
        g_endurance = false; g_vrrState = 1; g_steady = Steady::full;
        auto fresh = [] {
            g_generating = false; g_halfRate = false; g_belowSeconds = g_recoverSeconds = g_upSeconds = g_downSeconds = 0.0;
            g_genShortSeconds = 0.0; g_genEngageBackoff = 0.0; g_genStartedAt = -1.0; g_sessionStartAt = 0.0;
            g_realSlotPeriod = g_fullSlotPeriod;
        };
        double t = 0.0;
        // Windows of the game's own rate, `secs` long each, for `total` seconds.
        auto run = [&t](double own, double total, double secs = 5.0) {
            for (double end = t + total; t < end - 1e-9; ) { t += secs; genDecide(t, own, secs); }
        };
        g_steadySettleSec = 30.0;
        fresh();
        run(46.0, 25.0);
        CHECK(!g_generating, "nothing generated in the game's first 30 s, its loading screen at 46 fps");
        run(46.0, 30.0);
        CHECK(!g_generating, "settled, 46 fps of its own on a variable-refresh panel: its frames shown as ready, none guessed");
        run(110.0, 20.0);
        CHECK(!g_generating, "110 fps of its own: none generated");
        run(85.0, 20.0);
        CHECK(!g_generating, "85 fps, which Steady holds to an even 80: none generated");
        run(70.0, 5.0);
        CHECK(!g_generating, "one window at 70: not yet — a heavy stretch between lighter ones is no reason to change cadence");
        run(70.0, 5.0);
        CHECK(g_generating && g_halfRate && fabs(g_realSlotPeriod - 2.0 / 120.0) < 1e-9,
              "10 s at 70 fps, short of an even 80 and able to hold 60: two to one — 60 of its own, one guessed between each");
        run(70.0, 30.0);
        CHECK(g_generating && g_halfRate, "kept while it stays there");
        run(40.0, 5.0);
        CHECK(!g_generating && !g_halfRate && fabs(g_realSlotPeriod - 1.0 / 120.0) < 1e-9,
              "down to 40, short of every second refresh: generated frames off within 5 s, its own shown as ready");
        g_steady = Steady::low;
        steadyAtPresent(t, true);
        CHECK(!g_generating && g_steady != Steady::off, "and Steady runs again (%s)", steadyName(g_steady));
        g_steady = Steady::full;
        run(70.0, 10.0);
        CHECK(!g_generating, "back to 70 for 10 s: not yet — it ran only 35 s last time, so it waits 10 s more");
        run(70.0, 10.0);
        CHECK(g_generating, "20 s at 70: two to one again");
        run(70.0, 10.0);
        run(100.0, 5.0);
        CHECK(g_generating, "one window able to make 100: not yet");
        run(100.0, 5.0);
        CHECK(!g_generating, "10 s able to make 100 of its own: generated frames off, Steady's from here");
        // Started and stopped quickly, twice: each start waits longer.
        fresh(); t = 100.0;
        run(70.0, 10.0); CHECK(g_generating, "set-up: generating");
        run(40.0, 5.0); CHECK(!g_generating && g_genEngageBackoff == 10.0, "stopped within a minute of starting: the next start waits 10 s more (%.0f)", g_genEngageBackoff);
        run(70.0, 15.0); CHECK(!g_generating, "so 15 s at 70 isn't enough");
        run(70.0, 5.0); CHECK(g_generating, "20 s is");
        run(40.0, 5.0); CHECK(g_genEngageBackoff == 20.0, "stopped quickly again: 20 s more (%.0f)", g_genEngageBackoff);
        fresh(); t = 150.0;
        run(70.0, 10.0); run(70.0, 70.0); run(40.0, 5.0);
        CHECK(!g_generating && g_genEngageBackoff == 0.0, "on for over a minute before stopping: no wait added (%.0f)", g_genEngageBackoff);
        // A long session: Steady's even 80 of its own frames.
        fresh(); t = 200.0;
        run(70.0, 10.0); CHECK(g_generating, "set-up: generating");
        g_endurance = true;
        run(70.0, 5.0);
        CHECK(!g_generating, "on battery: generated frames off at the next window");
        run(70.0, 60.0);
        CHECK(!g_generating, "and not started again while on battery");
        g_endurance = false;
        // The display being looked at again: nothing started.
        fresh(); t = 300.0; g_vrrState = 2;
        run(70.0, 30.0);
        CHECK(!g_generating, "nothing started while the display is being looked at again");
        g_vrrState = 1;
        // Without Steady (up to 120): two to one up to 90 of its own, none above.
        fresh(); t = 400.0; g_steadyWanted = false;
        run(95.0, 20.0); CHECK(!g_generating, "up to 120, 95 fps of its own: shown as ready, none generated");
        run(80.0, 10.0); CHECK(g_generating && g_halfRate, "up to 120, 80 fps of its own: two to one");
        run(95.0, 10.0); CHECK(!g_generating, "able to make 95 again for 10 s: off");
        g_steadyWanted = true;
        // Not the player's choice: a variable-refresh panel shows the game's own frames.
        fresh(); t = 500.0; g_genForce = false;
        run(40.0, 60.0); CHECK(!g_generating, "not chosen: none generated on a variable-refresh panel, even at 40");
        g_genForce = true;

        // Smooth Motion: a heavy scene, a frame made halfway between each two of the game's own.
        g_smoothMotion = true;
        fresh(); t = 600.0; g_sessionStartAt = t;
        run(30.0, 25.0);
        CHECK(!g_generating, "Smooth Motion: nothing in the game's first 30 s");
        run(30.0, 5.0);
        CHECK(g_generating && g_fill && !g_halfRate && fabs(g_realSlotPeriod - 1.0 / 120.0) < 1e-9,
              "settled at 30 fps of its own: Smooth Motion — its frames shown as ready, one made halfway between each two");
        run(45.0, 30.0);
        CHECK(g_generating && g_fill, "kept through 45 fps");
        g_endurance = true;
        run(35.0, 30.0);
        CHECK(g_generating && g_fill, "kept in a long session (on battery): the GPU is full with the game's work there anyway");
        g_endurance = false;
        run(90.0, 5.0);
        CHECK(!g_generating && !g_fill, "able to make 90 of its own for 5 s: Smooth Motion off, its own frames");
        run(30.0, 5.0);
        CHECK(g_generating && g_fill && g_genEngageBackoff == 0.0,
              "back to 30: Smooth Motion again within the window — it had run over a minute, so no wait added");
        run(18.0, 5.0);
        CHECK(!g_generating, "down to 18 fps: too far apart to make a frame between — off");
        fresh(); t = 900.0; g_sessionStartAt = 0.0; g_vrrState = 0; g_vrrReported = false;
        run(30.0, 20.0);
        CHECK(!g_fill, "a fixed-refresh display without FSR 3's pictures: no Smooth Motion (0.47's frames ahead need a panel that follows)");
        g_vrrState = 1;
        fresh(); t = 1000.0; g_genForce = false;
        run(30.0, 20.0);
        CHECK(!g_generating, "frame generation not chosen: no Smooth Motion");
        g_genForce = true;
        fresh(); t = 1100.0;
        run(70.0, 20.0);
        CHECK(!g_generating && !g_halfRate && !g_fill,
              "70 fps with Smooth Motion on: its own frames as ready — not held to 60 of them for 60 guesses (13 October)");

        // Smooth Motion between frames (FSR 3 to the display, its pictures and motion to make them from).
        g_midAvailableForTest = 1;
        fresh(); t = 1200.0;
        run(18.0, 2.0, 2.0);
        CHECK(g_generating && g_fill && g_mid.load(),
              "18 fps of its own, frames between possible: Smooth Motion at once — 0.47's stopped at 24 (12 minutes of nothing at 18–23)");
        g_midRate.store(40.0);
        run(18.0, 10.0, 2.0);
        CHECK(g_mid.load(), "kept: the presenter sees 40 fps of the game's frames (its own time reads high while it waits on them)");
        g_midRate.store(70.0);
        run(30.0, 10.0, 2.0);
        CHECK(g_mid.load(), "at 70 by the presenter, under 62%% of the display's 120: kept, no frames made between (the presenter's choice)");
        g_midRate.store(80.0);
        run(30.0, 4.0, 2.0);
        CHECK(!g_mid.load() && !g_generating, "at 80 by the presenter for 4 s: off, its own frames");
        run(55.0, 2.0, 2.0);
        CHECK(g_mid.load() && g_genEngageBackoff == 0.0, "55 fps again: back at once, no wait added for a start that soon");
        g_midRate.store(9.0);
        run(9.0, 4.0, 2.0);
        CHECK(!g_mid.load(), "down to 9 by the presenter for 4 s: too far apart for a frame between — off");
        // Frames between costing the game its own: held for its drawable with the GPU idle.
        fresh(); t = 1300.0; g_gpuBusy.store(96);
        run(40.0, 2.0, 2.0);
        CHECK(g_mid.load() && g_midGpuBefore == 96, "40 fps, the GPU 96%% busy: frames between");
        g_gpuBusy.store(60); g_midRate.store(30.0);
        run(30.0, 6.0, 2.0);
        CHECK(!g_mid.load() && g_midWanted && g_midPausedUntil >= t + 59.0,
              "the GPU down to 60%% busy and the game to 30 for 6 s: frames between paused a minute — not off for the session (13 October)");
        g_midRate.store(0.0);
        run(40.0, 4.0, 2.0);
        CHECK(!g_generating && !g_fill, "paused: the game's own frames, no guesses ahead in their place");
        t += 60.0;
        g_gpuBusy.store(96);
        run(40.0, 2.0, 2.0);
        CHECK(g_mid.load(), "a minute on: frames between again");
        g_gpuBusy.store(60); g_midRate.store(30.0);
        run(30.0, 6.0, 2.0);
        CHECK(!g_mid.load() && g_midPausedUntil >= t + 119.0, "costing it again: paused twice as long");
        genStop(t, "%.0f", 0.0);
        g_midPausedUntil = 0.0; g_midPauseFor = 0.0; g_midRate.store(0.0); g_gpuBusy.store(-1);

        // Guardian (anvil_guardian.h): frames between found to cost more than they give at a rate on this Mac —
        // none there, and no guesses in their place; elsewhere as before. A check holds them off, or makes them.
        anvil_guardian::reset();
        anvil_guardian::noteCost(28.0); anvil_guardian::noteCost(28.0); anvil_guardian::noteCost(28.0);
        fresh(); t = 1400.0;
        run(28.0, 6.0, 2.0);
        CHECK(!g_mid.load() && !g_generating && !g_fill, "learned against at 25–30 fps: the game's own frames there");
        run(40.0, 2.0, 2.0);
        CHECK(g_mid.load(), "40 fps: frames between as before");
        genStop(t, "%.0f", 0.0);
        g_guardProbe = 1;
        fresh(); t = 1500.0;
        run(40.0, 6.0, 2.0);
        CHECK(!g_generating, "a check under way with them off: none started");
        g_guardProbe = 2;
        run(28.0, 2.0, 2.0);
        CHECK(g_mid.load(), "a check with them on: started at once, where they were learned against");
        g_guardProbe = 0;
        run(28.0, 6.0, 2.0);
        CHECK(!g_mid.load(), "the check over, still learned against: off again");
        anvil_guardian::reset();

        // Guardian's stutters (0.50): what a long frame was mostly, and which frames count.
        CHECK(stutterCause(142, 96, 38.0, 8, 2) == 0, "96 ms of a 142 ms frame reading 38 MB: reading its data");
        CHECK(stutterCause(142, 96, 0.2, 8, 2) == 3, "the same time on 0.2 MB: not called reading (a stalled call, not data)");
        CHECK(stutterCause(100, 5, 1.0, 60, 0) == 1, "60 of 100 ms compiling: compiling shaders");
        CHECK(stutterCause(100, 0, 0, 0, 55) == 2, "55 of 100 ms waiting for a drawable: the GPU or the display");
        CHECK(stutterCause(80, 10, 4.0, 10, 10) == 3, "none of them 40%%: the game's own work");
        {
            g_frames.store(2000);
            g_presentEma = 0.0125;
            const int all = g_stutters;
            guardianFrame(5000.0, 0.0125, 0.0);
            guardianFrame(5000.1, 0.08, 0.0);
            CHECK(g_stutters == all + 1, "an 80 ms frame among 12.5 ms ones: a stutter");
            guardianFrame(5000.2, 0.03, 0.0);
            CHECK(g_stutters == all + 1, "30 ms: not one (under 50 ms)");
            g_presentEma = 0.025;
            guardianFrame(5000.3, 0.06, 0.0);
            CHECK(g_stutters == all + 1, "60 ms among 25 ms frames: not one (under three times as long)");
            g_frames.store(100);
            guardianFrame(5000.4, 0.2, 0.0);
            CHECK(g_stutters == all + 1, "in the game's first 600 frames (its loading): not counted");
            g_frames.store(2000);
        }

        // A display at a fixed rate, frames between possible (0.49): from 15 fps to half its rate.
        fresh(); t = 1600.0; g_vrrState = 0; g_vrrReported = false;
        run(25.0, 2.0, 2.0);
        CHECK(g_mid.load() && g_fill, "fixed refresh, 25 fps, FSR 3's pictures: frames between");
        g_midRate.store(80.0);
        run(80.0, 4.0, 2.0);
        CHECK(!g_mid.load(), "and off above its range");
        g_midRate.store(0.0);
        genStop(t, "%.0f", 0.0);
        g_vrrState = 1;

        // 0.47's frames made ahead over FSR 1 (FSR 3 eased: none between), then FSR 3 back (0.55): frames between
        // instead, from the next window.
        g_midAvailableForTest = 0;
        fresh(); t = 1700.0;
        run(40.0, 6.0, 2.0);
        CHECK(g_generating && g_fill && !g_mid.load(), "40 fps, FSR 3 eased: 0.47's frames made ahead");
        g_midAvailableForTest = 1;
        run(40.0, 2.0, 2.0);
        CHECK(g_generating && g_fill && g_mid.load(), "FSR 3 back: frames between in their place, at once");
        genStop(t, "%.0f", 0.0);
        g_midWanted = true; g_midAvailableForTest = -1; g_gpuBusy.store(-1);
        g_smoothMotion = false;
        g_genForce = true;
        // A fixed 120 Hz display, chosen: as before, kept for the session — but two to one only
        // while the game holds every second refresh.
        fresh(); t = 600.0; g_vrrState = 0;
        run(70.0, 5.0);
        CHECK(g_generating && g_halfRate, "fixed display, 70 fps: two to one");
        run(45.0, 5.0);
        CHECK(g_generating && !g_halfRate, "down to 45: guessed frames only in the gaps it leaves, not one stretched over two");
        run(130.0, 60.0);
        CHECK(g_generating, "chosen on a fixed display: kept for the session, as before");
        g_vrrState = 1;
        // Started on a display judged fixed, then confirmed following: two to one, or nothing.
        // (Up to 120: with Steady a fixed display generates nothing above about 76 either.)
        g_steadyWanted = false;
        fresh(); t = 700.0; g_vrrState = 0;
        run(95.0, 5.0); CHECK(g_generating && !g_halfRate, "set-up: filling gaps on a display judged fixed");
        g_vrrState = 1;
        run(95.0, 5.0); CHECK(!g_generating, "confirmed following, at 95: off, its own frames shown as ready");
        fresh(); t = 800.0; g_vrrState = 0;
        run(95.0, 5.0); CHECK(g_generating && !g_halfRate, "set-up: filling gaps on a display judged fixed");
        g_vrrState = 1;
        run(72.0, 5.0); CHECK(g_generating && g_halfRate, "confirmed following, at 72: two to one");
        g_steadyWanted = true;
        // A ProMotion panel judged "doesn't follow" in its first seconds (the stand-in game on
        // 11 October, and six of fifteen LEGO sessions on 1–2 October): its own rules still, not
        // a fixed display's — nothing at 54, two to one at 70, and not kept for the session.
        g_vrrReported = true;
        fresh(); t = 900.0; g_vrrState = 0;
        run(54.0, 30.0); CHECK(!g_generating, "a ProMotion panel taken for fixed, the game at 54: nothing generated");
        run(70.0, 10.0); CHECK(g_generating && g_halfRate, "at 70: two to one, not guesses in the gaps");
        run(110.0, 10.0); CHECK(!g_generating, "able to make 110 again: off, not kept for the session");
        g_vrrReported = false; g_vrrState = 1;
        g_steadySettleSec = 0.0; g_generating = false; g_halfRate = false; g_frameGenRequested = false; g_genForce = false;
        g_realSlotPeriod = g_fullSlotPeriod;
    }

    // 0.57: held frames ask the panel for 10.5 ms, not 12.0 — still the 12.5 ms step, further from the 16.7 one.
    printf("Held gap:\n");
    {
        g_refreshPeriod = 1.0 / 120.0;
        CHECK(fabs(steadyHoldMinGap() - 0.0105) < 1e-9, "120 Hz: 10.5 ms (%.4f)", steadyHoldMinGap());
        const double step = 1.0 / 240.0;
        CHECK(fabs(std::ceil(steadyHoldMinGap() / step - 1e-9) * step - 0.0125) < 1e-9, "on the 240 Hz grid, the 12.5 ms step");
        g_refreshPeriod = 1.0 / 144.0;
        CHECK(steadyHoldMinGap() > g_refreshPeriod, "144 Hz: more than a refresh (%.4f)", steadyHoldMinGap());
        g_refreshPeriod = 1.0 / 120.0;
    }

    // 0.59: back after a long gap with no frames, what Anvil had backed off from starts afresh.
    printf("Back after a gap:\n");
    {
        const double settleWas = g_steadySettleSec;
        g_steadySettleSec = 30.0;
        g_lastPresentCallAt = -1.0; g_lastPresentWall = -1.0;
        double t = 1000.0;
        auto frames = [&](double seconds) { for (double end = t + seconds; t < end; t += 1.0 / 60.0) steadyOnPresent(t); };
        frames(40.0);
        const bool settledBefore = g_steadySettled;
        // Mid-fight: Smooth Motion paused for ten minutes, FSR 3 eased with a two-minute back-off, Steady backed off.
        g_midPauseFor = 600.0; g_midPausedUntil = t + 600.0;
        g_genEngageBackoff = 120.0;
        g_fsr3Eased = true; g_fsr3EaseBackoff = 120.0; g_fsr3NextBackAt = t + 120.0;
        g_holdBackoff = 60.0; g_nextHoldAt = t + 60.0; g_probeBackoff = 60.0; g_nextProbeAt = t + 60.0;
        t += 10.0;                      // ten seconds without a frame: a load, not a break
        frames(1.0);
        CHECK(g_midPausedUntil > t + 500.0 && g_holdBackoff == 60.0, "10 s with no frames changes nothing");
        CHECK(settledBefore && g_steadySettled, "nor restarts the settle");
        t += 20.0;                      // twenty: the game paused behind another app, the Mac asleep
        steadyOnPresent(t);
        CHECK(g_midPausedUntil <= t && g_midPauseFor == 0.0, "Smooth Motion's ten-minute pause lifted (%.0f s left)", g_midPausedUntil - t);
        CHECK(g_genEngageBackoff == 0.0, "frame generation's start back-off cleared");
        CHECK(g_fsr3EaseBackoff == 0.0 && g_fsr3NextBackAt <= t, "FSR 3 free to come back at once");
        CHECK(g_holdBackoff == 0.0 && g_nextHoldAt <= t && g_probeBackoff == 0.0 && g_nextProbeAt <= t, "Steady's back-offs cleared");
        CHECK(!g_steadySettled, "the first seconds back shown as ready");
        frames(kResumeSettleSec + 0.5);
        CHECK(g_steadySettled, "and settled again %.0f s later, not the session start's 30", kResumeSettleSec);
        // The Mac asleep: the clock every other timing uses stops, so the gap is read on one that doesn't.
        g_lastPresentWall = sleepingClock() - 2400.0;
        g_midPauseFor = 600.0; g_midPausedUntil = t + 600.0;
        steadyOnPresent(t + 1.0 / 60.0);
        CHECK(g_midPausedUntil <= t + 0.1, "40 minutes asleep is a gap, though CACurrentMediaTime barely moved");
        g_fsr3Eased = false; g_steadySettleSec = settleWas; g_steadySettled = settleWas <= 0.0;
        g_lastPresentCallAt = -1.0; g_lastPresentWall = -1.0;
    }

    // A picture's shape: the window's when within 2%, else the game's own, whole.
    printf("Picture shape:\n");
    {
        const CGSize lego = fitShape(CGSizeMake(1512, 982), CGSizeMake(3024, 1934));
        CHECK(lego.width == 3024 && lego.height == 1934, "1.5%% apart is the window's own (%.0fx%.0f)", lego.width, lego.height);
        const CGSize wide = fitShape(CGSizeMake(1920, 1080), CGSizeMake(3024, 1964));
        CHECK(wide.width == 3024 && wide.height == 1701, "16:9 on a MacBook Pro: whole, with bars above and below (%.0fx%.0f)", wide.width, wide.height);
        const CGSize tall = fitShape(CGSizeMake(1024, 768), CGSizeMake(3024, 1964));
        CHECK(tall.width == 2619 && tall.height == 1964, "4:3: whole, with bars either side (%.0fx%.0f)", tall.width, tall.height);
    }

    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("steady 80: all checks passed\n");
    return 0;
}

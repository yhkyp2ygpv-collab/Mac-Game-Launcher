// Guardian's learning (anvil_guardian.mm): what a window is worth, checks of frames between's worth started
// and judged, what's learned kept and read back, looked at again, and a check left when the scene changes.
//
//   clang++ -std=c++17 -ObjC++ -O1 guardian_test.mm ../../AnvilMetal/anvil_guardian.mm -o guardian_test
#include "../../AnvilMetal/anvil_guardian.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>

using namespace anvil_guardian;

static int g_failed = 0;
#define CHECK(cond, ...) do { if (!(cond)) { ++g_failed; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static Window win(double now, double own, double shown, bool between, double gapMean, double gapSd, bool eligible = true) {
    Window w;
    w.now = now; w.seconds = 2.0; w.own = own; w.shown = shown; w.between = between;
    w.gapMeanMs = gapMean; w.gapSdMs = gapSd; w.eligible = eligible; w.calm = true;
    return w;
}

// Plays windows two seconds apart: frames between giving (onOwn, onShown, onSd) and the game alone
// (offOwn, offOwn, offSd), as the glue would switch them. Returns the actions seen, in order.
struct Play {
    double now = 100.0;
    bool between = true;
    std::string actions;
    void run(int windows, double onOwn, double onShown, double onSd, double offOwn, double offSd, bool learnedOffSwitches = true) {
        for (int i = 0; i < windows; ++i) {
            const double own = between ? onOwn : offOwn, shown = between ? onShown : offOwn;
            const double mean = 1000.0 / shown, sd = between ? onSd * mean : offSd * mean;
            const Action a = step(win(now, own, shown, between, mean, sd));
            switch (a) {
            case Action::probeOff: actions += "off "; between = false; break;
            case Action::probeOn: actions += "on "; between = true; break;
            case Action::endProbe: actions += "end ";
                between = betweenWanted(offOwn); break;
            case Action::abortProbe: actions += "abort "; break;
            default: break;
            }
            // Learned off at this rate: the glue keeps frames between off there.
            if (a == Action::none && learnedOffSwitches && between && !betweenWanted(offOwn)) between = false;
            now += 2.0;
        }
    }
};

int main() {
    char path[256];
    snprintf(path, sizeof path, "%s/guardian_test_%d.txt", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", (int)getpid());
    unlink(path);

    // What a window is worth.
    {
        CHECK(std::fabs(score(win(0, 30, 30, false, 33.3, 0)) - 30.0) < 0.01, "own alone, even: %.2f", score(win(0, 30, 30, false, 33.3, 0)));
        const double s = score(win(0, 27, 54, true, 18.5, 0));
        CHECK(std::fabs(s - (27 + 0.7 * 27)) < 0.01, "with frames between: %.2f", s);
        const double uneven = score(win(0, 27, 54, true, 18.5, 18.5 * 0.4));
        CHECK(std::fabs(uneven - (27 + 0.7 * 27) * 0.6) < 0.01, "uneven: %.2f", uneven);
        const double notShown = score(win(0, 30, 24, false, 41.6, 0));
        CHECK(std::fabs(notShown - 24.0) < 0.01, "frames not shown count as not shown: %.2f", notShown);
        CHECK(bandOf(14.9) == -1 && bandOf(15) == 0 && bandOf(29) == 2 && bandOf(30) == 3 && bandOf(74.9) == 7 && bandOf(75) == -1,
              "bands");
    }

    // A Mac where frames between help: checked, found better, kept on.
    {
        configure(path, true);
        reset();
        Play p;
        p.run(10, 26.0, 52.0, 0.05, 29.0, 0.1);
        CHECK(p.actions.find("off end") != std::string::npos, "a check, judged: '%s'", p.actions.c_str());
        Result r;
        CHECK(lastResult(&r) && r.band == 2 && r.change > 0.3 && r.wanted, "frames between found better at 25–30: band %d change %.2f",
              r.band, r.change);
        CHECK(betweenWanted(28.0), "wanted at 28");
        CHECK(checksThisSession() >= 1, "checked: %d", checksThisSession());
    }

    // A Mac where they cost: the game halved with frames between on and its frames uneven. Three checks
    // and frames between are off at that rate.
    {
        reset();
        Play p;
        p.run(80, 15.5, 31.0, 0.45, 28.0, 0.08);
        CHECK(!betweenWanted(28.0), "learned off at 25–30 after: '%s'", p.actions.c_str());
        CHECK(betweenWanted(40.0), "other rates untouched");
        int ends = 0;
        for (size_t at = 0; (at = p.actions.find("end", at)) != std::string::npos; ++at) ++ends;
        CHECK(ends >= 3, "three checks at least: %d ('%s')", ends, p.actions.c_str());
        char words[640];
        describe(words, sizeof words);
        CHECK(strstr(words, "not at 25–30 fps") != nullptr, "described: %s", words);

        // Kept, and read back in the next session.
        CHECK(save(), "saved");
        reset();
        CHECK(betweenWanted(28.0), "forgotten by reset");
        CHECK(load(), "loaded");
        CHECK(!betweenWanted(28.0), "learned off again from the file");

        // Looked at again: with frames between off there and eligible, a check with them on comes.
        Play again;
        again.between = false;
        again.run(30, 15.5, 31.0, 0.45, 28.0, 0.08);
        CHECK(again.actions.find("on ") != std::string::npos, "looked at again: '%s'", again.actions.c_str());
        CHECK(!betweenWanted(28.0), "and still off: they still cost");
    }

    // A check left when the scene changes under it.
    {
        reset();
        double now = 100.0;
        Action a = Action::none;
        for (int i = 0; i < 6 && a != Action::probeOff; ++i, now += 2.0) a = step(win(now, 26, 52, true, 19.2, 1));
        CHECK(a == Action::probeOff, "a check started");
        CHECK(step(win(now, 29, 29, false, 34.5, 2)) == Action::none, "its first window passed over");
        now += 2.0;
        CHECK(step(win(now, 70, 70, false, 14.3, 1)) == Action::abortProbe, "a scene twice as light: left");
        CHECK(checksThisSession() == 0, "and not counted");
    }

    // The presenter's own guard: counted against frames between at the rate it began at.
    {
        reset();
        noteCost(33.0); noteCost(33.0); noteCost(33.0);
        CHECK(!betweenWanted(33.0), "three costs at 30–36: off there");
        CHECK(betweenWanted(26.0), "not elsewhere");
    }

    // Not before the session has settled, nor while Anvil's other choices are changing.
    {
        configure(path, false);
        reset();
        double now = 100.0;
        Action a = step(win(now, 26, 52, true, 19.2, 1));
        for (int i = 0; i < 2; ++i) { now += 2.0; a = step(win(now, 26, 52, true, 19.2, 1)); }
        CHECK(a == Action::none, "settling");
        Window w = win(now + 2.0, 26, 52, true, 19.2, 1);
        w.calm = false;
        configure(path, true);
        a = step(w);
        CHECK(a == Action::none, "not calm: no check");
    }

    unlink(path);
    if (g_failed) { printf("guardian: %d checks FAILED\n", g_failed); return 1; }
    printf("guardian: all checks passed\n");
    return 0;
}

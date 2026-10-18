// Guardian's learning — see anvil_guardian.h.
#include "anvil_guardian.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <os/lock.h>
#include <string>
#include <unistd.h>

namespace anvil_guardian {
namespace {

// Bands of the game's own frame rate, Smooth Motion's range on any display: from 15 fps, below which a
// frame between is too far from both sides, to 75, above which no display Anvil knows wants one.
constexpr double kEdges[] = {15.0, 20.0, 25.0, 30.0, 36.0, 42.0, 50.0, 60.0, 75.0};
constexpr int kBands = (int)(sizeof kEdges / sizeof kEdges[0]) - 1;

struct Band {
    int n = 0;             // checks
    double mean = 0.0;     // frames between against the game's own alone: +0.4 is 40% better
    double m2 = 0.0;       // Welford's sum of squares
    double lastAt = -1e9;  // the last check, this session
};

struct Timing {
    double settle;     // no check in a session's first seconds
    double gap;        // between any two checks
    double learning;   // between checks in a band with fewer than three
    double unsure;     // with three or more that don't yet agree
    double sure;       // that do
    int perSession;    // checks a session at most
};
constexpr Timing kNormal = {60.0, 45.0, 45.0, 180.0, 900.0, 20};
constexpr Timing kFast = {4.0, 4.0, 4.0, 8.0, 20.0, 50};

// Against frames between at a rate: three checks or more, a loss of more than 5% on average, and the
// average a standard error clear of nothing.
constexpr double kLoss = -0.05;
constexpr int kDecideAfter = 3;
// Worth of a made frame against a real one, and the most uneven gaps can take off.
constexpr double kMadeWorth = 0.7;
constexpr double kUnevenMax = 0.5;

// A lock with nothing to tear down: the game's threads can still be drawing while its process exits, after
// C++ objects have been destroyed (a std::mutex there throws when locked).
os_unfair_lock g_lock = OS_UNFAIR_LOCK_INIT;
struct Locked {
    Locked() { os_unfair_lock_lock(&g_lock); }
    ~Locked() { os_unfair_lock_unlock(&g_lock); }
};
Band g_bands[kBands];
// A plain buffer, set before anything else in the library runs: libanvil reads its settings from its load-
// time constructor, which can run before this file's own — a std::string here was constructed after
// configure() had set it, and emptied it (Anvil's stand-in, 14 October: nothing learned was ever kept).
char g_path[1024] = {0};
Timing g_t = kNormal;
double g_sessionStart = -1.0;
double g_lastCheckAt = -1e9;
int g_checks = 0;

// The last windows, newest last.
constexpr int kHistory = 3;
Window g_history[kHistory];
int g_historyN = 0;

// A check under way: the arm switched (true: frames between off for it), its reference and windows seen.
bool g_probing = false;
bool g_probeOff = false;
double g_refScore = 0.0, g_refOwn = 0.0;
int g_probeWindows = 0;
double g_probeStartedAt = 0.0;

Result g_last;
bool g_haveLast = false;

double se(const Band& b) { return b.n >= 2 ? std::sqrt(b.m2 / (b.n - 1) / b.n) : 1e9; }

bool wanted(const Band& b) {
    return !(b.n >= kDecideAfter && b.mean < kLoss && b.mean + se(b) < 0.0);
}

bool sure(const Band& b) { return b.n >= kDecideAfter && std::fabs(b.mean) > 2.0 * se(b); }

double interval(const Band& b) {
    if (b.n < kDecideAfter) return g_t.learning;
    return sure(b) ? g_t.sure : g_t.unsure;
}

void add(Band& b, double x) {
    ++b.n;
    const double d = x - b.mean;
    b.mean += d / b.n;
    b.m2 += d * (x - b.mean);
}

void push(const Window& w) {
    if (g_historyN == kHistory) {
        for (int i = 1; i < kHistory; ++i) g_history[i - 1] = g_history[i];
        g_historyN = kHistory - 1;
    }
    g_history[g_historyN++] = w;
}

int bandLocked(double own) {
    if (!(own >= kEdges[0]) || own >= kEdges[kBands]) return -1;
    for (int i = 0; i < kBands; ++i)
        if (own < kEdges[i + 1]) return i;
    return -1;
}

}  // namespace

void configure(const char* statePath, bool fast) {
    Locked h;
    snprintf(g_path, sizeof g_path, "%s", statePath ? statePath : "");
    g_t = fast ? kFast : kNormal;
}

void reset() {
    Locked h;
    for (Band& b : g_bands) b = Band{};
    g_sessionStart = -1.0;
    g_lastCheckAt = -1e9;
    g_checks = 0;
    g_historyN = 0;
    g_probing = false;
    g_haveLast = false;
}

bool load() {
    Locked h;
    if (!g_path[0]) return false;
    FILE* f = fopen(g_path, "r");
    if (!f) return false;
    char line[256];
    bool ok = false;
    if (fgets(line, sizeof line, f) && strncmp(line, "anvil-guardian 1", 16) == 0) {
        ok = true;
        while (fgets(line, sizeof line, f)) {
            double lo = 0, hi = 0, mean = 0, m2 = 0;
            int n = 0;
            if (sscanf(line, "band %lf %lf %d %lf %lf", &lo, &hi, &n, &mean, &m2) != 5) continue;
            const int b = bandLocked(0.5 * (lo + hi));
            if (b < 0 || std::fabs(kEdges[b] - lo) > 0.01 || n < 0 || n > 100000 || !std::isfinite(mean) || !std::isfinite(m2)) continue;
            g_bands[b].n = n;
            g_bands[b].mean = mean;
            g_bands[b].m2 = std::max(0.0, m2);
        }
    }
    fclose(f);
    return ok;
}

bool save() {
    Locked h;
    if (!g_path[0]) return false;
    const std::string tmp = std::string(g_path) + ".new";
    FILE* f = fopen(tmp.c_str(), "w");
    if (!f) return false;
    fprintf(f, "anvil-guardian 1\n");
    for (int i = 0; i < kBands; ++i)
        if (g_bands[i].n > 0)
            fprintf(f, "band %.0f %.0f %d %.4f %.6f\n", kEdges[i], kEdges[i + 1], g_bands[i].n, g_bands[i].mean, g_bands[i].m2);
    const bool written = fclose(f) == 0;
    return written && rename(tmp.c_str(), g_path) == 0;
}

double score(const Window& w) {
    if (w.own <= 0.0) return 0.0;
    const double shown = w.shown > 0.0 ? w.shown : w.own;
    const double real = std::min(w.own, shown);
    const double made = std::min(std::max(0.0, shown - w.own), real);
    const double uneven = w.gapMeanMs > 0.0 ? std::min(kUnevenMax, w.gapSdMs / w.gapMeanMs) : 0.0;
    return (real + kMadeWorth * made) * (1.0 - uneven);
}

int bandOf(double own) {
    Locked h;
    return bandLocked(own);
}

int bandCount() { return kBands; }

void bandRange(int band, double* lo, double* hi) {
    if (band < 0 || band >= kBands) { *lo = *hi = 0.0; return; }
    *lo = kEdges[band];
    *hi = kEdges[band + 1];
}

bool betweenWanted(double own) {
    Locked h;
    const int b = bandLocked(own);
    return b < 0 || wanted(g_bands[b]);
}

void noteCost(double own) {
    Locked h;
    const int b = bandLocked(own);
    if (b >= 0) add(g_bands[b], -0.33);
}

Action step(const Window& w) {
    Locked h;
    if (g_sessionStart < 0.0) g_sessionStart = w.now;

    if (g_probing) {
        ++g_probeWindows;
        // The first window after the switch has both in it, and the presenter starting or stopping.
        if (g_probeWindows == 1) return Action::none;
        // The scene changed under the check: nothing to compare. The game's own rate with frames between
        // against without, as a ratio — they can cost it a lot, which is what a check is for (a game held to
        // half its rate by them is still the same scene), but not more than that, and gain it nothing.
        const double base = g_probeOff ? w.own : g_refOwn;
        const double withBetween = g_probeOff ? g_refOwn : w.own;
        const double ratio = base > 0.0 ? withBetween / base : 0.0;
        const bool sameScene = ratio >= 0.45 && ratio <= 1.15 && bandLocked(base) >= 0;
        if (!sameScene || w.own <= 0.0 || g_probeWindows > 4) {
            g_probing = false;
            g_historyN = 0;
            return Action::abortProbe;
        }
        const double now = score(w);
        const double on = g_probeOff ? g_refScore : now, off = g_probeOff ? now : g_refScore;
        if (off <= 0.0) { g_probing = false; g_historyN = 0; return Action::abortProbe; }
        const double change = on / off - 1.0;
        const int b = bandLocked(base);
        add(g_bands[b], std::max(-1.0, std::min(1.5, change)));
        g_bands[b].lastAt = w.now;
        g_lastCheckAt = w.now;
        ++g_checks;
        g_last = Result{b, kEdges[b], kEdges[b + 1], change, g_bands[b].n, g_bands[b].mean, wanted(g_bands[b])};
        g_haveLast = true;
        g_probing = false;
        g_historyN = 0;
        return Action::endProbe;
    }

    push(w);
    if (g_historyN < kHistory) return Action::none;
    if (w.now - g_sessionStart < g_t.settle || w.now - g_lastCheckAt < g_t.gap || g_checks >= g_t.perSession) return Action::none;
    // Three windows alike: the same choice, nothing else changing, the game's rate within a fifth.
    double own = 0.0;
    for (int i = 0; i < kHistory; ++i) {
        const Window& x = g_history[i];
        if (x.between != w.between || !x.calm || x.own <= 0.0) return Action::none;
        own += x.own / kHistory;
    }
    for (int i = 0; i < kHistory; ++i)
        if (std::fabs(g_history[i].own - own) > 0.2 * own) return Action::none;
    const int b = bandLocked(own);
    if (b < 0) return Action::none;
    Band& band = g_bands[b];
    if (w.now - band.lastAt < interval(band)) return Action::none;
    const bool off = w.between;
    if (!off) {
        // Frames between off here only because Guardian learned so — looked at again now and then.
        for (int i = 0; i < kHistory; ++i)
            if (!g_history[i].eligible) return Action::none;
        if (wanted(band)) return Action::none;
    }
    g_probing = true;
    g_probeOff = off;
    g_refScore = 0.5 * (score(g_history[kHistory - 1]) + score(g_history[kHistory - 2]));
    g_refOwn = own;
    g_probeWindows = 0;
    g_probeStartedAt = w.now;
    return off ? Action::probeOff : Action::probeOn;
}

bool lastResult(Result* r) {
    Locked h;
    if (!g_haveLast || !r) return false;
    *r = g_last;
    return true;
}

int checksThisSession() {
    Locked h;
    return g_checks;
}

int describe(char* out, size_t room) {
    Locked h;
    if (!out || room == 0) return 0;
    out[0] = 0;
    std::string help, not_, learning;
    char part[96];
    for (int i = 0; i < kBands; ++i) {
        const Band& b = g_bands[i];
        if (b.n == 0) continue;
        snprintf(part, sizeof part, "%s%.0f–%.0f fps (%+.0f%%, %d check%s)", "", kEdges[i], kEdges[i + 1], b.mean * 100.0, b.n,
                 b.n == 1 ? "" : "s");
        std::string& to = b.n < kDecideAfter ? learning : (wanted(b) ? help : not_);
        if (!to.empty()) to += ", ";
        to += part;
    }
    std::string all;
    if (!help.empty()) all += "frames between help at " + help;
    if (!not_.empty()) all += (all.empty() ? "" : "; ") + std::string("not at ") + not_;
    if (!learning.empty()) all += (all.empty() ? "" : "; ") + std::string("still learning ") + learning;
    if (all.empty()) all = "nothing yet";
    return snprintf(out, room, "%s", all.c_str());
}

}  // namespace anvil_guardian

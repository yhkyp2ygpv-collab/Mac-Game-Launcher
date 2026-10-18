// Anvil Surround's stereo-to-surround split (anvil_upmix.h), on test signals whose answer is known:
// a voice in the middle goes to the centre, a stereo room to the surrounds, a sound panned to one
// side stays in its front speaker, nothing is lost or doubled, the delay is exactly 512 samples,
// any buffer size gives the same sound, silence stays silent, and it is cheap enough for a game.
//
//   clang++ -std=c++17 -ObjC++ -O2 -framework Accelerate Native/Tools/tests/upmix_test.mm -o /tmp/upmix_test && /tmp/upmix_test
#include "../../AnvilMetal/anvil_upmix.h"
#include <chrono>
#include <cstdio>
#include <memory>
#include <random>
#include <vector>

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { ++failures; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

using Planes = std::vector<std::vector<float>>;

// Runs `left`/`right` through a fresh upmixer in buffers of `chunk` frames (0: varying sizes).
static Planes run(const std::vector<float>& left, const std::vector<float>& right, uint32_t width, double rate = 48000,
                  uint32_t chunk = 512) {
    auto up = std::make_unique<anvil_upmix::Upmixer>();
    if (!up->init(rate, width)) { printf("FAIL: init\n"); ++failures; return {}; }
    Planes out(width, std::vector<float>(left.size()));
    std::mt19937 rng(7);
    size_t at = 0;
    while (at < left.size()) {
        const uint32_t n = std::min<size_t>(chunk ? chunk : 1 + rng() % 1500, left.size() - at);
        float* planes[8];
        for (uint32_t c = 0; c < width; ++c) planes[c] = out[c].data() + at;
        up->process(left.data() + at, right.data() + at, n, planes);
        at += n;
    }
    return out;
}

static double energy(const std::vector<float>& x, size_t from) {
    double e = 0;
    for (size_t i = from; i < x.size(); ++i) e += double(x[i]) * x[i];
    return e;
}

static std::vector<float> noise(size_t n, uint32_t seed, float level = 0.3f) {
    std::mt19937 rng(seed);
    std::normal_distribution<float> d(0.0f, level);
    std::vector<float> x(n);
    for (auto& v : x) v = d(rng);
    return x;
}

// Speech-like: noise shaped into a 150–3000 Hz band (falling 24 dB an octave above it, as a
// voice's energy does) with a syllable rhythm.
static std::vector<float> voice(size_t n, uint32_t seed, double rate = 48000) {
    auto x = noise(n, seed, 0.4f);
    float lp[4] = {}, hp = 0, prev = 0;
    for (size_t i = 0; i < n; ++i) {
        float y = x[i];
        for (float& p : lp) { p += 0.33f * (y - p); y = p; }   // ~3 kHz, four poles
        const float h = y - prev; prev = y;        // gentle high-pass
        hp = 0.98f * hp + h;
        const float syllable = 0.5f + 0.5f * std::sin(2 * M_PI * 4.0 * i / rate);
        x[i] = hp * syllable;
    }
    return x;
}

int main() {
    const size_t N = 48000 * 4;                     // four seconds
    const size_t settle = 48000;                    // judged after the first second
    const double rate = 48000;

    // 1. A sound in one side only: untouched, in its own front speaker, exactly 512 samples late.
    {
        const auto x = noise(N, 1);
        const std::vector<float> zero(N, 0.0f);
        const auto out = run(x, zero, 8);
        double err = 0, sig = 0;
        for (size_t i = settle; i < N; ++i) {
            const double d = out[0][i] - x[i - anvil_upmix::kSize];
            err += d * d; sig += double(x[i]) * x[i];
        }
        CHECK(err / sig < 1e-6, "a sound in the left side alone comes back %.1f dB from the original (want < −60)", 10 * std::log10(err / sig + 1e-30));
        double elsewhere = 0;
        for (int c = 1; c < 8; ++c) elsewhere += energy(out[c], settle);
        CHECK(elsewhere / sig < 1e-6, "the left side alone leaks %.1f dB into other speakers", 10 * std::log10(elsewhere / sig + 1e-30));
        printf("one side: %.1f dB from the original, 512 samples (%.1f ms) later\n", 10 * std::log10(err / sig + 1e-30), 512 * 1000.0 / rate);
    }

    // 2. A voice in the middle (the same in both sides): mostly to the centre, none behind.
    {
        const auto v = voice(N, 2);
        const auto out = run(v, v, 8);
        const double in = 2 * energy(v, settle);
        double sum = 0; for (int c = 0; c < 8; ++c) sum += energy(out[c], settle);
        const double centre = energy(out[2], settle) / sum, around = (energy(out[4], settle) + energy(out[5], settle) + energy(out[6], settle) + energy(out[7], settle)) / sum;
        CHECK(centre > 0.7, "a voice in the middle: %.0f%% to the centre (want > 70%%)", centre * 100);
        CHECK(around < 0.01, "a voice in the middle: %.1f%% behind or beside (want < 1%%)", around * 100);
        CHECK(std::fabs(10 * std::log10(sum / in)) < 1.0, "a voice in the middle: %.2f dB louder or quieter in all", 10 * std::log10(sum / in));
        CHECK(energy(out[3], 0) == 0, "nothing to the LFE");
        printf("voice in the middle: %.0f%% centre, %.1f%% around, %.2f dB overall\n", centre * 100, around * 100, 10 * std::log10(sum / in));
    }

    // 3. A stereo room (the two sides unrelated): a good share to the surrounds, little to the centre.
    {
        const auto l = noise(N, 3), r = noise(N, 4);
        const auto out = run(l, r, 8);
        const double in = energy(l, settle) + energy(r, settle);
        double sum = 0; for (int c = 0; c < 8; ++c) sum += energy(out[c], settle);
        const double around = (energy(out[4], settle) + energy(out[5], settle) + energy(out[6], settle) + energy(out[7], settle)) / sum;
        const double centre = energy(out[2], settle) / sum;
        CHECK(around > 0.25, "a stereo room: %.0f%% to the surrounds (want > 25%%)", around * 100);
        CHECK(centre < 0.05, "a stereo room: %.1f%% to the centre (want < 5%%)", centre * 100);
        CHECK(std::fabs(10 * std::log10(sum / in)) < 1.0, "a stereo room: %.2f dB louder or quieter in all", 10 * std::log10(sum / in));
        // Left stays left: the left surround carries the left side's room, not the right's.
        double ll = 0, lr = 0;
        for (size_t i = settle; i < N; ++i) { ll += double(out[6][i]) * l[i - anvil_upmix::kSize - 480]; lr += double(out[6][i]) * r[i - anvil_upmix::kSize - 480]; }
        CHECK(ll > 5 * std::fabs(lr), "the left surround follows the left side (%.3g against %.3g), 10 ms after the front", ll, lr);
        printf("stereo room: %.0f%% surrounds (beside and behind), %.1f%% centre, %.2f dB overall\n", around * 100, centre * 100, 10 * std::log10(sum / in));
    }

    // 4. A sound panned part-way left: stays at the front, louder on the left.
    {
        const auto x = noise(N, 5);
        std::vector<float> r(N);
        for (size_t i = 0; i < N; ++i) r[i] = 0.35f * x[i];
        const auto out = run(x, r, 8);
        double sum = 0; for (int c = 0; c < 8; ++c) sum += energy(out[c], settle);
        const double fl = energy(out[0], settle), fr = energy(out[1], settle);
        const double around = (energy(out[4], settle) + energy(out[5], settle) + energy(out[6], settle) + energy(out[7], settle)) / sum;
        CHECK(fl > 4 * fr, "panned left: front left %.3g, front right %.3g", fl, fr);
        CHECK(around < 0.01, "panned left: %.1f%% behind or beside (want < 1%%)", around * 100);
        printf("panned left: front left %.0f%%, front right %.0f%%, centre %.0f%%, around %.1f%%\n", 100 * fl / sum, 100 * fr / sum,
               100 * energy(out[2], settle) / sum, 100 * around);
    }

    // 5. A voice in a room, the room 12 dB under it: most of the voice to the centre, the room around.
    {
        const auto v = voice(N, 6);
        const float roomLevel = float(std::sqrt(energy(v, 0) / N)) * 0.25f;
        const auto nl = noise(N, 7, roomLevel), nr = noise(N, 8, roomLevel);
        std::vector<float> l(N), r(N);
        for (size_t i = 0; i < N; ++i) { l[i] = v[i] + nl[i]; r[i] = v[i] + nr[i]; }
        const auto out = run(l, r, 8);
        // How much of the voice each speaker carries: its output projected on the voice.
        double share[8], total = 0;
        const double vn = energy(v, settle);
        for (int c = 0; c < 8; ++c) {
            double p = 0;
            for (size_t i = settle; i < N; ++i) p += double(out[c][i]) * v[i - anvil_upmix::kSize];
            share[c] = (p / vn) * (p / vn);
            total += share[c];
        }
        double room = 0, roomAround = 0;
        for (size_t i = settle; i < N; ++i) {
            const double nl0 = nl[i - anvil_upmix::kSize];
            room += nl0 * nl0;
        }
        for (int c = 4; c < 8; ++c) {
            double p = 0;
            for (size_t i = settle; i < N; ++i) p += double(out[c][i]) * nl[i - anvil_upmix::kSize - (c >= 6 ? 480 : 864)];
            roomAround += (p * p) / (room * room);
        }
        CHECK(share[2] / total > 0.6, "voice in a room: %.0f%% of the voice from the centre (want > 60%%)", 100 * share[2] / total);
        CHECK(share[4] + share[5] + share[6] + share[7] < 0.02 * total, "voice in a room: the voice behind or beside");
        CHECK(roomAround > 0.05, "voice in a room: %.0f%% of the room's left side reaches the left surrounds", 100 * roomAround);
        printf("voice in a room: %.0f%% of the voice from the centre, %.0f%% of the room around you\n", 100 * share[2] / total, 100 * roomAround);
    }

    // 6. Any buffer size, the same sound; 5.1 keeps the room in its one surround pair.
    {
        const auto l = noise(N / 2, 9), r = noise(N / 2, 10);
        const auto a = run(l, r, 8, rate, 512), b = run(l, r, 8, rate, 0);
        double diff = 0;
        for (int c = 0; c < 8; ++c) for (size_t i = 0; i < a[c].size(); ++i) diff = std::max(diff, double(std::fabs(a[c][i] - b[c][i])));
        CHECK(diff < 1e-6, "buffers of 512 and of 1 to 1500 frames differ by %.3g", diff);
        const auto six = run(l, r, 6);
        double sum = 0; for (int c = 0; c < 6; ++c) sum += energy(six[c], settle / 2);
        const double around = (energy(six[4], settle / 2) + energy(six[5], settle / 2)) / sum;
        CHECK(around > 0.25, "5.1: %.0f%% to the surrounds", around * 100);
        const auto at44 = run(l, r, 8, 44100);
        double s44 = 0; for (int c = 0; c < 8; ++c) s44 += energy(at44[c], settle / 2);
        CHECK(s44 > 0 && std::isfinite(s44), "44.1 kHz");
    }

    // 7. Silence in, silence out — and nothing that isn't a number, even from a hard clip.
    {
        const std::vector<float> zero(N / 4, 0.0f);
        const auto out = run(zero, zero, 8);
        double e = 0; for (int c = 0; c < 8; ++c) e += energy(out[c], 0);
        CHECK(e == 0, "silence comes out as %.3g", e);
        std::vector<float> clip(N / 4);
        for (size_t i = 0; i < clip.size(); ++i) clip[i] = (i / 37) % 2 ? 1.0f : -1.0f;
        const auto loud = run(clip, clip, 8);
        bool finite = true;
        for (auto& p : loud) for (float v : p) finite = finite && std::isfinite(v);
        CHECK(finite, "a full-scale square wave gives something that isn't a number");
    }

    // 8. Cost: a minute of 48 kHz stereo, in game-sized buffers.
    {
        const size_t M = 48000 * 60;
        const auto l = noise(M, 11), r = noise(M, 12);
        auto up = std::make_unique<anvil_upmix::Upmixer>();
        up->init(48000, 8);
        std::vector<float> o(8 * 512);
        float* planes[8];
        for (int c = 0; c < 8; ++c) planes[c] = o.data() + c * 512;
        const auto t0 = std::chrono::steady_clock::now();
        for (size_t at = 0; at + 512 <= M; at += 512) up->process(l.data() + at, r.data() + at, 512, planes);
        const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        CHECK(ms < 600, "a minute of stereo took %.0f ms to split (want under 1%% of a core)", ms);
        printf("cost: %.0f ms per minute of sound (%.2f%% of one core)\n", ms, ms / 600.0);
    }

    if (failures) { printf("%d failures\n", failures); return 1; }
    printf("anvil surround: all checks passed\n");
    return 0;
}

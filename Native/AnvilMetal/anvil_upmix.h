// Anvil Surround: a stereo game's sound made into surround.
//
// Many games mix only in stereo, whatever Windows says the output plays — or, through XAudio2,
// put their stereo sound in a 7.1 mix's front pair and leave the other six channels silent. 3D
// sound then has two speakers to place, ahead left and ahead right, and nothing comes from
// beside or behind the player. This splits such a stereo mix the way a surround decoder for
// films does, but by frequency rather than by a fixed matrix:
//
//   every 2.7 ms, for each of 257 bands from 0 to half the sample rate, it measures the two
//   sides' levels and how much they move together, averaged over 40 ms, and reads the band as
//   one sound placed between the speakers plus a room unrelated between the sides (the split
//   film and music upmixers call primary and ambience). From that it sends
//     - what is the same in both sides, panned to the middle (voices, as games mix them), to
//       the centre speaker, taking it out of the two fronts so it is not doubled;
//     - what the two sides don't share (reverb, rain, crowds, wind: a stereo mix's room), in
//       part to the surrounds, beside and behind, 10 and 18 ms later than the front so a sound
//       is still heard where it starts — ahead (the precedence effect);
//     - what is panned to one side, and the bass, to the fronts, where the game put it.
//   Every band keeps its energy: what goes to the centre or the surrounds is taken from the
//   fronts. Nothing goes to the LFE (a game's stereo bass stays in its speakers, as it would on
//   a surround system with bass management). The split adds 512 samples of delay (10.7 ms at
//   48 kHz) and costs a fraction of a percent of one core.
//
// One Upmixer per stream, set up before the output starts; process() runs on CoreAudio's I/O
// thread and neither allocates nor locks.
#pragma once

#import <Accelerate/Accelerate.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace anvil_upmix {

constexpr int kSize = 512;                // one analysis frame — and the delay the split adds
constexpr int kHop = 128;                 // a new frame every quarter frame
constexpr int kHalf = kSize / 2;          // bands 0…kHalf
constexpr int kDelayRing = 8192;          // ambience delay lines (power of two): 42 ms at 192 kHz
constexpr int kOutputs = 5;               // front left, front right, centre, ambience left, right

struct Upmixer {
    /// Ready to process(): `channels` is the surround mix it writes — 8 (7.1) or 6 (5.1), in
    /// Windows' order (FL FR FC LFE BL BR [SL SR]). False if Accelerate won't set up its DFT.
    bool init(double sampleRate, uint32_t channels) {
        release();
        rate = sampleRate > 0 ? sampleRate : 48000.0;
        width = channels == 6 ? 6 : 8;
        forward = vDSP_DFT_zrop_CreateSetup(nullptr, kSize, vDSP_DFT_FORWARD);
        inverse = forward ? vDSP_DFT_zrop_CreateSetup(forward, kSize, vDSP_DFT_INVERSE) : nullptr;
        if (!forward || !inverse) { release(); return false; }
        for (int n = 0; n < kSize; ++n) window[n] = std::sqrt(0.5f - 0.5f * std::cos(2.0f * float(M_PI) * n / kSize));
        // The round trip's gain, measured rather than assumed: Accelerate's real DFTs scale by
        // 2 one way and kSize the other, and the windows overlap four deep.
        float overlap = 0;
        for (int m = 0; m < kSize / kHop; ++m) overlap += window[(m * kHop + kHop / 2) % kSize] * window[(m * kHop + kHop / 2) % kSize];
        float probe[kSize], back[kSize];
        for (int n = 0; n < kSize; ++n) probe[n] = std::sin(0.37f * n) + 0.25f * std::cos(1.91f * n);
        roundTrip(probe, back);
        double dot = 0, norm = 0;
        for (int n = 0; n < kSize; ++n) { dot += double(back[n]) * probe[n]; norm += double(probe[n]) * probe[n]; }
        const double gain = norm > 0 ? dot / norm : 0;
        if (!(gain > 0) || !(overlap > 0)) { release(); return false; }
        scale = float(1.0 / (gain * overlap));
        // Bands: the centre from 90–180 Hz up, easing above 8 kHz (sibilance and air stay
        // wide); ambience from 150–300 Hz up (below that coherence can't be told apart in a
        // frame this short, and bass from behind only muddies).
        for (int k = 0; k <= kHalf; ++k) {
            const float hz = float(k * rate / kSize);
            const float low = std::clamp((hz - 90.0f) / 90.0f, 0.0f, 1.0f);
            const float high = hz > 8000.0f ? std::max(0.5f, 1.0f - (hz - 8000.0f) / 12000.0f) : 1.0f;
            centreWeight[k] = kCentreMost * low * high;
            ambientWeight[k] = std::clamp((hz - 150.0f) / 150.0f, 0.0f, 1.0f);
        }
        beta = float(std::exp(-double(kHop) / (0.040 * rate)));
        sideDelay = std::min<uint32_t>(uint32_t(0.010 * rate), kDelayRing - 1);
        backDelay = std::min<uint32_t>(uint32_t(0.018 * rate), kDelayRing - 1);
        reset();
        return true;
    }

    void reset() {
        memset(inL, 0, sizeof inL); memset(inR, 0, sizeof inR);
        memset(acc, 0, sizeof acc); memset(ready, 0, sizeof ready);
        memset(pll, 0, sizeof pll); memset(prr, 0, sizeof prr); memset(plrRe, 0, sizeof plrRe); memset(plrIm, 0, sizeof plrIm);
        memset(cLast, 0, sizeof cLast); memset(aLastL, 0, sizeof aLastL); memset(aLastR, 0, sizeof aLastR);
        memset(ambience, 0, sizeof ambience);
        have = 0; ring = 0;
    }

    void release() {
        if (inverse) vDSP_DFT_DestroySetup(inverse);
        if (forward) vDSP_DFT_DestroySetup(forward);
        inverse = forward = nullptr;
    }

    ~Upmixer() { release(); }

    /// `frames` of the stereo mix in, the same many of surround out, `kSize` samples later: one
    /// plane per channel of `width`. Planes may be the input's own (`out[0] == left` is fine).
    void process(const float* left, const float* right, uint32_t frames, float* const* out) noexcept [[clang::nonblocking]] {
        uint32_t done = 0;
        while (done < frames) {
            const uint32_t take = std::min<uint32_t>(kHop - have, frames - done);
            // The input is taken in before any output is written, so the output may be its planes.
            memcpy(inL + (kSize - kHop) + have, left + done, take * sizeof(float));
            memcpy(inR + (kSize - kHop) + have, right + done, take * sizeof(float));
            for (uint32_t j = 0; j < take; ++j) {
                const uint32_t at = have + j, i = done + j;
                ambience[0][ring] = ready[3][at];
                ambience[1][ring] = ready[4][at];
                const float sideL = ambience[0][(ring - sideDelay) & (kDelayRing - 1)];
                const float sideR = ambience[1][(ring - sideDelay) & (kDelayRing - 1)];
                ring = (ring + 1) & (kDelayRing - 1);
                out[0][i] = ready[0][at];
                out[1][i] = ready[1][at];
                out[2][i] = ready[2][at];
                out[3][i] = 0.0f;
                if (width == 6) {
                    out[4][i] = sideL;
                    out[5][i] = sideR;
                } else {
                    const float backL = ambience[0][(ring - 1 - backDelay) & (kDelayRing - 1)];
                    const float backR = ambience[1][(ring - 1 - backDelay) & (kDelayRing - 1)];
                    out[4][i] = kBackShare * backL;
                    out[5][i] = kBackShare * backR;
                    out[6][i] = kSideShare * sideL;
                    out[7][i] = kSideShare * sideR;
                }
            }
            have += take;
            done += take;
            if (have == kHop) {
                frame();
                have = 0;
            }
        }
    }

    uint32_t width = 8;
    double rate = 48000.0;

private:
    // The centre takes at most 81% of a sound panned dead centre (0.9²) — a little stays in the
    // fronts, so a voice keeps the width it was mixed with. Of what the sides don't share, half
    // goes to the surrounds; on 7.1 that is split 64:36 between beside and behind.
    static constexpr float kCentreMost = 0.9f;
    static constexpr float kAmbientShare = 0.5f;
    static constexpr float kSideShare = 0.8f, kBackShare = 0.6f;

    void roundTrip(const float* x, float* y) {
        DSPSplitComplex in = {sr, si};
        vDSP_ctoz(reinterpret_cast<const DSPComplex*>(x), 2, &in, 1, kHalf);
        vDSP_DFT_Execute(forward, sr, si, lr, li);
        vDSP_DFT_Execute(inverse, lr, li, tr, ti);
        DSPSplitComplex t = {tr, ti};
        vDSP_ztoc(&t, 1, reinterpret_cast<DSPComplex*>(y), 2, kHalf);
    }

    void transform(const float* x, float* re, float* im) noexcept [[clang::nonblocking]] {
        float w[kSize];
        vDSP_vmul(x, 1, window, 1, w, 1, kSize);
        DSPSplitComplex in = {sr, si};
        vDSP_ctoz(reinterpret_cast<const DSPComplex*>(w), 2, &in, 1, kHalf);
        vDSP_DFT_Execute(forward, sr, si, re, im);
    }

    /// One frame: both sides to bands, each band split, the five outputs back and overlapped.
    void frame() noexcept [[clang::nonblocking]] {
        transform(inL, lr, li);
        transform(inR, rr, ri);
        for (int k = 0; k <= kHalf; ++k) {
            // Accelerate packs the two real bands, 0 and kHalf, into slot 0.
            const bool dc = k == 0, nyquist = k == kHalf;
            const int slot = nyquist ? 0 : k;
            const float lRe = nyquist ? li[0] : lr[slot], lIm = (dc || nyquist) ? 0.0f : li[slot];
            const float rRe = nyquist ? ri[0] : rr[slot], rIm = (dc || nyquist) ? 0.0f : ri[slot];
            const float b = beta, nb = 1.0f - beta;
            pll[k] = b * pll[k] + nb * (lRe * lRe + lIm * lIm);
            prr[k] = b * prr[k] + nb * (rRe * rRe + rIm * rIm);
            plrRe[k] = b * plrRe[k] + nb * (lRe * rRe + lIm * rIm);
            plrIm[k] = b * plrIm[k] + nb * (lIm * rRe - lRe * rIm);
            // The band as one sound placed somewhere between the speakers plus a room the same
            // in level on both sides and unrelated between them: the room's level is what makes
            // the two sides' measured powers and their shared part (the cross term) agree.
            const float sum = pll[k] + prr[k];
            float c = 0.0f, aL = 0.0f, aR = 0.0f;
            if (sum > 1e-18f) {
                const float cross = std::sqrt(plrRe[k] * plrRe[k] + plrIm[k] * plrIm[k]);
                const float diff = pll[k] - prr[k];
                const float room = std::max(0.0f, 0.5f * (sum - std::sqrt(diff * diff + 4.0f * cross * cross)));
                const float soundL = std::max(0.0f, pll[k] - room), soundR = std::max(0.0f, prr[k] - room);
                const float sound = soundL + soundR;
                // How far the sound is from the middle: 1 for the same in both sides, 0 for one side only.
                const float centred = sound > 1e-20f ? std::min(1.0f, 2.0f * cross / sound) : 0.0f;
                const float middle = std::clamp((centred - 0.7f) / 0.3f, 0.0f, 1.0f);
                const float cWant = centreWeight[k] * std::sqrt(middle * middle * middle * (sound / sum));
                const float aWantL = pll[k] > 1e-20f ? ambientWeight[k] * std::sqrt(kAmbientShare * room / pll[k]) : 0.0f;
                const float aWantR = prr[k] > 1e-20f ? ambientWeight[k] * std::sqrt(kAmbientShare * room / prr[k]) : 0.0f;
                c = 0.5f * (cLast[k] + cWant);
                aL = 0.5f * (aLastL[k] + aWantL);
                aR = 0.5f * (aLastR[k] + aWantR);
                const float taken = c * c + std::max(aL * aL, aR * aR);
                if (taken > 0.98f) { const float t = std::sqrt(0.98f / taken); c *= t; aL *= t; aR *= t; }
            }
            cLast[k] = c;
            aLastL[k] = aL;
            aLastR[k] = aR;
            const float fL = std::sqrt(std::max(0.0f, 1.0f - c * c - aL * aL));
            const float fR = std::sqrt(std::max(0.0f, 1.0f - c * c - aR * aR));
            const float cm = c * float(M_SQRT1_2);
            // Front left, front right, centre, ambience left, ambience right.
            const float re[kOutputs] = {fL * lRe, fR * rRe, cm * (lRe + rRe), aL * lRe, aR * rRe};
            const float im[kOutputs] = {fL * lIm, fR * rIm, cm * (lIm + rIm), aL * lIm, aR * rIm};
            for (int o = 0; o < kOutputs; ++o) {
                if (dc) { bandRe[o][0] = re[o]; }
                else if (nyquist) { bandIm[o][0] = re[o]; }
                else { bandRe[o][k] = re[o]; bandIm[o][k] = im[o]; }
            }
        }
        float y[kSize];
        for (int o = 0; o < kOutputs; ++o) {
            vDSP_DFT_Execute(inverse, bandRe[o], bandIm[o], tr, ti);
            DSPSplitComplex t = {tr, ti};
            vDSP_ztoc(&t, 1, reinterpret_cast<DSPComplex*>(y), 2, kHalf);
            for (int n = 0; n < kSize; ++n) acc[o][n] += y[n] * window[n] * scale;
            memcpy(ready[o], acc[o], kHop * sizeof(float));
            memmove(acc[o], acc[o] + kHop, (kSize - kHop) * sizeof(float));
            memset(acc[o] + (kSize - kHop), 0, kHop * sizeof(float));
        }
        memmove(inL, inL + kHop, (kSize - kHop) * sizeof(float));
        memmove(inR, inR + kHop, (kSize - kHop) * sizeof(float));
    }

    vDSP_DFT_Setup forward = nullptr, inverse = nullptr;
    float scale = 1.0f, beta = 0.9f;
    uint32_t sideDelay = 480, backDelay = 864;
    uint32_t have = 0, ring = 0;
    float window[kSize];
    float inL[kSize], inR[kSize];
    float acc[kOutputs][kSize];
    float ready[kOutputs][kHop];
    float pll[kHalf + 1], prr[kHalf + 1], plrRe[kHalf + 1], plrIm[kHalf + 1];
    float cLast[kHalf + 1], aLastL[kHalf + 1], aLastR[kHalf + 1];
    float centreWeight[kHalf + 1], ambientWeight[kHalf + 1];
    float sr[kHalf], si[kHalf], lr[kHalf], li[kHalf], rr[kHalf], ri[kHalf], tr[kHalf], ti[kHalf];
    float bandRe[kOutputs][kHalf], bandIm[kOutputs][kHalf];
    float ambience[2][kDelayRing];
};

} // namespace anvil_upmix

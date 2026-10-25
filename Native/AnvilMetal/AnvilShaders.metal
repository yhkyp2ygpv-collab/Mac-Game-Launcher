// Anvil's frame pipeline, in Metal.
//
// These run on the frame after D3DMetal has finished translating it, which is the
// cheapest place to stand: the image is already a Metal texture, so an upscale or
// interpolation pass costs one dispatch and no format conversion.

#include <metal_stdlib>
using namespace metal;

// =============================================================================
// EASU — edge-adaptive spatial upsampling (FSR 1's first stage)
//
// Implemented from AMD's published algorithm rather than linked from their SDK:
// for each output pixel, take a 12-tap neighbourhood, fit the local gradient, and
// weight the taps along the detected edge direction. That directionality is what
// separates it from a bilinear stretch — edges stay straight instead of stair-stepping.
// =============================================================================

static inline float3 fetch(texture2d<float, access::sample> src, sampler s, float2 uv) {
    return src.sample(s, uv).rgb;
}

// Lanczos-style 2-lobe weight, approximated by the quadratic AMD uses — the exact
// transcendental costs more than the image quality it buys at these tap counts.
static inline float easuWeight(float x2, float attenuation) {
    float b = (2.0 / 5.0) * x2 - 1.0;
    float t = (1.0 / 4.0) * x2 - 1.0;
    b *= b;
    t *= t;
    return attenuation * b * t;
}

kernel void anvil_easu(texture2d<float, access::sample> src   [[texture(0)]],
                       texture2d<float, access::write>  dst   [[texture(1)]],
                       constant float4&                 params[[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;

    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);

    const float2 srcSize   = float2(src.get_width(), src.get_height());
    const float2 dstSize   = float2(dst.get_width(), dst.get_height());
    const float2 texel     = 1.0 / srcSize;

    // Centre of this output pixel, expressed in source space.
    const float2 pos = (float2(gid) + 0.5) * (srcSize / dstSize);
    const float2 base = floor(pos - 0.5) + 0.5;
    const float2 f = pos - base;

    // 12-tap cross: the 4 nearest plus the 8 that reveal edge direction.
    float3 c[12];
    c[0]  = fetch(src, s, (base + float2(-1.0,  0.0)) * texel);
    c[1]  = fetch(src, s, (base + float2( 0.0, -1.0)) * texel);
    c[2]  = fetch(src, s, (base + float2( 1.0, -1.0)) * texel);
    c[3]  = fetch(src, s, (base + float2( 2.0,  0.0)) * texel);
    c[4]  = fetch(src, s, (base + float2(-1.0,  1.0)) * texel);
    c[5]  = fetch(src, s, (base + float2( 0.0,  0.0)) * texel);
    c[6]  = fetch(src, s, (base + float2( 1.0,  0.0)) * texel);
    c[7]  = fetch(src, s, (base + float2( 2.0,  1.0)) * texel);
    c[8]  = fetch(src, s, (base + float2(-1.0,  2.0)) * texel);
    c[9]  = fetch(src, s, (base + float2( 0.0,  1.0)) * texel);
    c[10] = fetch(src, s, (base + float2( 1.0,  1.0)) * texel);
    c[11] = fetch(src, s, (base + float2( 1.0,  2.0)) * texel);

    // Luma drives edge detection; chroma follows the same weights so colour can't
    // drift away from luminance and produce fringing.
    const float3 lumaCoeff = float3(0.2126, 0.7152, 0.0722);
    float l[12];
    for (int i = 0; i < 12; ++i) l[i] = dot(c[i], lumaCoeff);

    // Local gradient from the inner quad.
    float lA = l[5], lB = l[6], lC = l[9], lD = l[10];
    float dx = (lB - lA) + (lD - lC);
    float dy = (lC - lA) + (lD - lB);
    float len = max(1e-5, sqrt(dx * dx + dy * dy));
    float2 dir = float2(dx, dy) / len;

    // Sharper weighting across the edge than along it. This is the whole trick.
    float sharpness = clamp(params.x, 0.0, 1.0);
    float attenuation = mix(1.0, 2.0, sharpness);
    float2 axis = float2(abs(dir.x), abs(dir.y));

    float3 accum = float3(0.0);
    float weightSum = 0.0;
    const float2 offsets[12] = {
        float2(-1, 0), float2(0, -1), float2(1, -1), float2(2, 0),
        float2(-1, 1), float2(0,  0), float2(1,  0), float2(2, 1),
        float2(-1, 2), float2(0,  1), float2(1,  1), float2(1, 2)
    };
    for (int i = 0; i < 12; ++i) {
        float2 d = offsets[i] - f;
        // Stretch distance along the edge so taps parallel to it contribute more.
        float2 warped = d * mix(float2(1.0), axis.yx + 0.5, 0.5);
        float x2 = dot(warped, warped);
        float w = easuWeight(x2, attenuation);
        accum += c[i] * w;
        weightSum += w;
    }

    float3 outColor = accum / max(weightSum, 1e-5);

    // Clamp to the inner quad so the sharpening can never invent a value brighter
    // or darker than the pixels it came from — that is what stops ringing.
    float3 lo = min(min(c[5], c[6]), min(c[9], c[10]));
    float3 hi = max(max(c[5], c[6]), max(c[9], c[10]));
    outColor = clamp(outColor, lo, hi);

    dst.write(float4(outColor, 1.0), gid);
}

// =============================================================================
// RCAS — robust contrast-adaptive sharpening.
//
// A direct port of AMD's FsrRcasF from the FidelityFX SDK v1.1.4
// (sdk/include/FidelityFX/gpu/fsr1/ffx_fsr1.h, MIT, Copyright (C) 2024 Advanced
// Micro Devices, Inc. — see THIRD-PARTY.md). This replaces a hand-written
// approximation that had no noise term and cruder limiters, so it over-sharpened
// grain and haloed on high-contrast edges.
//
// The algorithm derives, from the 5-tap cross around each pixel, the largest
// sharpening lobe that cannot push any channel outside the range already present in
// that neighbourhood. That constraint is what prevents ringing, and it is why the
// strength is computed per pixel rather than being a global slider.
// =============================================================================

constant float kRcasLimit = 0.25 - (1.0 / 16.0);

kernel void anvil_rcas(texture2d<float, access::read>  src   [[texture(0)]],
                       texture2d<float, access::write> dst   [[texture(1)]],
                       constant float4&                params[[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    const int w = int(src.get_width()), h = int(src.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) return;

    const int2 sp = int2(gid);
    const int2 lim = int2(w - 1, h - 1);

    //    b
    //  d e f
    //    h
    const float3 b  = src.read(uint2(clamp(sp + int2( 0, -1), int2(0), lim))).rgb;
    const float3 d  = src.read(uint2(clamp(sp + int2(-1,  0), int2(0), lim))).rgb;
    const float3 e  = src.read(uint2(clamp(sp,                int2(0), lim))).rgb;
    const float3 f  = src.read(uint2(clamp(sp + int2( 1,  0), int2(0), lim))).rgb;
    const float3 hh = src.read(uint2(clamp(sp + int2( 0,  1), int2(0), lim))).rgb;

    // Luma times two, in AMD's weighting.
    const float bL = b.b  * 0.5 + (b.r  * 0.5 + b.g);
    const float dL = d.b  * 0.5 + (d.r  * 0.5 + d.g);
    const float eL = e.b  * 0.5 + (e.r  * 0.5 + e.g);
    const float fL = f.b  * 0.5 + (f.r  * 0.5 + f.g);
    const float hL = hh.b * 0.5 + (hh.r * 0.5 + hh.g);

    // Noise detection: how far the centre sits from the mean of its ring, relative
    // to the ring's own spread. Sharpening is scaled down where this is high, so
    // grain and dither are not amplified into crawling speckle.
    float nz = 0.25 * (bL + dL + fL + hL) - eL;
    const float range = max(max(max(bL, dL), max(eL, fL)), hL)
                      - min(min(min(bL, dL), min(eL, fL)), hL);
    nz = saturate(abs(nz) / max(range, 1e-5));
    nz = -0.5 * nz + 1.0;

    const float3 mn4 = min(min(b, d), min(f, hh));
    const float3 mx4 = max(max(b, d), max(f, hh));

    // Limiters: the largest lobe that keeps every channel inside the existing range.
    const float2 peak = float2(1.0, -4.0);
    const float3 hitMin = mn4 / max(4.0 * mx4, float3(1e-5));
    // 4 * mn4 - 4 is zero wherever all four neighbours are at full intensity in a
    // channel — a lightsaber core, an explosion, blown-out bloom — and 0 / 0 is NaN.
    // Shaders are built with fast math, where NaN is not guaranteed to lose a max(),
    // so it could reach the output as a black or garbage pixel. Kept just below zero,
    // the lobe there comes out 0: nothing to sharpen, which is the right answer.
    const float3 hitMax = (peak.x - mx4) / min(4.0 * mn4 + peak.y, float3(-1.0 / 1024.0));
    const float3 lobeRGB = max(-hitMin, hitMax);

    // Sharpness arrives 0..1 from the UI; AMD's parameter is in stops of reduction
    // where 0 is maximum, so it is inverted and exponentiated here.
    const float sharpness = clamp(params.x, 0.0, 1.0);
    const float scale = exp2(-(1.0 - sharpness) * 2.0);

    float lobe = max(-kRcasLimit,
                     min(max(max(lobeRGB.r, lobeRGB.g), lobeRGB.b), 0.0)) * scale;
    lobe *= nz;

    const float rcpL = 1.0 / (4.0 * lobe + 1.0);
    const float3 outColor = (lobe * (b + d + hh + f) + e) * rcpL;

    dst.write(float4(outColor, 1.0), gid);
}

// =============================================================================
// Optical flow — block matching between two presented frames.
//
// This is what makes frame generation possible with no engine data: motion is
// measured from the images themselves rather than supplied by the game. It is the
// same principle as AMD's AFMF and the reason that works everywhere.
// =============================================================================

// Search is done on a quarter-resolution luma plane rather than the colour frame.
// Motion doesn't need chroma, and a single-channel texture a sixteenth the size
// keeps the whole search window in cache — which is where the cost actually goes.
kernel void anvil_luma_pyramid(texture2d<float, access::sample> src [[texture(0)]],
                               texture2d<float, access::write>  dst [[texture(1)]],
                               uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    // Bilinear sampling at quarter size averages 4 texels for free.
    float3 c = src.sample(s, uv).rgb;
    dst.write(float4(dot(c, float3(0.2126, 0.7152, 0.0722)), 0, 0, 0), gid);
}

// Block-matched optical flow, following the structure of AMD's FidelityFX
// opticalflow v5 (MIT, Copyright (C) 2024 Advanced Micro Devices, Inc. — see
// THIRD-PARTY.md). Their key idea is that the search window is loaded into
// threadgroup memory once and every candidate reads it from there. A naive kernel
// re-reads texture memory per candidate, which is what forced the earlier version
// here down to a 3-step approximation; with the window resident, the full
// exhaustive search is affordable and the vectors are correspondingly better.

constant int kBlockSize    = 8;                    // 8x8 reference block
constant int kSearchRadius = 8;                    // +/-8 candidates per axis
constant int kSearchSpan   = 2 * kSearchRadius + 1;      // 17
constant int kWindow       = kBlockSize + 2 * kSearchRadius;  // 24x24 window
constant int kThreads      = 256;                        // 16x16 threadgroup

// strideIn: luma pixels between one flow texel and the next — the flow field's divisor. It
// was a constant 4 whatever the field's size, so with Anvil's default divisor of
// 8 the field's 1/8-size grid of blocks only reached half-way across and down the frame, and
// every vector was shown at twice its block's position: motion measured in the top-left
// quarter, used for the whole picture. Fixed in 0.29.
kernel void anvil_optical_flow(
    texture2d<float, access::read>  prev  [[texture(0)]],
    texture2d<float, access::read>  curr  [[texture(1)]],
    texture2d<float, access::write> flow  [[texture(2)]],
    constant int&                   strideIn [[buffer(0)]],
    uint2  groupId  [[threadgroup_position_in_grid]],
    uint   localId  [[thread_index_in_threadgroup]],
    uint   simdLane [[thread_index_in_simdgroup]],
    uint   simdId   [[simdgroup_index_in_threadgroup]])
{
    threadgroup float  block[kBlockSize * kBlockSize];
    threadgroup float  window[kWindow * kWindow];
    threadgroup float  simdCost[kThreads / 32];
    threadgroup uint   simdPick[kThreads / 32];

    const int w = int(curr.get_width()), h = int(curr.get_height());
    const int2 bounds = int2(w - 1, h - 1);
    // One threadgroup per flow texel, `stride` luma pixels apart. Blocks are 8x8 whatever
    // the stride: at 4 they overlap, which an 8x8 block matches more reliably than a 4x4
    // one does; at 8 they tile the frame.
    const int stride = clamp(strideIn, 1, kBlockSize * 2);
    const int2 origin = int2(groupId) * stride - (kBlockSize - stride) / 2;

    // --- Cooperative load. Each thread pulls a share of both tiles. ---
    for (int i = int(localId); i < kBlockSize * kBlockSize; i += kThreads) {
        int2 p = clamp(origin + int2(i % kBlockSize, i / kBlockSize), int2(0), bounds);
        block[i] = curr.read(uint2(p)).r;
    }
    for (int i = int(localId); i < kWindow * kWindow; i += kThreads) {
        int2 p = clamp(origin - kSearchRadius + int2(i % kWindow, i / kWindow), int2(0), bounds);
        window[i] = prev.read(uint2(p)).r;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // --- Every thread scores its share of the 289 candidates. ---
    float bestCost = INFINITY;
    int   bestIdx  = kSearchRadius * kSearchSpan + kSearchRadius;   // zero motion

    for (int c = int(localId); c < kSearchSpan * kSearchSpan; c += kThreads) {
        const int ox = c % kSearchSpan, oy = c / kSearchSpan;
        float sad = 0.0;
        for (int by = 0; by < kBlockSize; ++by) {
            for (int bx = 0; bx < kBlockSize; ++bx) {
                sad += abs(block[by * kBlockSize + bx] -
                           window[(oy + by) * kWindow + (ox + bx)]);
            }
        }
        // Prefer smaller motion on ties; flat regions otherwise flicker between
        // equally-good matches from frame to frame.
        sad += 0.001 * float(abs(ox - kSearchRadius) + abs(oy - kSearchRadius));
        if (sad < bestCost) { bestCost = sad; bestIdx = c; }
    }

    // --- Reduce to the single best candidate: within each SIMD group, then across. ---
    float simdBest = simd_min(bestCost);
    // Lowest lane holding the winning cost reports its index, so ties resolve
    // deterministically rather than by whichever lane happens to write last.
    uint  vote   = (bestCost == simdBest) ? simdLane : 0xFFFFu;
    uint  winner = simd_min(vote);
    if (simdLane == winner) { simdCost[simdId] = simdBest; simdPick[simdId] = uint(bestIdx); }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (localId != 0) return;

    float finalCost = simdCost[0];
    uint  finalIdx  = simdPick[0];
    for (uint i = 1; i < kThreads / 32; ++i) {
        if (simdCost[i] < finalCost) { finalCost = simdCost[i]; finalIdx = simdPick[i]; }
    }

    const int2 motion = int2(int(finalIdx) % kSearchSpan, int(finalIdx) / kSearchSpan) - kSearchRadius;
    // Confidence falls off as residual error rises; the interpolator uses it to
    // decide where the motion can be trusted.
    const float blockArea = float(kBlockSize * kBlockSize);
    const float confidence = saturate(1.0 - (finalCost / blockArea) * 8.0);

    // Offsets are in quarter-res luma space; scale back to full resolution.
    flow.write(float4(float2(motion) * 4.0, confidence, 1.0), groupId);
}

// =============================================================================
// Frame interpolation — synthesise the midpoint between two real frames.
// =============================================================================

kernel void anvil_interpolate(texture2d<float, access::sample> prev [[texture(0)]],
                              texture2d<float, access::sample> curr [[texture(1)]],
                              texture2d<float, access::sample> flow [[texture(2)]],
                              texture2d<float, access::write>  dst  [[texture(3)]],
                              constant float4& params [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);

    const float2 size = float2(dst.get_width(), dst.get_height());
    const float2 uv = (float2(gid) + 0.5) / size;
    const float phase = clamp(params.x, 0.0, 1.0);   // 0.5 for a single midpoint frame

    float4 f = flow.sample(s, uv);
    float2 motion = f.xy / size;
    float confidence = f.z;

    // Walk backwards along the motion from each side, so the sample lands where the
    // pixel actually was at this instant rather than where it starts or ends.
    float3 a = prev.sample(s, uv + motion * phase).rgb;
    float3 b = curr.sample(s, uv - motion * (1.0 - phase)).rgb;
    float3 warped = mix(a, b, phase);

    // Where motion couldn't be resolved, a straight cross-fade is wrong but stable;
    // a bad motion vector is far more visible than a soft blend.
    float3 blended = mix(prev.sample(s, uv).rgb, curr.sample(s, uv).rgb, phase);

    dst.write(float4(mix(blended, warped, confidence), 1.0), gid);
}

// =============================================================================
// Frame extrapolation — predict the NEXT frame instead of filling in a past gap.
//
// Interpolation is higher quality but structurally costs a frame of latency: the
// midpoint between two real frames can only be shown once both exist, so the newer
// one must be held back. Extrapolation projects forward from the two frames already
// presented, so nothing is held back and latency is unchanged from not running
// frame generation at all.
//
// The trade is direction changes. A projected frame assumes motion continues; when
// it reverses, the prediction is wrong for one frame. Confidence-weighted fallback
// to the unmodified frame keeps that failure soft rather than a visible tear.
// =============================================================================

kernel void anvil_extrapolate(texture2d<float, access::sample> prev [[texture(0)]],
                              texture2d<float, access::sample> curr [[texture(1)]],
                              texture2d<float, access::sample> flow [[texture(2)]],
                              texture2d<float, access::write>  dst  [[texture(3)]],
                              constant float4& params [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);

    const float2 size = float2(dst.get_width(), dst.get_height());
    const float2 uv = (float2(gid) + 0.5) / size;
    // How far past the newest real frame to project. 0.5 places the synthesised
    // frame halfway to where the next real frame is expected.
    const float phase = clamp(params.x, 0.0, 1.0);
    // The flow's pixels to this frame's: 1, or — with FSR 3's motion, measured at the game's
    // size, and frames at the display's — the ratio between them.
    const float toDst = params.y > 0.0 ? params.y : 1.0;

    float4 f = flow.sample(s, uv);
    f.xy *= toDst;
    float2 motion = f.xy / size;
    float confidence = f.z;

    // The flow search matches a block in `curr` against `prev`, so its vector points
    // backwards in time. Content therefore travels by -motion per frame, and the
    // pixel predicted to land at uv is the one currently at uv + motion * phase.
    float3 projected = curr.sample(s, uv + motion * phase).rgb;

    // Very fast motion is the least trustworthy, because a direction change costs
    // most there. The taper only engages past what normal camera movement produces —
    // 16 px/frame is ordinary panning, not an outlier, and discounting it wastes
    // most of the effect.
    float speed = length(f.xy);
    float speedTrust = saturate(1.0 - max(0.0, speed - 48.0) / 48.0);

    // Where the motion around disagrees — something moving across what's behind it — the field,
    // sampled between its blocks, is a blend of two motions that is neither's: projected along
    // it, the edge drags the background with it, a smear around everything that moves. There
    // the newest real frame is shown as it is: a moving edge a moment behind, not smeared.
    const float2 step = 1.0 / float2(flow.get_width(), flow.get_height());
    float apart = 0.0;
    const float2 around[4] = { float2(-step.x, 0.0), float2(step.x, 0.0), float2(0.0, -step.y), float2(0.0, step.y) };
    for (int i = 0; i < 4; ++i) apart = max(apart, length(flow.sample(s, uv + around[i]).xy * toDst - f.xy));
    const float edgeTrust = saturate(1.0 - (apart - 2.0) / 6.0);

    float3 safe = curr.sample(s, uv).rgb;
    dst.write(float4(mix(safe, projected, confidence * speedTrust * edgeTrust), 1.0), gid);
}

// =============================================================================
// Anvil's own overlay.
//
// Apple's Metal HUD shows everything it knows — device, Rosetta mode, memory,
// draw counts — and exposes no supported way to ask for less. Anvil already runs a
// compute pass over every presented frame, so drawing its own counter costs one
// extra dispatch and gives exact control over what appears.
//
// Digits are a 3x5 bitmap packed into a uint per glyph, scaled up at draw time.
// A texture atlas would be overkill for eleven glyphs.
// =============================================================================

// Row-major, 3 bits per row, 5 rows: bit 0 is the top-left pixel.
// Seven of these ten were wrong. Each comment described the intended shape
// correctly and the hex beside it did not match — 6 and 9 were each other's
// bitmap, so the counter reported 69 fps as 96. The values below are generated
// from the comments rather than typed: bit index is y*3 + x, bit 0 top-left.
constant uint kDigitGlyphs[11] = {
    0x7B6F, // 0  111 101 101 101 111
    0x749A, // 1  010 110 010 010 111
    0x73E7, // 2  111 001 111 100 111
    0x79E7, // 3  111 001 111 001 111
    0x49ED, // 4  101 101 111 001 001
    0x79CF, // 5  111 100 111 001 111
    0x7BCF, // 6  111 100 111 101 111
    0x24A7, // 7  111 001 010 010 010
    0x7BEF, // 8  111 101 111 101 111
    0x79EF, // 9  111 101 111 001 111
    0x0000  // space
};

static inline bool glyphPixel(uint glyph, int x, int y) {
    if (x < 0 || x > 2 || y < 0 || y > 4) return false;
    return (kDigitGlyphs[glyph] >> (uint(y * 3 + x))) & 1u;
}

/// params: x = fps, y = scale, z = corner (0..3), w = opacity
kernel void anvil_overlay(texture2d<float, access::read>  src   [[texture(0)]],
                          texture2d<float, access::write> dst   [[texture(1)]],
                          constant float4&                params[[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]])
{
    const int w = int(src.get_width()), h = int(src.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) return;

    float4 colour = src.read(gid);

    const int value = clamp(int(params.x + 0.5), 0, 9999);
    const int scale = max(int(params.y), 1);
    const int glyphW = 3 * scale, glyphH = 5 * scale, gap = scale;
    const int digits = value >= 1000 ? 4 : (value >= 100 ? 3 : (value >= 10 ? 2 : 1));
    const int boxW = digits * glyphW + (digits - 1) * gap + 4 * scale;
    const int boxH = glyphH + 4 * scale;

    // Corner placement, inset by a little so it clears rounded window edges.
    const int inset = 8 * scale;
    const bool hot = int(params.z) >= 4;              // the corner, plus 4 while the Mac is hot
    const int corner = clamp(int(params.z) & 3, 0, 3);
    const int originX = (corner == 1 || corner == 3) ? (w - boxW - inset) : inset;
    const int originY = (corner >= 2) ? (h - boxH - inset) : inset;

    const int lx = int(gid.x) - originX, ly = int(gid.y) - originY;
    if (lx < 0 || ly < 0 || lx >= boxW || ly >= boxH) {
        dst.write(colour, gid);
        return;
    }

    // Dim plate behind the digits so they stay readable over a bright scene.
    colour.rgb *= (1.0 - 0.65 * clamp(params.w, 0.0, 1.0));
    if (hot) colour.rgb = mix(colour.rgb, float3(0.75, 0.08, 0.05), 0.6);

    const int textX = lx - 2 * scale, textY = ly - 2 * scale;
    const int cell = glyphW + gap;
    const int index = textX / cell;
    if (index >= 0 && index < digits && (textX % cell) < glyphW) {
        int divisor = 1;
        for (int i = 0; i < digits - index - 1; ++i) divisor *= 10;
        const uint digit = uint((value / divisor) % 10);
        if (glyphPixel(digit, (textX % cell) / scale, textY / scale)) {
            // Green while comfortably above 60, amber below.
            colour.rgb = value >= 60 ? float3(0.45, 1.0, 0.45) : float3(1.0, 0.75, 0.3);
        }
    }
    dst.write(colour, gid);
}

// =============================================================================
// Fused finish pass: RCAS and the overlay in a single dispatch.
//
// Running them separately costs two full-resolution blits and two dispatches —
// measured at 2.25 ms per frame at 3024x1964, a fifth of the budget at 90fps and
// enough to be felt as stutter. The blit is the expensive part (1.08 ms each), so
// the win is in doing one instead of two.
//
// params: x = sharpness, y = fps, z = overlay scale, w = corner + overlay flag
//         (negative w disables the overlay)
// =============================================================================

/// anvil_finish's RCAS, for anvil_fsr_fused. anvil_finish keeps its own copy: compiled from
/// a shared function, the two-pass picture came out up to 4/255 different from before on
/// some pixels (the compiler orders fast-math arithmetic by the code around it), and what
/// every game already shows stays exactly as it was. Colours are held to 0–1 by the caller.
static inline float3 fsrRcas(float3 b, float3 d, float3 e, float3 f, float3 hh, float sharpnessIn)
{
    const float sharpness = clamp(sharpnessIn, 0.0, 1.0);
    if (sharpness <= 0.001) return e;
    const float bL = b.b  * 0.5 + (b.r  * 0.5 + b.g);
    const float dL = d.b  * 0.5 + (d.r  * 0.5 + d.g);
    const float eL = e.b  * 0.5 + (e.r  * 0.5 + e.g);
    const float fL = f.b  * 0.5 + (f.r  * 0.5 + f.g);
    const float hL = hh.b * 0.5 + (hh.r * 0.5 + hh.g);

    float nz = 0.25 * (bL + dL + fL + hL) - eL;
    const float range = max(max(max(bL, dL), max(eL, fL)), hL)
                      - min(min(min(bL, dL), min(eL, fL)), hL);
    nz = saturate(abs(nz) / max(range, 1e-5));
    nz = -0.5 * nz + 1.0;

    const float3 mn4 = min(min(b, d), min(f, hh));
    const float3 mx4 = max(max(b, d), max(f, hh));
    const float2 peak = float2(1.0, -4.0);
    const float3 hitMin = mn4 / max(4.0 * mx4, float3(1e-5));
    // Divisor kept below zero, as in anvil_rcas: no NaN in saturated highlights.
    const float3 hitMax = (peak.x - mx4) / min(4.0 * mn4 + peak.y, float3(-1.0 / 1024.0));
    const float3 lobeRGB = max(-hitMin, hitMax);

    const float scale = exp2(-(1.0 - sharpness) * 2.0);
    float lobe = max(-kRcasLimit,
                     min(max(max(lobeRGB.r, lobeRGB.g), lobeRGB.b), 0.0)) * scale * nz;
    return (lobe * (b + d + hh + f) + e) / (4.0 * lobe + 1.0);
}

/// The frame counter over one pixel of a w x h frame, where anvil_finish draws it (its copy).
/// params: y = fps, z = overlay scale, w = corner (negative: no counter).
static inline float3 anvilCounterOver(float3 colour, int2 gid, int w, int h, float4 params)
{
    if (params.w < 0.0) return colour;
    const int value = clamp(int(params.y + 0.5), 0, 9999);
    const int oscale = max(int(params.z), 1);
    const int glyphW = 3 * oscale, glyphH = 5 * oscale, gap = oscale;
    const int digits = value >= 1000 ? 4 : (value >= 100 ? 3 : (value >= 10 ? 2 : 1));
    const int boxW = digits * glyphW + (digits - 1) * gap + 4 * oscale;
    const int boxH = glyphH + 4 * oscale;

    const int inset = 8 * oscale;
    // params.w: the corner, plus 4 while the Mac is hot (its plate red).
    const bool hot = int(params.w) >= 4;
    const int corner = clamp(int(params.w) & 3, 0, 3);
    const int originX = (corner == 1 || corner == 3) ? (w - boxW - inset) : inset;
    const int originY = (corner >= 2) ? (h - boxH - inset) : inset;

    const int lx = gid.x - originX, ly = gid.y - originY;
    if (lx >= 0 && ly >= 0 && lx < boxW && ly < boxH) {
        colour *= 0.35;
        if (hot) colour = mix(colour, float3(0.75, 0.08, 0.05), 0.6);
        const int textX = lx - 2 * oscale, textY = ly - 2 * oscale;
        const int cell = glyphW + gap;
        const int index = textX / cell;
        if (index >= 0 && index < digits && (textX % cell) < glyphW) {
            int divisor = 1;
            for (int i = 0; i < digits - index - 1; ++i) divisor *= 10;
            const uint digit = uint((value / divisor) % 10);
            if (glyphPixel(digit, (textX % cell) / oscale, textY / oscale)) {
                colour = value >= 60 ? float3(0.45, 1.0, 0.45) : float3(1.0, 0.75, 0.3);
            }
        }
    }
    return colour;
}

kernel void anvil_finish(texture2d<float, access::read>  src   [[texture(0)]],
                         texture2d<float, access::write> dst   [[texture(1)]],
                         constant float4&                params[[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]])
{
    const int w = int(src.get_width()), h = int(src.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) return;

    const int2 sp = int2(gid);
    const int2 lim = int2(w - 1, h - 1);

    // Held to 0–1, where RCAS's limits are worked out: a 16-bit float frame can carry a
    // value above 1 that the display clips anyway. A no-op for every other format.
    const float3 b  = saturate(src.read(uint2(clamp(sp + int2( 0, -1), int2(0), lim))).rgb);
    const float3 d  = saturate(src.read(uint2(clamp(sp + int2(-1,  0), int2(0), lim))).rgb);
    const float3 e  = saturate(src.read(uint2(clamp(sp,                int2(0), lim))).rgb);
    const float3 f  = saturate(src.read(uint2(clamp(sp + int2( 1,  0), int2(0), lim))).rgb);
    const float3 hh = saturate(src.read(uint2(clamp(sp + int2( 0,  1), int2(0), lim))).rgb);

    float3 colour = e;

    const float sharpness = clamp(params.x, 0.0, 1.0);
    if (sharpness > 0.001) {
        // AMD's RCAS, as ported in anvil_rcas.
        const float bL = b.b  * 0.5 + (b.r  * 0.5 + b.g);
        const float dL = d.b  * 0.5 + (d.r  * 0.5 + d.g);
        const float eL = e.b  * 0.5 + (e.r  * 0.5 + e.g);
        const float fL = f.b  * 0.5 + (f.r  * 0.5 + f.g);
        const float hL = hh.b * 0.5 + (hh.r * 0.5 + hh.g);

        float nz = 0.25 * (bL + dL + fL + hL) - eL;
        const float range = max(max(max(bL, dL), max(eL, fL)), hL)
                          - min(min(min(bL, dL), min(eL, fL)), hL);
        nz = saturate(abs(nz) / max(range, 1e-5));
        nz = -0.5 * nz + 1.0;

        const float3 mn4 = min(min(b, d), min(f, hh));
        const float3 mx4 = max(max(b, d), max(f, hh));
        const float2 peak = float2(1.0, -4.0);
        const float3 hitMin = mn4 / max(4.0 * mx4, float3(1e-5));
        // Divisor kept below zero, as in anvil_rcas: no NaN in saturated highlights.
        const float3 hitMax = (peak.x - mx4) / min(4.0 * mn4 + peak.y, float3(-1.0 / 1024.0));
        const float3 lobeRGB = max(-hitMin, hitMax);

        const float scale = exp2(-(1.0 - sharpness) * 2.0);
        float lobe = max(-kRcasLimit,
                         min(max(max(lobeRGB.r, lobeRGB.g), lobeRGB.b), 0.0)) * scale * nz;
        colour = (lobe * (b + d + hh + f) + e) / (4.0 * lobe + 1.0);
    }

    // Overlay, drawn into the same pass rather than costing another blit.
    if (params.w >= 0.0) {
        const int value = clamp(int(params.y + 0.5), 0, 9999);
        const int oscale = max(int(params.z), 1);
        const int glyphW = 3 * oscale, glyphH = 5 * oscale, gap = oscale;
        const int digits = value >= 1000 ? 4 : (value >= 100 ? 3 : (value >= 10 ? 2 : 1));
        const int boxW = digits * glyphW + (digits - 1) * gap + 4 * oscale;
        const int boxH = glyphH + 4 * oscale;

        const int inset = 8 * oscale;
        const bool hot = int(params.w) >= 4;          // the corner, plus 4 while the Mac is hot
        const int corner = clamp(int(params.w) & 3, 0, 3);
        const int originX = (corner == 1 || corner == 3) ? (w - boxW - inset) : inset;
        const int originY = (corner >= 2) ? (h - boxH - inset) : inset;

        const int lx = int(gid.x) - originX, ly = int(gid.y) - originY;
        if (lx >= 0 && ly >= 0 && lx < boxW && ly < boxH) {
            colour *= 0.35;
            if (hot) colour = mix(colour, float3(0.75, 0.08, 0.05), 0.6);
            const int textX = lx - 2 * oscale, textY = ly - 2 * oscale;
            const int cell = glyphW + gap;
            const int index = textX / cell;
            if (index >= 0 && index < digits && (textX % cell) < glyphW) {
                int divisor = 1;
                for (int i = 0; i < digits - index - 1; ++i) divisor *= 10;
                const uint digit = uint((value / divisor) % 10);
                if (glyphPixel(digit, (textX % cell) / oscale, textY / oscale)) {
                    colour = value >= 60 ? float3(0.45, 1.0, 0.45) : float3(1.0, 0.75, 0.3);
                }
            }
        }
    }

    dst.write(float4(colour, 1.0), gid);
}

// =============================================================================
// The frame counter on its own.
//
// Drawing the counter used to mean copying the whole frame out and writing every
// pixel of it back — 1.3 ms at 3024x1964, with every pixel of the game's image
// passing through Anvil to change a few hundred. This reads and writes only the
// counter's box: src is the frame under the box, copied out at the box's size, and
// the box is placed exactly where anvil_finish puts it.
//
// params: y = fps, z = scale.  box: xy = where the box starts, zw = its size.
// =============================================================================

kernel void anvil_counter(texture2d<float, access::read>  src    [[texture(0)]],
                          texture2d<float, access::write> dst    [[texture(1)]],
                          constant float4&                params [[buffer(0)]],
                          constant uint4&                 box    [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= box.z || gid.y >= box.w) return;

    const int value = clamp(int(params.y + 0.5), 0, 9999);
    const int oscale = max(int(params.z), 1);
    const int glyphW = 3 * oscale, gap = oscale;
    const int digits = value >= 1000 ? 4 : (value >= 100 ? 3 : (value >= 10 ? 2 : 1));

    // Dim plate behind the digits so they stay readable over a bright scene; red while the Mac is hot (params.w).
    float3 colour = src.read(gid).rgb * 0.35;
    if (params.w > 0.5) colour = mix(colour, float3(0.75, 0.08, 0.05), 0.6);

    const int textX = int(gid.x) - 2 * oscale, textY = int(gid.y) - 2 * oscale;
    const int cell = glyphW + gap;
    if (textX >= 0 && textY >= 0) {
        const int index = textX / cell;
        if (index < digits && (textX % cell) < glyphW) {
            int divisor = 1;
            for (int i = 0; i < digits - index - 1; ++i) divisor *= 10;
            const uint digit = uint((value / divisor) % 10);
            if (glyphPixel(digit, (textX % cell) / oscale, textY / oscale)) {
                colour = value >= 60 ? float3(0.45, 1.0, 0.45) : float3(1.0, 0.75, 0.3);
            }
        }
    }
    dst.write(float4(colour, 1.0), gid + box.xy);
}

// =============================================================================
// Flow field -> MetalFX motion texture.
//
// Apple's frame interpolator takes a full-resolution motion texture. Anvil's flow
// field is a coarse grid of block offsets, so this expands it, and writes vectors
// in the convention MetalFX expects: the offset from a pixel's position now to
// where it was in the previous frame, in pixels, with motionVectorScale set to 1.
// =============================================================================

kernel void anvil_flow_to_motion(texture2d<float, access::sample> flow  [[texture(0)]],
                                 texture2d<float, access::write>  motion[[texture(1)]],
                                 uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= motion.get_width() || gid.y >= motion.get_height()) return;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);

    const float2 uv = (float2(gid) + 0.5) /
                      float2(motion.get_width(), motion.get_height());
    const float4 f = flow.sample(s, uv);

    // Sampling the coarse field bilinearly is what keeps motion from stepping in
    // blocks across an edge. Confidence scales the vector rather than gating it, so
    // an unreliable match degrades toward no motion instead of a wrong one.
    motion.write(float4(f.xy * f.z, 0.0, 0.0), gid);
}

// =============================================================================
// Downsample / upsample for the interpolation path.
//
// MetalFX's interpolator costs 12.1 ms at 3024x1964 and 3.7 ms at 1512x982 — an
// 82fps ceiling against a 270fps one, for a frame that is on screen for about
// eight milliseconds. Interpolating at half resolution and scaling the result back
// is overwhelmingly the better trade: the generated frame is slightly softer, and
// it exists at all.
// =============================================================================

kernel void anvil_downsample(texture2d<float, access::sample> src [[texture(0)]],
                             texture2d<float, access::write>  dst [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    const float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    // Four bilinear taps at quarter-texel offsets: a box filter over the source
    // footprint for the cost of four samples, which keeps the downscale from
    // aliasing into the motion estimate.
    const float2 texel = 0.25 / float2(dst.get_width(), dst.get_height());
    float3 c = src.sample(s, uv + float2(-texel.x, -texel.y)).rgb
             + src.sample(s, uv + float2( texel.x, -texel.y)).rgb
             + src.sample(s, uv + float2(-texel.x,  texel.y)).rgb
             + src.sample(s, uv + float2( texel.x,  texel.y)).rgb;
    dst.write(float4(c * 0.25, 1.0), gid);
}

kernel void anvil_upsample(texture2d<float, access::sample> src [[texture(0)]],
                           texture2d<float, access::write>  dst [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    const float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    dst.write(float4(src.sample(s, uv).rgb, 1.0), gid);
}

// =============================================================================
// FSR 1 EASU — AMD's edge-adaptive spatial upsampling, as AMD wrote it.
//
// A port of FsrEasuCon/FsrEasuSetF/FsrEasuTapF/FsrEasuF from the FidelityFX SDK v1.1.4
// (sdk/include/FidelityFX/gpu/fsr1/ffx_fsr1.h, MIT, Copyright (C) 2024 Advanced Micro
// Devices, Inc. — see THIRD-PARTY.md), in 32-bit float, with Metal's gather standing in
// for the SDK's FsrEasuR/G/B. anvil_easu above is an earlier approximation and stays only
// for a precompiled library built before this one.
//
// Used by Anvil's output (anvil_inject.mm): whatever size the game draws at, the picture
// on the display is this, followed by RCAS — rather than the compositor's bilinear stretch.
// =============================================================================

static inline void fsrEasuSet(thread float2& dir, thread float& len, float2 pp,
                              bool biS, bool biT, bool biU, bool biV,
                              float lA, float lB, float lC, float lD, float lE)
{
    float w = 0.0;
    if (biS) w = (1.0 - pp.x) * (1.0 - pp.y);
    if (biT) w =        pp.x  * (1.0 - pp.y);
    if (biU) w = (1.0 - pp.x) *        pp.y;
    if (biV) w =        pp.x  *        pp.y;
    const float dc = lD - lC;
    const float cb = lC - lB;
    float lenX = max(abs(dc), abs(cb));
    lenX = 1.0 / max(lenX, 1e-8);
    const float dirX = lD - lB;
    dir.x += dirX * w;
    lenX = saturate(abs(dirX) * lenX);
    lenX *= lenX;
    len += lenX * w;
    const float ec = lE - lC;
    const float ca = lC - lA;
    float lenY = max(abs(ec), abs(ca));
    lenY = 1.0 / max(lenY, 1e-8);
    const float dirY = lE - lA;
    dir.y += dirY * w;
    lenY = saturate(abs(dirY) * lenY);
    lenY *= lenY;
    len += lenY * w;
}

static inline void fsrEasuTap(thread float3& aC, thread float& aW, float2 off, float2 dir,
                              float2 len, float lob, float clp, float3 c)
{
    float2 v;
    v.x = (off.x * ( dir.x)) + (off.y * dir.y);
    v.y = (off.x * (-dir.y)) + (off.y * dir.x);
    v *= len;
    float d2 = v.x * v.x + v.y * v.y;
    d2 = min(d2, clp);
    float wB = (2.0 / 5.0) * d2 - 1.0;
    float wA = lob * d2 - 1.0;
    wB *= wB;
    wA *= wA;
    wB = (25.0 / 16.0) * wB - (25.0 / 16.0 - 1.0);
    const float w = wB * wA;
    aC += c * w;
    aW += w;
}

kernel void anvil_fsr_easu_f32(texture2d<float, access::sample> src [[texture(0)]],
                           texture2d<float, access::write>  dst [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(coord::normalized, filter::nearest, address::clamp_to_edge);

    const float2 inSize  = float2(src.get_width(), src.get_height());
    const float2 outSize = float2(dst.get_width(), dst.get_height());
    const float2 rcpIn   = 1.0 / inSize;
    // FsrEasuCon: output pixel to input pixel, and the gather centres.
    const float2 con0xy = inSize / outSize;
    const float2 con0zw = 0.5 * inSize / outSize - 0.5;

    float2 pp = float2(gid) * con0xy + con0zw;
    const float2 fp = floor(pp);
    pp -= fp;

    const float2 p0 = fp * rcpIn + float2( 1.0, -1.0) * rcpIn;
    const float2 p1 = p0 + float2(-1.0,  2.0) * rcpIn;
    const float2 p2 = p0 + float2( 1.0,  2.0) * rcpIn;
    const float2 p3 = p0 + float2( 0.0,  4.0) * rcpIn;

    const float4 bczzR = src.gather(s, p0, int2(0), component::x);
    const float4 bczzG = src.gather(s, p0, int2(0), component::y);
    const float4 bczzB = src.gather(s, p0, int2(0), component::z);
    const float4 ijfeR = src.gather(s, p1, int2(0), component::x);
    const float4 ijfeG = src.gather(s, p1, int2(0), component::y);
    const float4 ijfeB = src.gather(s, p1, int2(0), component::z);
    const float4 klhgR = src.gather(s, p2, int2(0), component::x);
    const float4 klhgG = src.gather(s, p2, int2(0), component::y);
    const float4 klhgB = src.gather(s, p2, int2(0), component::z);
    const float4 zzonR = src.gather(s, p3, int2(0), component::x);
    const float4 zzonG = src.gather(s, p3, int2(0), component::y);
    const float4 zzonB = src.gather(s, p3, int2(0), component::z);

    const float4 bczzL = bczzB * 0.5 + (bczzR * 0.5 + bczzG);
    const float4 ijfeL = ijfeB * 0.5 + (ijfeR * 0.5 + ijfeG);
    const float4 klhgL = klhgB * 0.5 + (klhgR * 0.5 + klhgG);
    const float4 zzonL = zzonB * 0.5 + (zzonR * 0.5 + zzonG);
    const float bL = bczzL.x, cL = bczzL.y;
    const float iL = ijfeL.x, jL = ijfeL.y, fL = ijfeL.z, eL = ijfeL.w;
    const float kL = klhgL.x, lL = klhgL.y, hL = klhgL.z, gL = klhgL.w;
    const float oL = zzonL.z, nL = zzonL.w;

    float2 dir = float2(0.0);
    float len = 0.0;
    fsrEasuSet(dir, len, pp, true,  false, false, false, bL, eL, fL, gL, jL);
    fsrEasuSet(dir, len, pp, false, true,  false, false, cL, fL, gL, hL, kL);
    fsrEasuSet(dir, len, pp, false, false, true,  false, fL, iL, jL, kL, nL);
    fsrEasuSet(dir, len, pp, false, false, false, true,  gL, jL, kL, lL, oL);

    const float2 dir2 = dir * dir;
    float dirR = dir2.x + dir2.y;
    const bool zro = dirR < (1.0 / 32768.0);
    dirR = rsqrt(max(dirR, 1e-12));
    dirR = zro ? 1.0 : dirR;
    dir.x = zro ? 1.0 : dir.x;
    dir *= dirR;
    len = len * 0.5;
    len *= len;
    const float stretch = (dir.x * dir.x + dir.y * dir.y) / max(max(abs(dir.x), abs(dir.y)), 1e-8);
    const float2 len2 = float2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
    const float lob = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len;
    const float clp = 1.0 / lob;

    const float3 min4 = min(min(float3(ijfeR.z, ijfeG.z, ijfeB.z), float3(klhgR.w, klhgG.w, klhgB.w)),
                            min(float3(ijfeR.y, ijfeG.y, ijfeB.y), float3(klhgR.x, klhgG.x, klhgB.x)));
    const float3 max4 = max(max(float3(ijfeR.z, ijfeG.z, ijfeB.z), float3(klhgR.w, klhgG.w, klhgB.w)),
                            max(float3(ijfeR.y, ijfeG.y, ijfeB.y), float3(klhgR.x, klhgG.x, klhgB.x)));

    float3 aC = float3(0.0);
    float aW = 0.0;
    fsrEasuTap(aC, aW, float2( 0.0, -1.0) - pp, dir, len2, lob, clp, float3(bczzR.x, bczzG.x, bczzB.x)); // b
    fsrEasuTap(aC, aW, float2( 1.0, -1.0) - pp, dir, len2, lob, clp, float3(bczzR.y, bczzG.y, bczzB.y)); // c
    fsrEasuTap(aC, aW, float2(-1.0,  1.0) - pp, dir, len2, lob, clp, float3(ijfeR.x, ijfeG.x, ijfeB.x)); // i
    fsrEasuTap(aC, aW, float2( 0.0,  1.0) - pp, dir, len2, lob, clp, float3(ijfeR.y, ijfeG.y, ijfeB.y)); // j
    fsrEasuTap(aC, aW, float2( 0.0,  0.0) - pp, dir, len2, lob, clp, float3(ijfeR.z, ijfeG.z, ijfeB.z)); // f
    fsrEasuTap(aC, aW, float2(-1.0,  0.0) - pp, dir, len2, lob, clp, float3(ijfeR.w, ijfeG.w, ijfeB.w)); // e
    fsrEasuTap(aC, aW, float2( 1.0,  1.0) - pp, dir, len2, lob, clp, float3(klhgR.x, klhgG.x, klhgB.x)); // k
    fsrEasuTap(aC, aW, float2( 2.0,  1.0) - pp, dir, len2, lob, clp, float3(klhgR.y, klhgG.y, klhgB.y)); // l
    fsrEasuTap(aC, aW, float2( 2.0,  0.0) - pp, dir, len2, lob, clp, float3(klhgR.z, klhgG.z, klhgB.z)); // h
    fsrEasuTap(aC, aW, float2( 1.0,  0.0) - pp, dir, len2, lob, clp, float3(klhgR.w, klhgG.w, klhgB.w)); // g
    fsrEasuTap(aC, aW, float2( 1.0,  2.0) - pp, dir, len2, lob, clp, float3(zzonR.z, zzonG.z, zzonB.z)); // o
    fsrEasuTap(aC, aW, float2( 0.0,  2.0) - pp, dir, len2, lob, clp, float3(zzonR.w, zzonG.w, zzonB.w)); // n

    const float3 pix = min(max4, max(min4, aC / max(aW, 1e-8)));
    dst.write(float4(pix, 1.0), gid);
}

// The same in 16-bit floats, which Apple GPUs run at twice the rate — AMD ships FSR 1 in
// both too (FsrEasuH). Positions stay 32-bit; colours, luma, weights and accumulation are
// half. The bench (fsr_bench) checks it against anvil_fsr_easu_f32 and times both.
static inline void fsrEasuSetH(thread half2& dir, thread half& len, half2 pp,
                               bool biS, bool biT, bool biU, bool biV,
                               half lA, half lB, half lC, half lD, half lE)
{
    half w = 0.0h;
    if (biS) w = (1.0h - pp.x) * (1.0h - pp.y);
    if (biT) w =         pp.x  * (1.0h - pp.y);
    if (biU) w = (1.0h - pp.x) *         pp.y;
    if (biV) w =         pp.x  *         pp.y;
    const half dc = lD - lC, cb = lC - lB;
    half lenX = max(abs(dc), abs(cb));
    lenX = 1.0h / max(lenX, 0.0001h);
    const half dirX = lD - lB;
    dir.x += dirX * w;
    lenX = saturate(abs(dirX) * lenX);
    lenX *= lenX;
    len += lenX * w;
    const half ec = lE - lC, ca = lC - lA;
    half lenY = max(abs(ec), abs(ca));
    lenY = 1.0h / max(lenY, 0.0001h);
    const half dirY = lE - lA;
    dir.y += dirY * w;
    lenY = saturate(abs(dirY) * lenY);
    lenY *= lenY;
    len += lenY * w;
}

static inline void fsrEasuTapH(thread half3& aC, thread half& aW, half2 off, half2 dir,
                               half2 len, half lob, half clp, half3 c)
{
    half2 v;
    v.x = (off.x * ( dir.x)) + (off.y * dir.y);
    v.y = (off.x * (-dir.y)) + (off.y * dir.x);
    v *= len;
    half d2 = min(v.x * v.x + v.y * v.y, clp);
    half wB = (2.0h / 5.0h) * d2 - 1.0h;
    half wA = lob * d2 - 1.0h;
    wB *= wB;
    wA *= wA;
    wB = (25.0h / 16.0h) * wB - (25.0h / 16.0h - 1.0h);
    const half w = wB * wA;
    aC += c * w;
    aW += w;
}

/// FSR 1's EASU for one output pixel, in 16-bit colour: anvil_fsr_easu's arithmetic, for
/// anvil_fsr_fused (anvil_fsr_easu keeps its own, as anvil_finish does — see fsrRcas).
static inline half3 fsrEasuAt(texture2d<half, access::sample> src, uint2 gid,
                              float2 inSize, float2 outSize)
{
    constexpr sampler s(coord::normalized, filter::nearest, address::clamp_to_edge);
    const float2 rcpIn   = 1.0 / inSize;
    float2 ppf = float2(gid) * (inSize / outSize) + (0.5 * inSize / outSize - 0.5);
    const float2 fp = floor(ppf);
    const half2 pp = half2(ppf - fp);

    const float2 p0 = fp * rcpIn + float2( 1.0, -1.0) * rcpIn;
    const float2 p1 = p0 + float2(-1.0,  2.0) * rcpIn;
    const float2 p2 = p0 + float2( 1.0,  2.0) * rcpIn;
    const float2 p3 = p0 + float2( 0.0,  4.0) * rcpIn;

    const half4 bczzR = src.gather(s, p0, int2(0), component::x);
    const half4 bczzG = src.gather(s, p0, int2(0), component::y);
    const half4 bczzB = src.gather(s, p0, int2(0), component::z);
    const half4 ijfeR = src.gather(s, p1, int2(0), component::x);
    const half4 ijfeG = src.gather(s, p1, int2(0), component::y);
    const half4 ijfeB = src.gather(s, p1, int2(0), component::z);
    const half4 klhgR = src.gather(s, p2, int2(0), component::x);
    const half4 klhgG = src.gather(s, p2, int2(0), component::y);
    const half4 klhgB = src.gather(s, p2, int2(0), component::z);
    const half4 zzonR = src.gather(s, p3, int2(0), component::x);
    const half4 zzonG = src.gather(s, p3, int2(0), component::y);
    const half4 zzonB = src.gather(s, p3, int2(0), component::z);

    const half4 bczzL = bczzB * 0.5h + (bczzR * 0.5h + bczzG);
    const half4 ijfeL = ijfeB * 0.5h + (ijfeR * 0.5h + ijfeG);
    const half4 klhgL = klhgB * 0.5h + (klhgR * 0.5h + klhgG);
    const half4 zzonL = zzonB * 0.5h + (zzonR * 0.5h + zzonG);
    const half bL = bczzL.x, cL = bczzL.y;
    const half iL = ijfeL.x, jL = ijfeL.y, fL = ijfeL.z, eL = ijfeL.w;
    const half kL = klhgL.x, lL = klhgL.y, hL = klhgL.z, gL = klhgL.w;
    const half oL = zzonL.z, nL = zzonL.w;

    half2 dir = half2(0.0h);
    half len = 0.0h;
    fsrEasuSetH(dir, len, pp, true,  false, false, false, bL, eL, fL, gL, jL);
    fsrEasuSetH(dir, len, pp, false, true,  false, false, cL, fL, gL, hL, kL);
    fsrEasuSetH(dir, len, pp, false, false, true,  false, fL, iL, jL, kL, nL);
    fsrEasuSetH(dir, len, pp, false, false, false, true,  gL, jL, kL, lL, oL);

    // Normalised in 32 bits: the length can be far below what half holds.
    float2 dirF = float2(dir);
    const float dirR2 = dot(dirF, dirF);
    const bool zro = dirR2 < (1.0 / 32768.0);
    dirF = zro ? float2(1.0, 0.0) : dirF * rsqrt(max(dirR2, 1e-12));
    const half2 dirN = half2(dirF);
    half lenS = len * 0.5h;
    lenS *= lenS;
    const half stretch = (dirN.x * dirN.x + dirN.y * dirN.y) / max(max(abs(dirN.x), abs(dirN.y)), 0.0001h);
    const half2 len2 = half2(1.0h + (stretch - 1.0h) * lenS, 1.0h - 0.5h * lenS);
    const half lob = 0.5h + ((1.0h / 4.0h - 0.04h) - 0.5h) * lenS;
    const half clp = 1.0h / lob;

    const half3 min4 = min(min(half3(ijfeR.z, ijfeG.z, ijfeB.z), half3(klhgR.w, klhgG.w, klhgB.w)),
                           min(half3(ijfeR.y, ijfeG.y, ijfeB.y), half3(klhgR.x, klhgG.x, klhgB.x)));
    const half3 max4 = max(max(half3(ijfeR.z, ijfeG.z, ijfeB.z), half3(klhgR.w, klhgG.w, klhgB.w)),
                           max(half3(ijfeR.y, ijfeG.y, ijfeB.y), half3(klhgR.x, klhgG.x, klhgB.x)));

    half3 aC = half3(0.0h);
    half aW = 0.0h;
    fsrEasuTapH(aC, aW, half2( 0.0h, -1.0h) - pp, dirN, len2, lob, clp, half3(bczzR.x, bczzG.x, bczzB.x)); // b
    fsrEasuTapH(aC, aW, half2( 1.0h, -1.0h) - pp, dirN, len2, lob, clp, half3(bczzR.y, bczzG.y, bczzB.y)); // c
    fsrEasuTapH(aC, aW, half2(-1.0h,  1.0h) - pp, dirN, len2, lob, clp, half3(ijfeR.x, ijfeG.x, ijfeB.x)); // i
    fsrEasuTapH(aC, aW, half2( 0.0h,  1.0h) - pp, dirN, len2, lob, clp, half3(ijfeR.y, ijfeG.y, ijfeB.y)); // j
    fsrEasuTapH(aC, aW, half2( 0.0h,  0.0h) - pp, dirN, len2, lob, clp, half3(ijfeR.z, ijfeG.z, ijfeB.z)); // f
    fsrEasuTapH(aC, aW, half2(-1.0h,  0.0h) - pp, dirN, len2, lob, clp, half3(ijfeR.w, ijfeG.w, ijfeB.w)); // e
    fsrEasuTapH(aC, aW, half2( 1.0h,  1.0h) - pp, dirN, len2, lob, clp, half3(klhgR.x, klhgG.x, klhgB.x)); // k
    fsrEasuTapH(aC, aW, half2( 2.0h,  1.0h) - pp, dirN, len2, lob, clp, half3(klhgR.y, klhgG.y, klhgB.y)); // l
    fsrEasuTapH(aC, aW, half2( 2.0h,  0.0h) - pp, dirN, len2, lob, clp, half3(klhgR.z, klhgG.z, klhgB.z)); // h
    fsrEasuTapH(aC, aW, half2( 1.0h,  0.0h) - pp, dirN, len2, lob, clp, half3(klhgR.w, klhgG.w, klhgB.w)); // g
    fsrEasuTapH(aC, aW, half2( 1.0h,  2.0h) - pp, dirN, len2, lob, clp, half3(zzonR.z, zzonG.z, zzonB.z)); // o
    fsrEasuTapH(aC, aW, half2( 0.0h,  2.0h) - pp, dirN, len2, lob, clp, half3(zzonR.w, zzonG.w, zzonB.w)); // n

    // A weight sum near zero (a tap set all at the window's edge) falls back to the nearest
    // pixel rather than dividing by it.
    half3 pix = aW > 0.0001h ? aC / aW : half3(ijfeR.z, ijfeG.z, ijfeB.z);
    return min(max4, max(min4, pix));
}

/// fsrEasuAt for the four display pixels of a 2x2 at exactly twice the game's size (0.55). There, each 2x2 whose
/// first pixel is odd comes from the same 4x4 of the game's pixels — `fp`, its texel the taps start from — at
/// fractions of 0.25 and 0.75 each way: the twelve texels are gathered, their luma and each tap set's edge worked
/// out once for the four, not four times. Each pixel's own part is fsrEasuAt's, step for step, in the order
/// (0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75).
static inline void fsrEasuQuad(texture2d<half, access::sample> src, float2 fp, float2 inSize, thread half3* out)
{
    constexpr sampler s(coord::normalized, filter::nearest, address::clamp_to_edge);
    const float2 rcpIn   = 1.0 / inSize;
    const float2 p0 = fp * rcpIn + float2( 1.0, -1.0) * rcpIn;
    const float2 p1 = p0 + float2(-1.0,  2.0) * rcpIn;
    const float2 p2 = p0 + float2( 1.0,  2.0) * rcpIn;
    const float2 p3 = p0 + float2( 0.0,  4.0) * rcpIn;

    const half4 bczzR = src.gather(s, p0, int2(0), component::x);
    const half4 bczzG = src.gather(s, p0, int2(0), component::y);
    const half4 bczzB = src.gather(s, p0, int2(0), component::z);
    const half4 ijfeR = src.gather(s, p1, int2(0), component::x);
    const half4 ijfeG = src.gather(s, p1, int2(0), component::y);
    const half4 ijfeB = src.gather(s, p1, int2(0), component::z);
    const half4 klhgR = src.gather(s, p2, int2(0), component::x);
    const half4 klhgG = src.gather(s, p2, int2(0), component::y);
    const half4 klhgB = src.gather(s, p2, int2(0), component::z);
    const half4 zzonR = src.gather(s, p3, int2(0), component::x);
    const half4 zzonG = src.gather(s, p3, int2(0), component::y);
    const half4 zzonB = src.gather(s, p3, int2(0), component::z);

    const half4 bczzL = bczzB * 0.5h + (bczzR * 0.5h + bczzG);
    const half4 ijfeL = ijfeB * 0.5h + (ijfeR * 0.5h + ijfeG);
    const half4 klhgL = klhgB * 0.5h + (klhgR * 0.5h + klhgG);
    const half4 zzonL = zzonB * 0.5h + (zzonR * 0.5h + zzonG);
    const half bL = bczzL.x, cL = bczzL.y;
    const half iL = ijfeL.x, jL = ijfeL.y, fL = ijfeL.z, eL = ijfeL.w;
    const half kL = klhgL.x, lL = klhgL.y, hL = klhgL.z, gL = klhgL.w;
    const half oL = zzonL.z, nL = zzonL.w;

    const half3 min4 = min(min(half3(ijfeR.z, ijfeG.z, ijfeB.z), half3(klhgR.w, klhgG.w, klhgB.w)),
                           min(half3(ijfeR.y, ijfeG.y, ijfeB.y), half3(klhgR.x, klhgG.x, klhgB.x)));
    const half3 max4 = max(max(half3(ijfeR.z, ijfeG.z, ijfeB.z), half3(klhgR.w, klhgG.w, klhgB.w)),
                           max(half3(ijfeR.y, ijfeG.y, ijfeB.y), half3(klhgR.x, klhgG.x, klhgB.x)));

    for (int q = 0; q < 4; ++q) {
        const half2 pp = half2((q & 1) ? 0.75h : 0.25h, (q & 2) ? 0.75h : 0.25h);
        half2 dir = half2(0.0h);
        half len = 0.0h;
        fsrEasuSetH(dir, len, pp, true,  false, false, false, bL, eL, fL, gL, jL);
        fsrEasuSetH(dir, len, pp, false, true,  false, false, cL, fL, gL, hL, kL);
        fsrEasuSetH(dir, len, pp, false, false, true,  false, fL, iL, jL, kL, nL);
        fsrEasuSetH(dir, len, pp, false, false, false, true,  gL, jL, kL, lL, oL);

        float2 dirF = float2(dir);
        const float dirR2 = dot(dirF, dirF);
        const bool zro = dirR2 < (1.0 / 32768.0);
        dirF = zro ? float2(1.0, 0.0) : dirF * rsqrt(max(dirR2, 1e-12));
        const half2 dirN = half2(dirF);
        half lenS = len * 0.5h;
        lenS *= lenS;
        const half stretch = (dirN.x * dirN.x + dirN.y * dirN.y) / max(max(abs(dirN.x), abs(dirN.y)), 0.0001h);
        const half2 len2 = half2(1.0h + (stretch - 1.0h) * lenS, 1.0h - 0.5h * lenS);
        const half lob = 0.5h + ((1.0h / 4.0h - 0.04h) - 0.5h) * lenS;
        const half clp = 1.0h / lob;

        half3 aC = half3(0.0h);
        half aW = 0.0h;
        fsrEasuTapH(aC, aW, half2( 0.0h, -1.0h) - pp, dirN, len2, lob, clp, half3(bczzR.x, bczzG.x, bczzB.x)); // b
        fsrEasuTapH(aC, aW, half2( 1.0h, -1.0h) - pp, dirN, len2, lob, clp, half3(bczzR.y, bczzG.y, bczzB.y)); // c
        fsrEasuTapH(aC, aW, half2(-1.0h,  1.0h) - pp, dirN, len2, lob, clp, half3(ijfeR.x, ijfeG.x, ijfeB.x)); // i
        fsrEasuTapH(aC, aW, half2( 0.0h,  1.0h) - pp, dirN, len2, lob, clp, half3(ijfeR.y, ijfeG.y, ijfeB.y)); // j
        fsrEasuTapH(aC, aW, half2( 0.0h,  0.0h) - pp, dirN, len2, lob, clp, half3(ijfeR.z, ijfeG.z, ijfeB.z)); // f
        fsrEasuTapH(aC, aW, half2(-1.0h,  0.0h) - pp, dirN, len2, lob, clp, half3(ijfeR.w, ijfeG.w, ijfeB.w)); // e
        fsrEasuTapH(aC, aW, half2( 1.0h,  1.0h) - pp, dirN, len2, lob, clp, half3(klhgR.x, klhgG.x, klhgB.x)); // k
        fsrEasuTapH(aC, aW, half2( 2.0h,  1.0h) - pp, dirN, len2, lob, clp, half3(klhgR.y, klhgG.y, klhgB.y)); // l
        fsrEasuTapH(aC, aW, half2( 2.0h,  0.0h) - pp, dirN, len2, lob, clp, half3(klhgR.z, klhgG.z, klhgB.z)); // h
        fsrEasuTapH(aC, aW, half2( 1.0h,  0.0h) - pp, dirN, len2, lob, clp, half3(klhgR.w, klhgG.w, klhgB.w)); // g
        fsrEasuTapH(aC, aW, half2( 1.0h,  2.0h) - pp, dirN, len2, lob, clp, half3(zzonR.z, zzonG.z, zzonB.z)); // o
        fsrEasuTapH(aC, aW, half2( 0.0h,  2.0h) - pp, dirN, len2, lob, clp, half3(zzonR.w, zzonG.w, zzonB.w)); // n

        const half3 pix = aW > 0.0001h ? aC / aW : half3(ijfeR.z, ijfeG.z, ijfeB.z);
        out[q] = min(max4, max(min4, pix));
    }
}

/// A fused pass's tile of EASU (its shape and a pixel of border) at exactly twice the game's size, a 2x2 at a time
/// (fsrEasuQuad), each value what the one-pixel-at-a-time fill makes there: off the frame's edge the nearest pixel's,
/// put through `tidy`. Needs an even shape, so that the tile starts on an odd display pixel and every 2x2 of it is one
/// of fsrEasuQuad's — clamped to the frame, both pixels of a 2x2 each way still fall in the same one.
static inline half4 fsrTileTidy(half3 v, bool zeroNaN) {
    const half3 s = saturate(v);
    // fsr3Finite's test (below), from the bits: fast maths can't drop it.
    const bool finite = all((as_type<uint3>(float3(s)) & 0x7f800000u) != 0x7f800000u);
    return half4((zeroNaN && !finite) ? half3(0.0h) : s, 0.0h);
}

static inline void fsrEasuTileTwice(texture2d<half, access::sample> src, threadgroup half4* tile, int2 origin, int tw, int th,
                                    int2 lim, int index, int threads, float2 inSize, bool zeroNaN)
{
    const int qw = tw / 2, qh = th / 2;
    for (int i = index; i < qw * qh; i += threads) {
        const int2 t = int2(i % qw, i / qw) * 2;
        const int2 c0 = clamp(origin + t, int2(0), lim), c1 = clamp(origin + t + 1, int2(0), lim);
        // The 2x2 they're in: its first pixel 2k - 1 each way, from the game's texel k - 1.
        const int2 quad = ((c0 + 1) >> 1) * 2 - 1;
        half3 v[4];
        fsrEasuQuad(src, float2(((quad + 1) >> 1) - 1), inSize, v);
        const bool x0 = c0.x != quad.x, x1 = c1.x != quad.x, y0 = c0.y != quad.y, y1 = c1.y != quad.y;
        const half3 top0 = x0 ? v[1] : v[0], top1 = x1 ? v[1] : v[0];
        const half3 bot0 = x0 ? v[3] : v[2], bot1 = x1 ? v[3] : v[2];
        const int at = t.y * tw + t.x;
        tile[at]          = fsrTileTidy(y0 ? bot0 : top0, zeroNaN);
        tile[at + 1]      = fsrTileTidy(y0 ? bot1 : top1, zeroNaN);
        tile[at + tw]     = fsrTileTidy(y1 ? bot0 : top0, zeroNaN);
        tile[at + tw + 1] = fsrTileTidy(y1 ? bot1 : top1, zeroNaN);
    }
}

kernel void anvil_fsr_easu(texture2d<half, access::sample> src [[texture(0)]],
                           texture2d<half, access::write>  dst [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(coord::normalized, filter::nearest, address::clamp_to_edge);

    const float2 inSize  = float2(src.get_width(), src.get_height());
    const float2 outSize = float2(dst.get_width(), dst.get_height());
    const float2 rcpIn   = 1.0 / inSize;
    float2 ppf = float2(gid) * (inSize / outSize) + (0.5 * inSize / outSize - 0.5);
    const float2 fp = floor(ppf);
    const half2 pp = half2(ppf - fp);

    const float2 p0 = fp * rcpIn + float2( 1.0, -1.0) * rcpIn;
    const float2 p1 = p0 + float2(-1.0,  2.0) * rcpIn;
    const float2 p2 = p0 + float2( 1.0,  2.0) * rcpIn;
    const float2 p3 = p0 + float2( 0.0,  4.0) * rcpIn;

    const half4 bczzR = src.gather(s, p0, int2(0), component::x);
    const half4 bczzG = src.gather(s, p0, int2(0), component::y);
    const half4 bczzB = src.gather(s, p0, int2(0), component::z);
    const half4 ijfeR = src.gather(s, p1, int2(0), component::x);
    const half4 ijfeG = src.gather(s, p1, int2(0), component::y);
    const half4 ijfeB = src.gather(s, p1, int2(0), component::z);
    const half4 klhgR = src.gather(s, p2, int2(0), component::x);
    const half4 klhgG = src.gather(s, p2, int2(0), component::y);
    const half4 klhgB = src.gather(s, p2, int2(0), component::z);
    const half4 zzonR = src.gather(s, p3, int2(0), component::x);
    const half4 zzonG = src.gather(s, p3, int2(0), component::y);
    const half4 zzonB = src.gather(s, p3, int2(0), component::z);

    const half4 bczzL = bczzB * 0.5h + (bczzR * 0.5h + bczzG);
    const half4 ijfeL = ijfeB * 0.5h + (ijfeR * 0.5h + ijfeG);
    const half4 klhgL = klhgB * 0.5h + (klhgR * 0.5h + klhgG);
    const half4 zzonL = zzonB * 0.5h + (zzonR * 0.5h + zzonG);
    const half bL = bczzL.x, cL = bczzL.y;
    const half iL = ijfeL.x, jL = ijfeL.y, fL = ijfeL.z, eL = ijfeL.w;
    const half kL = klhgL.x, lL = klhgL.y, hL = klhgL.z, gL = klhgL.w;
    const half oL = zzonL.z, nL = zzonL.w;

    half2 dir = half2(0.0h);
    half len = 0.0h;
    fsrEasuSetH(dir, len, pp, true,  false, false, false, bL, eL, fL, gL, jL);
    fsrEasuSetH(dir, len, pp, false, true,  false, false, cL, fL, gL, hL, kL);
    fsrEasuSetH(dir, len, pp, false, false, true,  false, fL, iL, jL, kL, nL);
    fsrEasuSetH(dir, len, pp, false, false, false, true,  gL, jL, kL, lL, oL);

    // Normalised in 32 bits: the length can be far below what half holds.
    float2 dirF = float2(dir);
    const float dirR2 = dot(dirF, dirF);
    const bool zro = dirR2 < (1.0 / 32768.0);
    dirF = zro ? float2(1.0, 0.0) : dirF * rsqrt(max(dirR2, 1e-12));
    const half2 dirN = half2(dirF);
    half lenS = len * 0.5h;
    lenS *= lenS;
    const half stretch = (dirN.x * dirN.x + dirN.y * dirN.y) / max(max(abs(dirN.x), abs(dirN.y)), 0.0001h);
    const half2 len2 = half2(1.0h + (stretch - 1.0h) * lenS, 1.0h - 0.5h * lenS);
    const half lob = 0.5h + ((1.0h / 4.0h - 0.04h) - 0.5h) * lenS;
    const half clp = 1.0h / lob;

    const half3 min4 = min(min(half3(ijfeR.z, ijfeG.z, ijfeB.z), half3(klhgR.w, klhgG.w, klhgB.w)),
                           min(half3(ijfeR.y, ijfeG.y, ijfeB.y), half3(klhgR.x, klhgG.x, klhgB.x)));
    const half3 max4 = max(max(half3(ijfeR.z, ijfeG.z, ijfeB.z), half3(klhgR.w, klhgG.w, klhgB.w)),
                           max(half3(ijfeR.y, ijfeG.y, ijfeB.y), half3(klhgR.x, klhgG.x, klhgB.x)));

    half3 aC = half3(0.0h);
    half aW = 0.0h;
    fsrEasuTapH(aC, aW, half2( 0.0h, -1.0h) - pp, dirN, len2, lob, clp, half3(bczzR.x, bczzG.x, bczzB.x)); // b
    fsrEasuTapH(aC, aW, half2( 1.0h, -1.0h) - pp, dirN, len2, lob, clp, half3(bczzR.y, bczzG.y, bczzB.y)); // c
    fsrEasuTapH(aC, aW, half2(-1.0h,  1.0h) - pp, dirN, len2, lob, clp, half3(ijfeR.x, ijfeG.x, ijfeB.x)); // i
    fsrEasuTapH(aC, aW, half2( 0.0h,  1.0h) - pp, dirN, len2, lob, clp, half3(ijfeR.y, ijfeG.y, ijfeB.y)); // j
    fsrEasuTapH(aC, aW, half2( 0.0h,  0.0h) - pp, dirN, len2, lob, clp, half3(ijfeR.z, ijfeG.z, ijfeB.z)); // f
    fsrEasuTapH(aC, aW, half2(-1.0h,  0.0h) - pp, dirN, len2, lob, clp, half3(ijfeR.w, ijfeG.w, ijfeB.w)); // e
    fsrEasuTapH(aC, aW, half2( 1.0h,  1.0h) - pp, dirN, len2, lob, clp, half3(klhgR.x, klhgG.x, klhgB.x)); // k
    fsrEasuTapH(aC, aW, half2( 2.0h,  1.0h) - pp, dirN, len2, lob, clp, half3(klhgR.y, klhgG.y, klhgB.y)); // l
    fsrEasuTapH(aC, aW, half2( 2.0h,  0.0h) - pp, dirN, len2, lob, clp, half3(klhgR.z, klhgG.z, klhgB.z)); // h
    fsrEasuTapH(aC, aW, half2( 1.0h,  0.0h) - pp, dirN, len2, lob, clp, half3(klhgR.w, klhgG.w, klhgB.w)); // g
    fsrEasuTapH(aC, aW, half2( 1.0h,  2.0h) - pp, dirN, len2, lob, clp, half3(zzonR.z, zzonG.z, zzonB.z)); // o
    fsrEasuTapH(aC, aW, half2( 0.0h,  2.0h) - pp, dirN, len2, lob, clp, half3(zzonR.w, zzonG.w, zzonB.w)); // n

    // A weight sum near zero (a tap set all at the window's edge) falls back to the nearest
    // pixel rather than dividing by it.
    half3 pix = aW > 0.0001h ? aC / aW : half3(ijfeR.z, ijfeG.z, ijfeB.z);
    pix = min(max4, max(min4, pix));
    dst.write(half4(pix, 1.0h), gid);
}

// =============================================================================
// FSR in one pass: EASU into threadgroup memory, then RCAS and the counter from it.
//
// The two-pass version writes the whole upscaled frame to a scratch texture and reads it
// back — at 3024x1934 that is 23 MB out and in again every frame. Here each threadgroup
// upscales its tile and a one-pixel border (RCAS reads a cross of five) into threadgroup
// memory and sharpens from there, so the upscaled frame never goes out to memory between
// the two. The border is extra EASU work, so which is quicker depends on the GPU, the sizes
// and the format — Graphics Prep times both on the Mac at the game's own and keeps the
// faster. On an M4 at 1512x982 to 3024x1934 (32x32 groups): 8-bit, 1.44 ms in two passes
// and 1.52 in this one; 16-bit float, whose scratch is twice the size, 1.90 and 1.57. With
// the tile filled a 2x2 at a time at twice the size (fsrEasuTileTwice, 0.55), 8-bit at LEGO's
// 3024x1964: 1.29 ms in this one against 1.46 in two, so it is the one kept there.
//
// The host gives threadgroup memory 0 room for (width + 2) x (height + 2) half4s and
// dispatches whole threadgroups, so every group has the full shape. The EASU result is
// kept as a 16-bit float rather than rounded to the drawable's format between the passes.
// =============================================================================
kernel void anvil_fsr_fused(texture2d<half, access::sample> src    [[texture(0)]],
                            texture2d<float, access::write> dst    [[texture(1)]],
                            constant float4&                params [[buffer(0)]],
                            threadgroup half4*              tile   [[threadgroup(0)]],
                            uint2 tid   [[thread_position_in_threadgroup]],
                            uint2 group [[threadgroup_position_in_grid]],
                            uint2 shape [[threads_per_threadgroup]],
                            uint  index [[thread_index_in_threadgroup]])
{
    const int w = int(dst.get_width()), h = int(dst.get_height());
    const float2 inSize  = float2(src.get_width(), src.get_height());
    const float2 outSize = float2(w, h);
    const int tw = int(shape.x) + 2, th = int(shape.y) + 2;
    const int2 origin = int2(group * shape) - 1;
    const int2 lim = int2(w - 1, h - 1);
    const int threads = int(shape.x * shape.y);
    // Off the frame's edge, the nearest pixel — what anvil_finish reads there.
    if (all(outSize == 2.0 * inSize) && (shape.x & 1) == 0 && (shape.y & 1) == 0) {
        fsrEasuTileTwice(src, tile, origin, tw, th, lim, int(index), threads, inSize, false);
    } else {
        for (int i = int(index); i < tw * th; i += threads) {
            const int2 p = clamp(origin + int2(i % tw, i / tw), int2(0), lim);
            tile[i] = half4(saturate(fsrEasuAt(src, uint2(p), inSize, outSize)), 0.0h);
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    const int2 gid = int2(group * shape + tid);
    if (gid.x >= w || gid.y >= h) return;
    const int c = (int(tid.y) + 1) * tw + int(tid.x) + 1;
    float3 colour = fsrRcas(float3(tile[c - tw].rgb), float3(tile[c - 1].rgb), float3(tile[c].rgb),
                            float3(tile[c + 1].rgb), float3(tile[c + tw].rgb), params.x);
    colour = anvilCounterOver(colour, gid, w, h, params);
    dst.write(float4(colour, 1.0), uint2(gid));
}

// =============================================================================
// FSR 3 for every game: Anvil's temporal pass (0.29).
//
// AMD's FSR 3 upscaler is temporal: every frame is blended with the frames before it,
// moved along the game's own motion vectors, so edges that shimmer and crawl in motion
// settle, and what one frame's pixels miss builds up over several. Those motion vectors —
// with depth and a jittered camera — come from inside the game's renderer, and only a game
// built for FSR hands them over. These passes do the same kind of blending for any game:
// the motion is measured from the game's own pictures (as frame generation's is), per
// 8x8 block and to a fraction of a pixel, and the history is held to the range the
// current frame's own neighbourhood allows — so where a measurement is wrong the picture
// falls back to the current frame instead of smearing. FSR 1 (EASU, then RCAS) takes the
// result to the display, and frame generation reuses the same motion.
//
// Per frame: at the game's size, anvil_fsr3_luma; anvil_optical_flow on its coarse plane
// (stride 8); anvil_fsr3_motion and anvil_fsr3_settle on its finer one. Then at the display's,
// anvil_fsr3_resolve: EASU, RCAS, the blend and the counter in one pass.
//
// Measured on Graphics Prep's moving test scene (anvil_prep.mm), LEGO's sizes on an M4: against a
// supersampled reference, 19% closer than FSR 1 in motion, 18% standing still, 22% less flicker,
// and no trail behind the moving disc.
// =============================================================================

constant float3 kFsr3Luma = float3(0.2126, 0.7152, 0.0722);

// Whether every component is a number, from its bits: Anvil's shaders compile with fast maths,
// which lets the compiler assume isfinite() is always true and drop the check — and a value
// that isn't a number, once in the history, would stay there. These it can't drop.
static inline bool fsr3Finite(float v) { return (as_type<uint>(v) & 0x7f800000u) != 0x7f800000u; }
static inline bool fsr3Finite(float2 v) { return all((as_type<uint2>(v) & 0x7f800000u) != 0x7f800000u); }
static inline bool fsr3Finite(float3 v) { return all((as_type<uint3>(v) & 0x7f800000u) != 0x7f800000u); }
static inline bool fsr3Finite(float4 v) { return all((as_type<uint4>(v) & 0x7f800000u) != 0x7f800000u); }

/// The frame's luma on two planes: `plane`, its size divided by `scale.x` (2, or 4 for a frame
/// over 2048 wide, so motion costs the same at any size), and `coarse`, divided by twice
/// that. One thread per coarse pixel. Motion is matched on the box-averaged planes, where much
/// of a game's edge shimmer is already smoothed away: a game without anti-aliasing changes
/// from frame to frame at every edge by a fraction of a pixel even where only the camera
/// moved, which is exactly what this pass is to settle and must not be mistaken for motion.
/// Both planes are rounded up, so every pixel is covered.
kernel void anvil_fsr3_luma(texture2d<float, access::read>  src    [[texture(0)]],
                            texture2d<float, access::write> plane  [[texture(1)]],
                            texture2d<float, access::write> coarse [[texture(2)]],
                            constant int&                   scaleIn [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= coarse.get_width() || gid.y >= coarse.get_height()) return;
    const int S = clamp(scaleIn, 1, 8);
    const int2 lim = int2(src.get_width(), src.get_height()) - 1;
    const int2 origin = int2(gid) * 2 * S;
    float sum = 0.0;
    for (int by = 0; by < 2; ++by) {
        for (int bx = 0; bx < 2; ++bx) {
            float box = 0.0;
            for (int y = 0; y < S; ++y)
                for (int x = 0; x < S; ++x)
                {
                    const float3 c = src.read(uint2(clamp(origin + int2(bx * S + x, by * S + y), int2(0), lim))).rgb;
                    box += fsr3Finite(c) ? dot(saturate(c), kFsr3Luma) : 0.0;
                }
            box /= float(S * S);
            const uint2 q = gid * 2 + uint2(bx, by);
            if (q.x < plane.get_width() && q.y < plane.get_height()) plane.write(float4(box), q);
            sum += box;
        }
    }
    coarse.write(float4(sum * 0.25), gid);
}

/// The widest plane: the luma plane a quarter the size each way (8 game pixels a pixel at the
/// usual scale), through a Gaussian of 2.5 plane pixels. A plain average — the 2x2 box the
/// coarse plane is — leaves a fine repeating pattern in, as a moiré that moves its own way: on
/// Graphics Prep's scene, a chequerboard of 5.75 plane pixels averaged over 8 game pixels was
/// followed at the wrong speed in every block. The Gaussian keeps 2% of it and the picture's
/// broad shapes whole. One thread a pixel of `wide`.
kernel void anvil_fsr3_wide(texture2d<float, access::sample> plane [[texture(0)]],
                            texture2d<float, access::write>  wide  [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= wide.get_width() || gid.y >= wide.get_height()) return;
    constexpr sampler lin(coord::normalized, filter::linear, address::clamp_to_edge);
    const float2 size = float2(plane.get_width(), plane.get_height());
    const float2 centre = (float2(gid) + 0.5) * 4.0;
    // 16x16 plane pixels in 8x8 bilinear taps: each tap stands between two pixels each way,
    // placed so the filter weighs them as the Gaussian does, and counts for both.
    const float2 first = floor(centre) - 7.0;
    float2 at[8], wt[8];
    for (int i = 0; i < 8; ++i) {
        const float2 d0 = first + float(2 * i) + 0.5 - centre, d1 = d0 + 1.0;
        const float2 w0 = exp(-d0 * d0 * (1.0 / (2.0 * 2.5 * 2.5))), w1 = exp(-d1 * d1 * (1.0 / (2.0 * 2.5 * 2.5)));
        wt[i] = w0 + w1;
        at[i] = first + float(2 * i) + 0.5 + w1 / wt[i];
    }
    float sum = 0.0, weight = 0.0;
    for (int y = 0; y < 8; ++y) {
        for (int x = 0; x < 8; ++x) {
            const float v = plane.sample(lin, float2(at[x].x, at[y].y) / size).r;
            const float w = wt[x].x * wt[y].y;
            if (fsr3Finite(v)) { sum += w * v; weight += w; }
        }
    }
    wide.write(float4(weight > 0.0 ? sum / weight : 0.0), gid);
}

/// The pan: the whole picture's motion, from the widest plane (the luma plane a quarter the size each way,
/// through a Gaussian: a repeating pattern smaller than a few dozen game pixels has blurred away there, the
/// picture's large shapes and its light and shade haven't) — every offset within ±8 of its pixels scored over the
/// whole plane, less a border, one threadgroup an offset. Matched in blocks, as the widest field is, a block of
/// gentle shading fits many offsets, and on Graphics Prep's repeating floor with landmarks panned at 21 and 37 game
/// pixels a frame (16 October) the fine search found the true motion in 5% and 3% of blocks. Scored over the
/// whole picture, only the pan fits. cost: 17x17, the mean difference at each offset.
kernel void anvil_fsr3_pan_cost(texture2d<float, access::read>  prev [[texture(0)]],
                                texture2d<float, access::read>  curr [[texture(1)]],
                                texture2d<float, access::write> cost [[texture(2)]],
                                uint2 group    [[threadgroup_position_in_grid]],
                                uint  index    [[thread_index_in_threadgroup]],
                                uint  simdLane [[thread_index_in_simdgroup]],
                                uint  simdId   [[simdgroup_index_in_threadgroup]])
{
    threadgroup float partial[8];
    const int w = int(curr.get_width()), h = int(curr.get_height());
    const int2 o = int2(group) - 8;
    // Every second pixel each way: the plane is blurred already, and every pixel cost 0.4 ms a frame with the fine
    // pass on an M4 at LEGO's sizes.
    const int border = 9;
    const int iw = max((w - 2 * border) / 2, 1), ih = max((h - 2 * border) / 2, 1);
    float sum = 0.0;
    for (int i = int(index); i < iw * ih; i += 256) {
        const int2 q = int2(border + 2 * (i % iw), border + 2 * (i / iw));
        const float c = curr.read(uint2(q)).r, p = prev.read(uint2(q + o)).r;
        if (fsr3Finite(c) && fsr3Finite(p)) sum += abs(c - p);
    }
    const float s = simd_sum(sum);
    if (simdLane == 0 && simdId < 8) partial[simdId] = s;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (index == 0) {
        float total = 0.0;
        for (int k = 0; k < 8; ++k) total += partial[k];
        cost.write(float4(total / float(iw * ih)), group);
    }
}

/// The pan from its costs, one thread: the lowest (the shorter of two alike), and how sure — how far below the
/// lowest offset two or more widest-plane pixels from it the cost is, against how much the picture holds at all.
/// A picture with nothing large in it (a repeating floor alone, blurred to grey) has no pan to find: its costs
/// are alike everywhere. And it has to do better than what the blocks themselves followed last frame (the most
/// common of their vectors): on a chequerboard alone at 10.6 game pixels a frame (16 October) the blocks had it
/// right at 93%, a pan one repeat off fitted as well and pulled half of them away; on the same floor with
/// landmarks, the camera speeding up to 21 and 37, the blocks lost it and the pan was right. Where it isn't
/// clearly better than theirs, it isn't said to be sure.
/// coarse: x, y in plane pixels (four to a widest-plane pixel), z how sure (0–1).
/// before: last frame's motion per block, in game pixels; info: x = game pixels per plane pixel, y = 1 when
/// `before` holds it.
kernel void anvil_fsr3_pan_pick(texture2d<float, access::read>  cost   [[texture(0)]],
                                texture2d<float, access::write> coarse [[texture(1)]],
                                texture2d<float, access::read>  before [[texture(2)]],
                                constant float4&                info   [[buffer(0)]],
                                uint index [[thread_index_in_threadgroup]])
{
    // One threadgroup of 256: the costs and the count of what the blocks followed shared out among them, the
    // picking on one. On one thread alone, counting the blocks took FSR 3 from 3.97 to 4.54 ms a frame on an M4.
    threadgroup float costs[289];
    threadgroup atomic_uint counts[289];
    for (int i = int(index); i < 289; i += 256) {
        costs[i] = cost.read(uint2(i % 17, i / 17)).r;
        atomic_store_explicit(&counts[i], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (info.y > 0.5) {
        const float perWide = 4.0 * max(info.x, 1.0);
        const int bw = int(before.get_width()), bh = int(before.get_height());
        for (int i = int(index); i < bw * bh; i += 256) {
            const float2 v = before.read(uint2(i % bw, i / bw)).xy;
            if (!fsr3Finite(v)) continue;
            const int2 b = int2(round(v / perWide)) + 8;
            if (all(b >= 0) && all(b < 17)) atomic_fetch_add_explicit(&counts[b.y * 17 + b.x], 1u, memory_order_relaxed);
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (index != 0) return;
    float best = 1e30, total = 0.0;
    int2 at = int2(8);
    for (int i = 0; i < 289; ++i) {
        const int2 xy = int2(i % 17, i / 17);
        const float c = costs[i] + 1e-6 * float(abs(xy.x - 8) + abs(xy.y - 8));
        total += c;
        if (c < best) { best = c; at = xy; }
    }
    float second = 1e30;
    for (int i = 0; i < 289; ++i) {
        const int2 xy = int2(i % 17, i / 17);
        if (max(abs(xy.x - at.x), abs(xy.y - at.y)) >= 2) second = min(second, costs[i]);
    }
    const float mean = total / 289.0;
    // How much the widest plane holds at all — its mean difference over every offset: on Graphics Prep's scenes
    // 0.047 for a chequerboard and thin lines alone (blurred to grey: a pan found there was one repeat off and still
    // looked sure, and the made frame of the shipped test came out 23.7 from the true picture against 7.5), 0.062
    // with landmarks, 0.09 for the natural scene. Below 0.055 there is nothing large enough to find a pan from.
    float sure = (mean < 0.055 || second > 1e29) ? 0.0 : saturate((second - best) / max(second, 1e-6));
    // What the blocks followed last frame: the most common of their vectors, to a widest-plane pixel.
    int2 theirs = int2(8);
    uint most = 0u;
    for (int i = 0; i < 289; ++i) {
        const uint n = atomic_load_explicit(&counts[i], memory_order_relaxed);
        if (n > most) { most = n; theirs = int2(i % 17, i / 17); }
    }
    if (max(abs(theirs.x - at.x), abs(theirs.y - at.y)) >= 2 && best > 0.85 * costs[theirs.y * 17 + theirs.x]) sure = 0.0;
    coarse.write(float4(float2(at - 8) * 4.0, sure, mean), uint2(0));
}

/// The pan made exact, on the luma plane itself: every whole-pixel offset within ±3 of the widest plane's, scored
/// over the plane (every third pixel each way). The widest plane's is to four plane pixels; a block matched a
/// pixel off a repeating pattern's lines loses to the same pattern one repeat off but exactly lined up.
/// cost: 7x7.
kernel void anvil_fsr3_pan_fine_cost(texture2d<float, access::read>  prev   [[texture(0)]],
                                     texture2d<float, access::read>  curr   [[texture(1)]],
                                     texture2d<float, access::read>  coarse [[texture(2)]],
                                     texture2d<float, access::write> cost   [[texture(3)]],
                                     uint2 group    [[threadgroup_position_in_grid]],
                                     uint  index    [[thread_index_in_threadgroup]],
                                     uint  simdLane [[thread_index_in_simdgroup]],
                                     uint  simdId   [[simdgroup_index_in_threadgroup]])
{
    threadgroup float partial[8];
    const int w = int(curr.get_width()), h = int(curr.get_height());
    const float4 c0 = coarse.read(uint2(0));
    const int2 o = int2(round(c0.xy)) + int2(group) - 3;
    const int border = 40;
    const int iw = max((w - 2 * border) / 3, 1), ih = max((h - 2 * border) / 3, 1);
    float sum = 0.0;
    for (int i = int(index); i < iw * ih; i += 256) {
        const int2 q = int2(border + 3 * (i % iw), border + 3 * (i / iw));
        const int2 qp = clamp(q + o, int2(0), int2(w - 1, h - 1));
        const float c = curr.read(uint2(q)).r, p = prev.read(uint2(qp)).r;
        if (fsr3Finite(c) && fsr3Finite(p)) sum += abs(c - p);
    }
    const float s = simd_sum(sum);
    if (simdLane == 0 && simdId < 8) partial[simdId] = s;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (index == 0) {
        float total = 0.0;
        for (int k = 0; k < 8; ++k) total += partial[k];
        cost.write(float4(total / float(iw * ih)), group);
    }
}

/// The exact pan: the lowest of the fine costs, placed between pixels with a parabola each way.
/// pan: x, y in plane pixels, z how sure (the widest plane's).
kernel void anvil_fsr3_pan_fine_pick(texture2d<float, access::read>  cost   [[texture(0)]],
                                     texture2d<float, access::read>  coarse [[texture(1)]],
                                     texture2d<float, access::write> pan    [[texture(2)]],
                                     uint tid [[thread_position_in_grid]])
{
    if (tid != 0) return;
    const float4 c0 = coarse.read(uint2(0));
    float best = 1e30;
    int2 at = int2(3);
    for (int y = 0; y < 7; ++y)
        for (int x = 0; x < 7; ++x) {
            const float c = cost.read(uint2(x, y)).r + 1e-7 * float(abs(x - 3) + abs(y - 3));
            if (c < best) { best = c; at = int2(x, y); }
        }
    float2 sub = float2(0.0);
    if (at.x > 0 && at.x < 6) {
        const float l = cost.read(uint2(at.x - 1, at.y)).r, m = cost.read(uint2(at)).r, r = cost.read(uint2(at.x + 1, at.y)).r;
        const float den = l - 2.0 * m + r;
        if (den > 1e-9) sub.x = clamp(0.5 * (l - r) / den, -0.5, 0.5);
    }
    if (at.y > 0 && at.y < 6) {
        const float u = cost.read(uint2(at.x, at.y - 1)).r, m = cost.read(uint2(at)).r, d = cost.read(uint2(at.x, at.y + 1)).r;
        const float den = u - 2.0 * m + d;
        if (den > 1e-9) sub.y = clamp(0.5 * (u - d) / den, -0.5, 0.5);
    }
    pan.write(float4(round(c0.xy) + float2(at - 3) + sub, c0.z, c0.w), uint2(0));
}

constant int kFineBlock  = 8;                               // 8x8 plane pixels per vector
constant int kFineTries  = 15;                              // guesses scored per block
constant int kFineRadius = 1;                               // then ±1 plane pixel around the best
constant int kFineSpan   = 2 * kFineRadius + 1;             // 5

/// How well a block matched, for how much there is in it to match: 1 for a block that matched
/// closely, or that is flat (it matches anywhere, and anywhere is right for it); towards 0 as
/// the leftover difference approaches the block's own variance. In luma squared.
static inline float fsr3Trust(float mse, float variance) {
    if (variance < (2.0 / 255.0) * (2.0 / 255.0)) return 1.0;
    // Leftover against what the block holds: a block that moved where it was measured to
    // leaves a small fraction of its own variance; one that didn't, about all of it.
    return saturate(1.25 - 1.5 * max(mse - (1.0 / 255.0) * (1.0 / 255.0), 0.0) / variance);
}

/// Where each block of this frame was a frame ago, in the game's pixels and to a fraction of
/// one: x, y towards the earlier position (as anvil_optical_flow's), z how far it can be
/// trusted, w the block's variance. Matched on the luma plane, 8x8 of it a block (16x16 of the
/// game's pixels at the usual scale of 2): big enough to see past a repeating pattern.
///
/// A block is scored, by its squared difference from the last frame at exactly that offset
/// (sampled between pixels), at fifteen guesses: no motion; last frame's motion here and in
/// the four blocks beside it; last frame's 8 blocks away each way (what most of the picture is
/// doing — a camera pan); the coarse field's; the widest field's; and the pan, measured over the
/// whole picture (anvil_fsr3_pan_cost) where it's sure. Every guess costs a
/// little for each pixel it moves (params.y), except this block's own motion last frame and
/// the widest field's: a repeating pattern matches as well at a wrong offset a whole repeat
/// away as at the right one, and of two such the smaller is usually the motion — but not in a
/// fast pan. Graphics Prep's scene panned at 13 and 26 game pixels a frame (11 October) was
/// followed at a whole chequer square off in every block, trusted all the same, and the
/// picture's thin lines washed out; the widest field, matched where the pattern has blurred
/// away, has the pan right, and motion already being followed, however fast, is kept. The best
/// is searched a plane pixel each way and placed between pixels. One 8x8 threadgroup a block.
///
/// params: x = 1 when `before` holds last frame's motion (0 just after starting over);
/// y = the cost of a game pixel of motion, in luma squared; z = game pixels per plane pixel;
/// w = 1 when `wide` holds the widest field (a vector per 32 plane pixels, in plane pixels), 2 when
/// `pan` holds the pan too.
kernel void anvil_fsr3_motion(texture2d<float, access::sample> lumaPrev [[texture(0)]],
                              texture2d<float, access::read>   lumaCurr [[texture(1)]],
                              texture2d<float, access::sample> coarse   [[texture(2)]],
                              texture2d<float, access::read>   before   [[texture(3)]],
                              texture2d<float, access::write>  motion   [[texture(4)]],
                              texture2d<float, access::sample> wide     [[texture(5)]],
                              texture2d<float, access::read>   pan      [[texture(6)]],
                              constant float4&                 params   [[buffer(0)]],
                              uint2 group     [[threadgroup_position_in_grid]],
                              uint2 tid       [[thread_position_in_threadgroup]],
                              uint  index     [[thread_index_in_threadgroup]],
                              uint  simdLane  [[thread_index_in_simdgroup]],
                              uint  simdId    [[simdgroup_index_in_threadgroup]],
                              uint  simdWidth [[threads_per_simdgroup]])
{
    threadgroup float tryCost[8][kFineTries];
    threadgroup float stepCost[8][kFineSpan * kFineSpan];
    threadgroup float2 chosen;
    threadgroup float moments[8][2];
    threadgroup float gradient[8][5];
    threadgroup float result[2];

    const int w = int(lumaCurr.get_width()), h = int(lumaCurr.get_height());
    const int2 lim = int2(w - 1, h - 1);
    const float2 size = float2(w, h);
    const int2 base = int2(group) * kFineBlock;
    const int2 p = clamp(base + int2(tid), int2(0), lim);
    const float c = lumaCurr.read(uint2(p)).r;
    const float2 at = float2(p) + 0.5;
    const uint groups = min((uint(kFineBlock * kFineBlock) + simdWidth - 1) / simdWidth, 8u);

    constexpr sampler lin(coord::normalized, filter::linear, address::clamp_to_edge);
    const int2 mlim = int2(before.get_width(), before.get_height()) - 1;
    const bool history = params.x > 0.5;
    const float S = max(params.z, 1.0);
    const int2 g = int2(group);
    const int2 around[9] = { int2(0, 0), int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1),
                             int2(-8, 0), int2(8, 0), int2(0, -8), int2(0, 8) };
    float2 tries[kFineTries];
    tries[0] = float2(0.0);
    for (int t = 0; t < 9; ++t)
        tries[1 + t] = history ? before.read(uint2(clamp(g + around[t], int2(0), mlim))).xy / S : float2(0.0);
    // The coarse field: a vector per 16 plane pixels, in units of half a plane pixel.
    const float2 centre = float2(base) + 0.5 * float(kFineBlock);
    const int2 cs = int2(coarse.get_width(), coarse.get_height());
    tries[10] = coarse.read(uint2(clamp(int2(centre / 16.0), int2(0), cs - 1))).xy * 0.5;
    tries[11] = coarse.sample(lin, centre / 16.0 / float2(cs)).xy * 0.5;
    // The widest field: a vector per 32 plane pixels, already in plane pixels.
    const bool haveWide = params.w > 0.5;
    const int2 ws = int2(wide.get_width(), wide.get_height());
    tries[12] = haveWide ? wide.read(uint2(clamp(int2(centre / 32.0), int2(0), ws - 1))).xy : float2(0.0);
    tries[13] = haveWide ? wide.sample(lin, centre / 32.0 / float2(ws)).xy : float2(0.0);
    // The pan (anvil_fsr3_pan_pick), where it's sure of it: what most of the picture is doing.
    const float4 panNow = params.w > 1.5 ? pan.read(uint2(0)) : float4(0.0);
    const bool havePan = params.w > 1.5 && fsr3Finite(panNow) && panNow.z > 0.05;
    tries[14] = havePan ? panNow.xy : float2(0.0);
    float extra[kFineTries];
    for (int t = 0; t < kFineTries; ++t) {
        if (!fsr3Finite(tries[t]) || any(abs(tries[t]) > 256.0)) tries[t] = float2(0.0);
        // Its own motion last frame (try 1), the widest field's (12, 13) and the pan (14) are free;
        // anything else costs its length.
        const bool free = (t == 1 && history) || (t >= 12 && t <= 13 && haveWide) || (t == 14 && havePan);
        extra[t] = free ? 0.0 : params.y * S * (abs(tries[t].x) + abs(tries[t].y));
    }

    for (int t = 0; t < kFineTries; ++t) {
        const float d = c - lumaPrev.sample(lin, (at + tries[t]) / size).r;
        const float sum = simd_sum(d * d);
        if (simdLane == 0 && simdId < 8) tryCost[simdId][t] = sum;
    }
    {
        const float s1 = simd_sum(c), s2 = simd_sum(c * c);
        if (simdLane == 0 && simdId < 8) { moments[simdId][0] = s1; moments[simdId][1] = s2; }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (index == 0) {
        float bestCost = 1e30;
        float2 pick = float2(0.0);
        for (int t = 0; t < kFineTries; ++t) {
            float sum = 0.0;
            for (uint q = 0; q < groups; ++q) sum += tryCost[q][t];
            // The pan wins only by matching better: a block whose own motion last frame fits as well keeps it.
            // On a chequerboard alone the pan can be one repeat off and fit as well, and taking it on a tie took
            // 93% of blocks right at 10.6 game pixels a frame down to 49% (16 October).
            const float cost = (sum * (1.0 / 64.0) + extra[t]) * (t == 14 ? 1.04 : 1.0) + (t == 14 ? 1e-6 : 0.0);
            if (cost < bestCost) { bestCost = cost; pick = tries[t]; }
        }
        chosen = pick;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    const float2 from = chosen;
    for (int i = 0; i < kFineSpan * kFineSpan; ++i) {
        const float2 step = float2(i % kFineSpan, i / kFineSpan) - float(kFineRadius);
        const float d = c - lumaPrev.sample(lin, (at + from + step) / size).r;
        const float sum = simd_sum(d * d);
        if (simdLane == 0 && simdId < 8) stepCost[simdId][i] = sum;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (index == 0) {
        float cost[kFineSpan * kFineSpan];
        int best = 0;
        for (int i = 0; i < kFineSpan * kFineSpan; ++i) {
            float sum = 0.0;
            for (uint q = 0; q < groups; ++q) sum += stepCost[q][i];
            const int2 o = int2(i % kFineSpan, i / kFineSpan) - kFineRadius;
            // The guess itself wins a tie.
            cost[i] = sum * (1.0 / 64.0) + 1e-6 * float(abs(o.x) + abs(o.y));
            if (cost[i] < cost[best]) best = i;
        }
        const int bx = best % kFineSpan, by = best / kFineSpan;
        // Between pixels, first roughly: the lowest point of a parabola through the winner and
        // its neighbours.
        float2 sub = float2(0.0);
        if (bx > 0 && bx < kFineSpan - 1) {
            const float l = cost[best - 1], m = cost[best], r = cost[best + 1];
            const float den = l - 2.0 * m + r;
            if (den > 1e-12) sub.x = clamp(0.5 * (l - r) / den, -0.5, 0.5);
        }
        if (by > 0 && by < kFineSpan - 1) {
            const float u = cost[best - kFineSpan], m = cost[best], d = cost[best + kFineSpan];
            const float den = u - 2.0 * m + d;
            if (den > 1e-12) sub.y = clamp(0.5 * (u - d) / den, -0.5, 0.5);
        }
        chosen = from + float2(bx - kFineRadius, by - kFineRadius) + sub;
        result[0] = cost[best];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Then exactly: two Lucas-Kanade steps from there. A parabola through sampled differences
    // leans towards whole pixels — measured 0.17 of a pixel short on a pan of 1.07 a frame —
    // and blended over ten frames that lean is a picture trailing behind. The gradient step
    // has no such lean.
    for (int step = 0; step < 2; ++step) {
        const float2 q = (at + chosen) / size;
        const float2 dx = float2(1.0 / size.x, 0.0), dy = float2(0.0, 1.0 / size.y);
        const float i0 = lumaPrev.sample(lin, q).r;
        const float ix = 0.5 * (lumaPrev.sample(lin, q + dx).r - lumaPrev.sample(lin, q - dx).r);
        const float iy = 0.5 * (lumaPrev.sample(lin, q + dy).r - lumaPrev.sample(lin, q - dy).r);
        const float it = c - i0;
        const float terms[5] = { simd_sum(ix * ix), simd_sum(ix * iy), simd_sum(iy * iy), simd_sum(ix * it), simd_sum(iy * it) };
        if (simdLane == 0 && simdId < 8) for (int i = 0; i < 5; ++i) gradient[simdId][i] = terms[i];
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (index == 0) {
            float a = 0.0, b = 0.0, d = 0.0, ex = 0.0, ey = 0.0;
            for (uint g2 = 0; g2 < groups; ++g2) {
                a += gradient[g2][0]; b += gradient[g2][1]; d += gradient[g2][2]; ex += gradient[g2][3]; ey += gradient[g2][4];
            }
            // A little held back, so a block with an edge in one direction only moves across it.
            const float reg = 1e-4;
            a += reg; d += reg;
            const float det = a * d - b * b;
            if (det > 1e-12) {
                const float2 delta = float2(d * ex - b * ey, a * ey - b * ex) / det;
                chosen += clamp(delta, float2(-0.5), float2(0.5));
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (index != 0) return;

    float s1 = 0.0, s2 = 0.0;
    for (uint q = 0; q < groups; ++q) { s1 += moments[q][0]; s2 += moments[q][1]; }
    const float mean = s1 * (1.0 / 64.0);
    const float variance = max(s2 * (1.0 / 64.0) - mean * mean, 0.0);
    motion.write(float4(chosen * S, fsr3Trust(result[0], variance), variance), group);
}

/// Each block's motion made to agree with its neighbours': of its own and the eight around
/// it, the one that matches the block well and differs least from the others (in game pixels). A block on a
/// repeating pattern can match at a wrong offset as well as at the right one; the blocks
/// around it, most of which aren't fooled, outvote it. One 8x8 threadgroup per block.
///
/// params: x = how much a pixel of disagreement with the neighbours costs, y = a pixel of
/// motion (as in anvil_fsr3_motion), both in luma squared; z = game pixels per plane pixel.
kernel void anvil_fsr3_settle(texture2d<float, access::sample> lumaPrev [[texture(0)]],
                              texture2d<float, access::read>   lumaCurr [[texture(1)]],
                              texture2d<float, access::read>   raw      [[texture(2)]],
                              texture2d<float, access::write>  motion   [[texture(3)]],
                              constant float4&                 params   [[buffer(0)]],
                              uint2 group     [[threadgroup_position_in_grid]],
                              uint2 tid       [[thread_position_in_threadgroup]],
                              uint  index     [[thread_index_in_threadgroup]],
                              uint  simdLane  [[thread_index_in_simdgroup]],
                              uint  simdId    [[simdgroup_index_in_threadgroup]],
                              uint  simdWidth [[threads_per_simdgroup]])
{
    threadgroup float tryCost[8][9];
    const int w = int(lumaCurr.get_width()), h = int(lumaCurr.get_height());
    const int2 lim = int2(w - 1, h - 1);
    const float2 size = float2(w, h);
    const int2 p = clamp(int2(group) * kFineBlock + int2(tid), int2(0), lim);
    const float c = lumaCurr.read(uint2(p)).r;
    const float2 at = float2(p) + 0.5;
    const uint groups = min((uint(kFineBlock * kFineBlock) + simdWidth - 1) / simdWidth, 8u);
    const int2 mlim = int2(raw.get_width(), raw.get_height()) - 1;
    constexpr sampler lin(coord::normalized, filter::linear, address::clamp_to_edge);

    float4 near[9];
    for (int i = 0; i < 9; ++i) {
        near[i] = raw.read(uint2(clamp(int2(group) + int2(i % 3 - 1, i / 3 - 1), int2(0), mlim)));
        if (!fsr3Finite(near[i])) near[i] = float4(0.0, 0.0, 0.0, 0.0);
        const float d = c - lumaPrev.sample(lin, (at + near[i].xy / max(params.z, 1.0)) / size).r;
        const float sum = simd_sum(d * d);
        if (simdLane == 0 && simdId < 8) tryCost[simdId][i] = sum;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (index != 0) return;
    float bestCost = 1e30, bestMse = 0.0;
    int best = 4;
    for (int i = 0; i < 9; ++i) {
        float sum = 0.0;
        for (uint q = 0; q < groups; ++q) sum += tryCost[q][i];
        const float mse = sum * (1.0 / 64.0);
        float apart = 0.0;
        for (int j = 0; j < 9; ++j) {
            if (j == 4) continue;
            const float2 d = abs(near[i].xy - near[j].xy);
            apart += min(d.x + d.y, 4.0);
        }
        // Its own motion wins a tie.
        const float cost = mse + params.x * apart * 0.125 + params.y * (abs(near[i].x) + abs(near[i].y))
                         + (i == 4 ? 0.0 : 1e-6);
        if (cost < bestCost) { bestCost = cost; bestMse = mse; best = i; }
    }
    // And how far the blocks beside differ from it, in game pixels: where something moving meets
    // what's behind it (anvil_fsr3_resolve), worked out once a block rather than once a pixel.
    float apart = 0.0;
    for (int i = 1; i < 9; i += 2) apart = max(apart, length(near[i].xy - near[best].xy));
    motion.write(float4(near[best].xy, fsr3Trust(bestMse, near[4].w), apart), group);
}

static inline float3 fsr3YCoCg(float3 c) {
    return float3( 0.25 * c.r + 0.5 * c.g + 0.25 * c.b,
                   0.5  * c.r             - 0.5  * c.b,
                  -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

static inline float3 fsr3RGB(float3 c) {
    return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

static inline half3 fsr3YCoCgH(half3 c) {
    return half3( 0.25h * c.r + 0.5h * c.g + 0.25h * c.b,
                  0.5h  * c.r              - 0.5h  * c.b,
                 -0.25h * c.r + 0.5h * c.g - 0.25h * c.b);
}

static inline half3 fsr3RGBH(half3 c) {
    return half3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

/// The history at `uv` through a Catmull-Rom filter, in five bilinear taps: a bilinear tap
/// alone softens the picture a little more every frame it is moved. In half precision, as the
/// history is kept; the positions and weights in full.
static inline half4 fsr3History(texture2d<half, access::sample> tex, float2 uv, float2 size)
{
    constexpr sampler lin(coord::normalized, filter::linear, address::clamp_to_edge);
    const float2 at = uv * size;
    const float2 t1 = floor(at - 0.5) + 0.5;
    const float2 f = at - t1;
    const float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    const float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    const float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    const float2 w3 = f * f * (-0.5 + 0.5 * f);
    const float2 w12 = w1 + w2;
    const float2 t12 = (t1 + w2 / w12) / size;
    const float2 t0 = (t1 - 1.0) / size;
    const float2 t3 = (t1 + 2.0) / size;
    const float a = w12.x * w0.y, b = w0.x * w12.y, c = w12.x * w12.y, d = w3.x * w12.y, e = w12.x * w3.y;
    const half4 sum = tex.sample(lin, float2(t12.x, t0.y)) * half(a)
                    + tex.sample(lin, float2(t0.x, t12.y)) * half(b)
                    + tex.sample(lin, t12)                 * half(c)
                    + tex.sample(lin, float2(t3.x, t12.y)) * half(d)
                    + tex.sample(lin, float2(t12.x, t3.y)) * half(e);
    return sum / half(a + b + c + d + e);
}

/// FSR 3 at the display's size, in one pass: this frame upscaled with EASU into threadgroup
/// memory, a tile and a pixel of border at a time (as anvil_fsr_fused), sharpened with RCAS,
/// and blended with the picture so far moved along the measured motion — into `dst`, with the
/// frame counter over it, and into `next`, the history for the next frame (16-bit float: the
/// colour, and in alpha how many frames it holds). At the display's own size the frame is
/// the tile, with nothing to upscale.
///
/// Blending at the display's size, as AMD's FSR 2 and 3 do, keeps the detail EASU draws:
/// blended at the game's size and upscaled after, every frame's resampling softened the
/// history a little more, and the picture lost to FSR 1 alone on Graphics Prep's test scene
/// even with the scene's true motion. In one pass, nothing at the display's size goes out to
/// memory but the two results: as four (EASU, blend, RCAS) it cost 4.9 ms a frame on an M4
/// at LEGO's sizes.
///
/// Each pixel's history is taken from where its block's motion says it was, through a
/// Catmull-Rom filter — or, where that moved, from where it is, if this frame's 3x3
/// neighbourhood agrees with that better (a HUD over a moving scene). Two places, not the
/// four that also tried the neighbouring blocks': that cost 0.5 ms a frame more on an M4 at
/// LEGO's sizes, and gained 0.03 of a 255th on the test scene. The history is clipped into
/// the neighbourhood's range
/// (mean ± blend.z standard deviations, within its min and max, in YCoCg), and counts for
/// less the less the motion was trusted and the further it had to be clipped: a history that
/// disagrees with the frame is a moved or uncovered object, and the frame wins.
///
/// The blend is worked in half precision, as the history is kept, and a pixel that didn't
/// move reads its history rather than filtering it. On an M4 at LEGO's sizes (4 October) the
/// pass went from 2.95 to 2.58 ms with the same scores on the test scene: half the registers let
/// a group be 32x32 (from 16x16), so less of the tile's border is upscaled twice. A 10-bit
/// history with an 8-bit frame count instead of 16-bit float measured the same: the pass is
/// bound by its arithmetic, not by memory.
///
/// params: x = sharpness, y = fps, z = counter scale, w = counter corner (negative: none).
/// blend: x = 1 with a history to blend (0: start over from this frame), y = most frames
/// held (the history's weight is at most 1 - 1/y), z = the clip's standard deviations,
/// w = how much less a bright sample counts (0: not at all).
/// game: xy = the game's frame size, which `motion`'s vectors are in pixels of; z = the
/// game pixels each motion vector covers, across and down.
kernel void anvil_fsr3_resolve(texture2d<half, access::sample>  src     [[texture(0)]],
                               texture2d<half, access::sample>  history [[texture(1)]],
                               texture2d<float, access::read>   motion  [[texture(2)]],
                               texture2d<float, access::write>  dst     [[texture(3)]],
                               texture2d<half, access::write>   next    [[texture(4)]],
                               constant float4&                 params  [[buffer(0)]],
                               constant float4&                 blend   [[buffer(1)]],
                               constant float4&                 game    [[buffer(2)]],
                               threadgroup half4*               tile    [[threadgroup(0)]],
                               uint2 tid   [[thread_position_in_threadgroup]],
                               uint2 group [[threadgroup_position_in_grid]],
                               uint2 shape [[threads_per_threadgroup]],
                               uint  index [[thread_index_in_threadgroup]])
{
    const int w = int(dst.get_width()), h = int(dst.get_height());
    const float2 inSize  = float2(src.get_width(), src.get_height());
    const float2 outSize = float2(w, h);
    const bool upscale = any(inSize != outSize);
    const int tw = int(shape.x) + 2, th = int(shape.y) + 2;
    const int2 origin = int2(group * shape) - 1;
    const int2 lim = int2(w - 1, h - 1);
    const int threads = int(shape.x * shape.y);
    // At exactly twice the game's size (the usual: a game at half a Retina display's pixels each way), a 2x2 at a
    // time from the texels the four share: on an M4 at LEGO's sizes the pass took 2.65 ms a frame against 2.89, its
    // scores on Graphics Prep's scene the same to the thousandth (16 October).
    if (upscale && all(outSize == 2.0 * inSize) && (shape.x & 1) == 0 && (shape.y & 1) == 0) {
        fsrEasuTileTwice(src, tile, origin, tw, th, lim, int(index), threads, inSize, true);
    } else {
        for (int i = int(index); i < tw * th; i += threads) {
            const int2 q = clamp(origin + int2(i % tw, i / tw), int2(0), lim);
            const half3 v = upscale ? saturate(fsrEasuAt(src, uint2(q), inSize, outSize)) : saturate(src.read(uint2(q)).rgb);
            tile[i] = half4(fsr3Finite(float3(v)) ? v : half3(0.0h), 0.0h);
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    const int2 p = int2(group * shape + tid);
    if (p.x >= w || p.y >= h) return;
    const int c = (int(tid.y) + 1) * tw + int(tid.x) + 1;
    float3 sharp = saturate(fsrRcas(float3(tile[c - tw].rgb), float3(tile[c - 1].rgb), float3(tile[c].rgb),
                                    float3(tile[c + 1].rgb), float3(tile[c + tw].rgb), params.x));
    if (!fsr3Finite(sharp)) sharp = float3(0.0);
    const uint2 at = uint2(p);
    if (blend.x < 0.5) {
        next.write(half4(half3(sharp), 1.0h), at);
        dst.write(float4(anvilCounterOver(sharp, p, w, h, params), 1.0), at);
        return;
    }

    // Motion is measured at the game's size, a vector per `cell` x `cell` of its pixels.
    const float2 gameSize = max(game.xy, float2(1.0));
    const float2 toOut = outSize / gameSize;
    const int cell = max(int(game.z), 1);
    const float2 g = (float2(p) + 0.5) / toOut;
    const int2 mlim = int2(motion.get_width(), motion.get_height()) - 1;
    const int2 block = clamp(int2(g) / cell, int2(0), mlim);
    const float4 m = motion.read(uint2(block));
    const bool moved = fsr3Finite(m.xyz);
    const float2 shift = moved ? m.xy * toOut : float2(0.0);
    const float2 from = float2(p) + 0.5 + shift;

    // Fast, and where blocks moving differently meet. In fast motion an eye follows no fine
    // detail, and frames blended there are what trails behind: on Graphics Prep's scene panned
    // at five and ten times its speed (11 October), thin lines washed out of the picture. Where
    // the blocks around disagree — something moving across what's behind it — one block's
    // vector is wrong for part of it. Both get a shorter memory (down to 3 frames, from 8 to 40
    // display pixels a frame, or 1 to 5 of disagreement) and a tighter clip, and at such an
    // edge each pixel also tries the vectors of the blocks beside it.
    const float speed = length(shift);
    // How far the blocks beside differ, as anvil_fsr3_settle found it (w, in game pixels); read
    // exactly, block by block, only where that says there's an edge.
    float apart = (moved && fsr3Finite(m.w)) ? m.w * max(toOut.x, toOut.y) : 0.0;
    const bool edge = apart > 1.0;
    float2 others[4] = { shift, shift, shift, shift };
    if (edge) {
        const int2 beside[4] = { int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
        apart = 0.0;
        for (int i = 0; i < 4; ++i) {
            const float4 n = motion.read(uint2(clamp(block + beside[i], int2(0), mlim)));
            if (fsr3Finite(n.xy)) others[i] = n.xy * toOut;
            apart = max(apart, length(others[i] - shift));
        }
    }
    const half quick = half(max(saturate((speed - 8.0) / 32.0), saturate((apart - 1.0) / 4.0)));

    // The neighbourhood's range in YCoCg. Its spread is taken about the centre, so that half
    // precision still sees the small one of a flat area.
    const half3 centre = half3(fsr3YCoCg(sharp));
    half3 d1 = half3(0.0h), d2 = half3(0.0h), lo = centre, hi = centre;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            const half3 s = fsr3YCoCgH(tile[c + dy * tw + dx].rgb);
            const half3 d = s - centre;
            d1 += d; d2 += d * d; lo = min(lo, s); hi = max(hi, s);
        }
    }
    const half3 meanD = d1 * (1.0h / 9.0h);
    const half3 mean = centre + meanD;
    const half3 sigma = sqrt(max(d2 * (1.0h / 9.0h) - meanD * meanD, half3(0.0h)));
    const half k = half(blend.z) * (1.0h - 0.35h * quick);
    const half3 boxLo = max(lo, min(mean - k * sigma, centre));
    const half3 boxHi = min(hi, max(mean + k * sigma, centre));

    half3 result = half3(sharp);
    half frames = 1.0h;
    half4 hist = half4(0.0h);
    half3 y = half3(0.0h);
    bool have = false;
    half trust = 1.0h;
    float outside = 1e30;
    if (all(from >= 0.0) && all(from <= outSize)) {              // else it came in from off the frame
        // Where nothing moved, the history is where it was: read, not filtered.
        hist = all(abs(shift) < 1.0 / 64.0) ? history.read(at) : fsr3History(history, from / outSize, outSize);
        have = fsr3Finite(float4(hist));
        trust = moved ? half(saturate(m.z)) : 1.0h;
        if (have) {
            y = fsr3YCoCgH(hist.rgb);
            outside = float(length(max(boxLo - y, half3(0.0h)) + max(y - boxHi, half3(0.0h))));
        }
    }
    // At an edge, the history where each block beside says this pixel was, if this frame agrees
    // with that better.
    if (edge && outside > 0.0) {
        for (int i = 0; i < 4; ++i) {
            if (length(others[i] - shift) <= 1.0) continue;
            const float2 there = float2(p) + 0.5 + others[i];
            if (!(all(there >= 0.0) && all(there <= outSize))) continue;
            const half4 h2 = fsr3History(history, there / outSize, outSize);
            if (!fsr3Finite(float4(h2))) continue;
            const half3 y2 = fsr3YCoCgH(h2.rgb);
            const float out2 = float(length(max(boxLo - y2, half3(0.0h)) + max(y2 - boxHi, half3(0.0h))));
            if (out2 < outside - 1e-5) { hist = h2; y = y2; outside = out2; have = true; }
        }
    }
    // Where it moved, the history as it is here too, if this frame agrees with that better (a
    // HUD over a moving scene). Not looked for where the moved history is already in range:
    // nothing can agree better than that.
    if (length(shift) > 0.5 && outside > 0.0) {
        const half4 still = history.read(at);
        if (fsr3Finite(float4(still))) {
            const half3 ys = fsr3YCoCgH(still.rgb);
            const float outsideStill = float(length(max(boxLo - ys, half3(0.0h)) + max(ys - boxHi, half3(0.0h))));
            if (outsideStill < outside - 1e-5) { hist = still; y = ys; have = true; trust = 1.0h; }
        }
    }
    if (have) {
        // Clipped towards the box's centre, keeping its hue where it can.
        const half3 mid = 0.5h * (boxLo + boxHi), extent = 0.5h * (boxHi - boxLo) + half3(1e-4h);
        const half3 v = y - mid;
        const half3 a = abs(v / extent);
        const half most = max(a.x, max(a.y, a.z));
        if (most > 1.0h) y = mid + v / most;

        const half cap = mix(half(blend.y), min(half(blend.y), 3.0h), quick);
        half fr = clamp(hist.a, 0.0h, cap);
        // A doubtful measurement shortens the history rather than ending it: the clip has
        // already pulled a wrong one into line, and an aliased edge always matches imperfectly.
        fr *= mix(0.25h, 1.0h, trust);
        fr *= saturate(1.5h - 0.5h * most);
        fr = min(fr + 1.0h, cap);
        const half alpha = 1.0h / fr;
        const half bright = half(blend.w);
        const half wc = alpha / (1.0h + bright * max(centre.x, 0.0h));
        const half wh = (1.0h - alpha) / (1.0h + bright * max(y.x, 0.0h));
        const half3 mixed = saturate(fsr3RGBH((centre * wc + y * wh) / max(wc + wh, 1e-3h)));
        if (fsr3Finite(float3(mixed))) { result = mixed; frames = fr; }
    }
    next.write(half4(result, frames), at);
    dst.write(float4(anvilCounterOver(float3(result), p, w, h, params), 1.0), at);
}

// =============================================================================
// Smooth Motion's frame between two (anvil_midpoint): the picture halfway between two real
// frames that have both been drawn — interpolated, not guessed ahead.
//
// Projected ahead from the last two frames (anvil_extrapolate), a made frame can only assume
// that motion carries on: where it turned, stopped or started, the made frame was wrong and the
// next real one stepped back — the judder of LEGO Star Wars' heavy scenes on 13 October. With
// both frames in hand, each pixel's motion can be checked: what the earlier frame shows half a
// step back along it and what the later one shows half a step on must be the same thing.
//
// Both frames are FSR 3's pictures as shown (its history, at the display's size), and the
// motion is FSR 3's, measured per 16x16 of the game's pixels from the later frame towards where
// each block was in the earlier one. A block's vector is wrong for part of it where something
// moves across what's behind it; there each pixel also tries the vector of the block it would
// have come from, its neighbours' and none at all (a HUD), and keeps the one the two frames
// agree on best. Where they agree on none — something uncovered or covered between the frames —
// the frame that shows it is taken alone: the one whose own motion there matches.
//
// Where the two frames don't agree along any motion over much of the picture — a reflection
// moving its own way over a floor, a heat haze rippling it, flames changing shape, motion too
// fast to follow — a made frame is two pictures at once, or one moved by a wrong vector: on
// Graphics Prep's scene (15 October) a heat haze broke into fragments and the lines under a
// reflection into dashes, the distortion seen in LEGO Star Wars at the game's own look. Trying
// more vectors per pixel (the pan, the neighbours') made the plain scene worse. So the frames are
// looked at first (anvil_midpoint_check, on FSR 3's luma planes).
//
// Where they disagree, the made frame is the nearer real frame there and nothing else (0.58): the
// check leaves a map of where, a value for every 4x4 of the planes it looks at, averaged over areas
// as the made frame reads it, and the made frame takes the real one's pixels where much of an area is apart,
// blended in as it grows, so flames, sparks and a reflection are shown as the game drew them and the
// rest of the picture — the camera's motion, the characters — still between. Until 0.57 any frame that disagreed over 4%
// of the picture was the nearer real frame whole, and LEGO Star Wars' heavy scenes (explosions,
// lightning, sparks: the worst frame of a stretch typically 39% apart) showed 17,608 of 27,682 made
// frames as a real one again on 17 October: the game's own rate there, with half a frame's latency
// for nothing. Whole now only where almost a third of the picture disagrees (anvil_midpoint_judge, for a
// few frames running) — a cut, a flash, the whole screen in flames — where a patchwork would be worse than
// the timing as it was.
//
// mid: x = the moment between the frames (0.5: halfway), y = 1 when `motionBefore` (the earlier
// frame's own motion) is there to check that frame's side against; z = test flags (16: the gate
// left out). game: xy = the game's frame size, which the motion is in pixels of; z = the game
// pixels each motion vector covers. params: the counter, as FSR's. gate: MidGate.
// =============================================================================

/// The made frames' gate, kept across frames: what the check counted this frame, and the judge's
/// verdict — `hold` 1 while the nearer real frame is shown instead. `held` and `judged` count up
/// for the presenter's stats; `share` is the last frame's share of the picture apart, `most` the
/// most since the presenter last read it (it sets it back to 0).
struct MidGate {
    atomic_uint looked;
    atomic_uint apart;
    float score;
    uint hold;
    uint judged;
    uint held;
    float share;
    float most;
    uint parted;      // made frames that took the nearer real frame's pixels where the two disagreed (0.58)
};

static inline float4 midMotion(texture2d<float, access::read> motion, float2 q, float2 toOut, int cell, int2 mlim)
{
    const int2 block = clamp(int2(floor(q / toOut)) / cell, int2(0), mlim);
    float4 m = motion.read(uint2(block));
    if (!fsr3Finite(m)) m = float4(0.0);
    m.xy *= toOut;
    m.w *= max(toOut.x, toOut.y);
    return m;
}

/// How far apart the two frames are along a motion: YCoCg, chroma at half weight, at the pixel
/// and four around it 1.5 pixels away diagonally — wide enough that one stripe of a repeating
/// pattern lined up with the next doesn't pass for a match.
static inline float midCost(texture2d<half, access::sample> before, texture2d<half, access::sample> after,
                            float2 a, float2 b, float2 inv)
{
    constexpr sampler lin(coord::normalized, filter::linear, address::clamp_to_edge);
    const float2 taps[5] = { float2(0.0), float2(1.5, 1.5), float2(-1.5, 1.5), float2(1.5, -1.5), float2(-1.5, -1.5) };
    float cost = 0.0;
    for (int i = 0; i < 5; ++i) {
        const half3 x = fsr3YCoCgH(before.sample(lin, (a + taps[i]) * inv).rgb);
        const half3 y = fsr3YCoCgH(after.sample(lin, (b + taps[i]) * inv).rgb);
        const half3 d = abs(x - y);
        cost += float(d.x) + 0.5 * float(d.y + d.z);
    }
    return cost * 0.2;
}

static inline float midLumaDiff(texture2d<half, access::sample> before, texture2d<half, access::sample> after,
                                float2 a, float2 b, float2 inv)
{
    constexpr sampler lin(coord::normalized, filter::linear, address::clamp_to_edge);
    const half3 x = fsr3YCoCgH(before.sample(lin, a * inv).rgb), y = fsr3YCoCgH(after.sample(lin, b * inv).rgb);
    const half3 d = abs(x - y);
    return float(d.x) + 0.5 * float(d.y + d.z);
}

kernel void anvil_midpoint(texture2d<half, access::sample>  before       [[texture(0)]],
                           texture2d<half, access::sample>  after        [[texture(1)]],
                           texture2d<float, access::read>   motion       [[texture(2)]],
                           texture2d<float, access::read>   motionBefore [[texture(3)]],
                           texture2d<float, access::write>  dst          [[texture(4)]],
                           texture2d<half, access::sample>  apartMap     [[texture(5)]],
                           constant float4&                 params       [[buffer(0)]],
                           constant float4&                 mid          [[buffer(1)]],
                           constant float4&                 game         [[buffer(2)]],
                           device const MidGate&            gate         [[buffer(3)]],
                           uint2 gid [[thread_position_in_grid]])
{
    const int w = int(dst.get_width()), h = int(dst.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) return;
    const float2 outSize = float2(w, h), inv = 1.0 / outSize;
    const float phase = clamp(mid.x, 0.0, 1.0);
    if (gate.hold != 0 && !(int(mid.z) & 16)) {
        // The frames disagree over too much of the picture: the nearer one, as it is.
        const half3 near = phase < 0.5 ? before.read(gid).rgb : after.read(gid).rgb;
        dst.write(float4(anvilCounterOver(float3(saturate(near)), int2(gid), w, h, params), 1.0), gid);
        return;
    }
    const float2 toOut = outSize / max(game.xy, float2(1.0));
    const int cell = max(int(game.z), 1);
    const int2 mlim = int2(motion.get_width(), motion.get_height()) - 1;
    const int2 blim = int2(motionBefore.get_width(), motionBefore.get_height()) - 1;
    const float2 p = float2(gid) + 0.5;
    const int dbg = int(mid.z);

    // Inside a block that moves with its neighbours, its motion: tried pixel by pixel against
    // others, a repeating pattern (a striped floor, rings) always lines up some wrong vector one
    // stripe on, and the pattern broke into a mosaic on Graphics Prep's scene.
    const float4 m0 = midMotion(motion, p, toOut, cell, mlim);
    float2 v = m0.xy;
    float best = 0.0;
    bool edge = m0.w > max(toOut.x, toOut.y);
    if (edge && !(dbg & 1)) {
        // Where blocks moving differently meet, one block's vector is wrong for part of it: each
        // pixel tries the vectors of the blocks beside it and the one where this vector puts it in
        // the later frame, over a patch, and keeps the one the two frames agree on best.
        float2 cand[6];
        int n = 0;
        cand[n++] = m0.xy;
        const float4 mr = midMotion(motion, p - (1.0 - phase) * m0.xy, toOut, cell, mlim);
        if (length(mr.xy - m0.xy) > 1.0) cand[n++] = mr.xy;
        const int2 block = clamp(int2(floor(p / toOut)) / cell, int2(0), mlim);
        const int2 beside[4] = { int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
        for (int i = 0; i < 4; ++i) {
            const float4 nb = motion.read(uint2(clamp(block + beside[i], int2(0), mlim)));
            if (!fsr3Finite(nb.xy)) continue;
            const float2 c = nb.xy * toOut;
            bool seen = false;
            for (int k = 0; k < n; ++k) seen = seen || length(cand[k] - c) <= 1.0;
            if (!seen) cand[n++] = c;
        }
        best = 1e30;
        for (int k = 0; k < n; ++k) {
            const float2 a = p + phase * cand[k], b = p - (1.0 - phase) * cand[k];
            const bool inA = all(a >= 0.0) && all(a <= outSize), inB = all(b >= 0.0) && all(b <= outSize);
            const float c = (inA && inB) ? midCost(before, after, a, b, inv) + (k == 0 ? 0.0 : 0.003)
                          : ((inA || inB) ? 0.06 : 1e20);
            if (c < best) { best = c; v = cand[k]; }
        }
    }
    // A HUD over a moving scene: the same here in both frames, and nothing like itself along the
    // scene's motion.
    if (length(v) > 0.5) {
        const float still = midLumaDiff(before, after, p, p, inv);
        if (still < 0.008 && midLumaDiff(before, after, p + phase * v, p - (1.0 - phase) * v, inv) > 0.06) {
            v = float2(0.0);
            edge = false;
        }
    }

    const float2 a = p + phase * v, b = p - (1.0 - phase) * v;
    const bool inA = all(a >= 0.0) && all(a <= outSize), inB = all(b >= 0.0) && all(b <= outSize);
    const half3 A = saturate(fsr3History(before, a * inv, outSize).rgb);
    const half3 B = saturate(fsr3History(after, b * inv, outSize).rgb);
    half3 result = mix(A, B, half(phase));
    if (inA != inB) {
        result = inA ? A : B;
    } else if (edge && best > 0.05 && !(dbg & 2)) {
        // Covered or uncovered between the frames: the side whose own motion there is this one.
        const float near = max(1.5, 0.15 * length(v));
        const bool okB = length(midMotion(motion, b, toOut, cell, mlim).xy - v) <= near;
        const bool okA = mid.y > 0.5 && length(midMotion(motionBefore, a, toOut, cell, blim).xy - v) <= near;
        if (okB && !okA) result = B;
        else if (okA && !okB) result = A;
    }
    // Where the two frames disagree over much of an area (the check's map averaged over 4x4 of its cells — 16x16 of the
    // planes' pixels, 32x32 of the game's at LEGO's sizes — in four filtered looks, each between four cells): the nearer
    // real frame, blended in as the share grows. A reflection moving its own way, a haze, flames — areas where much of
    // what the check looked at is apart — are the real frame; a lone pixel apart in an area that otherwise agrees isn't,
    // and the made frame stays. (Looked at cell by cell, the check's samples — one in sixteen — came out as scattered
    // spots that missed the broken parts between them: Graphics Prep's reflection, 17 October. Averaged through the
    // map's mip levels instead, the blit between the check and the made frames cost the stand-in 5% of its own frames.)
    if (!(dbg & 48)) {
        constexpr sampler lin(coord::normalized, filter::linear, address::clamp_to_edge);
        const float2 q = p * inv, o = 1.0 / float2(apartMap.get_width(), apartMap.get_height());
        const float d = 0.25 * (float(apartMap.sample(lin, q + o * float2(-1.0, -1.0)).r) + float(apartMap.sample(lin, q + o * float2(1.0, -1.0)).r)
                              + float(apartMap.sample(lin, q + o * float2(-1.0, 1.0)).r) + float(apartMap.sample(lin, q + o * float2(1.0, 1.0)).r));
        // A lone cell apart reaches at most a quarter of an area: from a fifth, several are.
        const float take = smoothstep(0.2, 0.45, d);
        if (take > 0.0) {
            const half3 near = saturate(phase < 0.5 ? before.read(gid).rgb : after.read(gid).rgb);
            result = mix(result, near, half(take));
        }
        if (dbg & 64) result = half3(half(take), result.g * 0.5h, result.b * 0.5h);
    }
    if (dbg & 4) result = half3(saturate(best * 10.0), (v.x != m0.x || v.y != m0.y) ? 1.0h : 0.0h, edge ? 0.5h : 0.0h);
    dst.write(float4(anvilCounterOver(float3(result), int2(gid), w, h, params), 1.0), gid);
}

/// The gate's look at two frames, on the luma planes FSR 3 matches motion on (the game's frames,
/// a plane pixel for every game.w of theirs each way): a plane pixel in 16 (the centre of each
/// 4x4, about one display pixel in 256), whether the two frames agree along its block's motion,
/// none (a HUD), or a neighbouring block's (midLumaCost).
/// Counted into `gate`; pixels whose motion leads off the picture (uncovered at its edge) aren't.
/// On the display-sized pictures, as anvil_midpoint looks, it took 1.0–1.3 ms a frame on an M4 at
/// LEGO's sizes, every look a cache line of its own; on the planes, a sixteenth of that.
/// rule: x = how far apart is apart. game: xy = the game's frame size, z = the game pixels each
/// motion vector covers, w = the game pixels each plane pixel covers.
static inline float midLumaCost(texture2d<float, access::sample> x, texture2d<float, access::sample> y,
                                float2 a, float2 b, float2 inv)
{
    // How far each frame's value lies outside the range of the other's 3x3 around where the motion puts it — a
    // hard edge a fraction of a pixel off in one frame stays inside it; something that moved its own way, warped
    // or changed doesn't. Taken straight (the difference of the two), a chequerboard's edges alone came to more
    // than 7% of Graphics Prep's plain scene, and every made frame of it was held.
    constexpr sampler lin(coord::normalized, filter::linear, address::clamp_to_edge);
    const float va = x.sample(lin, a * inv).r, vb = y.sample(lin, b * inv).r;
    float loA = va, hiA = va, loB = vb, hiB = vb;
    for (int j = -1; j <= 1; ++j) {
        for (int i = -1; i <= 1; ++i) {
            if (i == 0 && j == 0) continue;
            const float2 o = float2(i, j);
            const float sa = x.sample(lin, (a + o) * inv).r, sb = y.sample(lin, (b + o) * inv).r;
            loA = min(loA, sa); hiA = max(hiA, sa);
            loB = min(loB, sb); hiB = max(hiB, sb);
        }
    }
    const float outB = max(max(loB - va, va - hiB), 0.0), outA = max(max(loA - vb, vb - hiA), 0.0);
    const float cost = 0.5 * (outA + outB);
    return fsr3Finite(cost) ? cost : 1.0;
}

kernel void anvil_midpoint_check(texture2d<float, access::sample> before [[texture(0)]],
                                 texture2d<float, access::sample> after  [[texture(1)]],
                                 texture2d<float, access::read>   motion [[texture(2)]],
                                 texture2d<half, access::write>   apartMap [[texture(3)]],
                                 device MidGate&                  gate   [[buffer(0)]],
                                 constant float4&                 mid    [[buffer(1)]],
                                 constant float4&                 game   [[buffer(2)]],
                                 constant float4&                 rule   [[buffer(3)]],
                                 uint2 gid      [[thread_position_in_grid]],
                                 uint  simdLane [[thread_index_in_simdgroup]])
{
    const float2 size = float2(after.get_width(), after.get_height()), inv = 1.0 / size;
    const float S = max(game.w, 1.0);
    const float2 p = float2(gid) * 4.0 + 2.0;
    // Every thread reaches the sums below (a pixel off the plane, or leading off it, counts as nothing): a count
    // added up across the SIMD group first, then once into the gate.
    uint looked = 0u, apart = 0u;
    float far = 0.0;          // for the map: 0 where the frames agree, 1 where they're three times apart
    if (all(p < size)) {
        const float phase = clamp(mid.x, 0.0, 1.0);
        const int cell = max(int(game.z), 1);
        const int2 mlim = int2(motion.get_width(), motion.get_height()) - 1;
        const int2 block = clamp(int2(floor(p * S)) / cell, int2(0), mlim);
        float2 v = motion.read(uint2(block)).xy / S;
        if (!fsr3Finite(v)) v = float2(0.0);
        const float2 a = p + phase * v, b = p - (1.0 - phase) * v;
        if (all(a >= 0.0) && all(a <= size) && all(b >= 0.0) && all(b <= size)) {
            float best = midLumaCost(before, after, a, b, inv);
            if (best > rule.x) best = min(best, midLumaCost(before, after, p, p, inv));
            const int2 beside[4] = { int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
            for (int i = 0; i < 4 && best > rule.x; ++i) {
                float2 c = motion.read(uint2(clamp(block + beside[i], int2(0), mlim))).xy / S;
                if (!fsr3Finite(c)) continue;
                best = min(best, midLumaCost(before, after, p + phase * c, p - (1.0 - phase) * c, inv));
            }
            looked = 1u;
            apart = best > rule.x ? 1u : 0u;
            far = saturate((best - rule.x) / (2.0 * rule.x));
        }
    }
    if (gid.x < apartMap.get_width() && gid.y < apartMap.get_height()) apartMap.write(half4(half(far)), gid);
    const uint lookedAll = simd_sum(looked), apartAll = simd_sum(apart);
    if (simdLane == 0u) {
        if (lookedAll) atomic_fetch_add_explicit(&gate.looked, lookedAll, memory_order_relaxed);
        if (apartAll) atomic_fetch_add_explicit(&gate.apart, apartAll, memory_order_relaxed);
    }
}

/// The gate's verdict, one thread: this frame apart over more than rule.y of what was looked at
/// counts towards holding the nearer real frame whole; held from a score of 0.5 (two such frames
/// running), let go below 0.15 (several agreeing) — so Smooth Motion doesn't flicker on and off from
/// one frame to the next. Apart over more than rule.z, and not held: a made frame with the real one's
/// pixels where they disagree (counted). The counts start over for the next frame.
kernel void anvil_midpoint_judge(device MidGate&  gate [[buffer(0)]],
                                 constant float4& rule [[buffer(1)]],
                                 uint tid [[thread_position_in_grid]])
{
    if (tid != 0) return;
    const uint looked = atomic_load_explicit(&gate.looked, memory_order_relaxed);
    const uint apart = atomic_load_explicit(&gate.apart, memory_order_relaxed);
    const float share = looked > 0u ? float(apart) / float(looked) : 0.0;
    const bool bad = share > rule.y;
    gate.score = bad ? mix(gate.score, 1.0, 0.5) : mix(gate.score, 0.0, 0.15);
    if (gate.hold == 0u && gate.score > 0.5) gate.hold = 1u;
    else if (gate.hold != 0u && gate.score < 0.15) gate.hold = 0u;
    gate.judged += 1u;
    if (gate.hold != 0u) gate.held += 1u;
    else if (share > rule.z) gate.parted += 1u;
    gate.share = share;
    gate.most = max(gate.most, share);
    atomic_store_explicit(&gate.looked, 0u, memory_order_relaxed);
    atomic_store_explicit(&gate.apart, 0u, memory_order_relaxed);
}

// =============================================================================
// Smooth Motion at the lowest latency (0.69): the frame made ahead of the newest one.
//
// Frames between (anvil_midpoint) are made from the two newest real frames and shown between them, so each
// real frame waits half the game's frame to be shown: at 25 fps of the game's own, 20 ms more between what the
// player does and the screen — more the lower the frame rate, which was felt. Here the newest real frame is
// shown the moment it's done and the made one after it, the picture carried on along its motion by `reach`
// of a frame (0.5: to halfway towards the next real one), so no real frame waits for a made one.
//
// The motion is FSR 3's, in the newer frame's pixels and pointing back to where each was in the older one
// (as anvil_midpoint reads it): content at q in the newest frame moves on to q - reach*v, so the made pixel at
// p is the newest frame's at s = p + reach*v(s). Where blocks moving differently meet, each pixel tries the
// vectors around it and keeps the one that (1) the pixel it lands on in the newest frame moves with itself and
// (2) the older frame agrees with along that motion. Where none does — what a moving thing is about to uncover,
// which neither real frame shows — the newest frame's own pixel there, a moment behind rather than smeared.
// A HUD (the same in both frames, and nothing like itself along the motion) stays still. Where the check
// found the two frames apart over much of an area (flames, a reflection: anvil_midpoint_check's map), and
// whole when the judge holds, the newest frame as it is.
//
// ahead: x = reach (0.5), z = test flags (1: block motion only, 16: the gate left out, 32: the map left out,
// 64: the map shown). game, params, gate: as anvil_midpoint.
// =============================================================================
kernel void anvil_ahead(texture2d<half, access::sample>  before   [[texture(0)]],
                        texture2d<half, access::sample>  after    [[texture(1)]],
                        texture2d<float, access::read>   motion   [[texture(2)]],
                        texture2d<float, access::write>  dst      [[texture(4)]],
                        texture2d<half, access::sample>  apartMap [[texture(5)]],
                        constant float4&                 params   [[buffer(0)]],
                        constant float4&                 ahead    [[buffer(1)]],
                        constant float4&                 game     [[buffer(2)]],
                        device const MidGate&            gate     [[buffer(3)]],
                        uint2 gid [[thread_position_in_grid]])
{
    const int w = int(dst.get_width()), h = int(dst.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) return;
    const float2 outSize = float2(w, h), inv = 1.0 / outSize;
    const float reach = clamp(ahead.x, 0.0, 1.0);
    const int dbg = int(ahead.z);
    if (gate.hold != 0 && !(dbg & 16)) {
        dst.write(float4(anvilCounterOver(float3(saturate(after.read(gid).rgb)), int2(gid), w, h, params), 1.0), gid);
        return;
    }
    const float2 toOut = outSize / max(game.xy, float2(1.0));
    const int cell = max(int(game.z), 1);
    const int2 mlim = int2(motion.get_width(), motion.get_height()) - 1;
    const float2 p = float2(gid) + 0.5;
    const float blockPx = max(toOut.x, toOut.y);

    // The vector at p, then at where it lands: one step of s = p + reach*v(s).
    const float4 m0 = midMotion(motion, p, toOut, cell, mlim);
    const float4 m1 = midMotion(motion, p + reach * m0.xy, toOut, cell, mlim);
    float2 v = m1.xy;
    bool sure = true;
    const bool edge = m0.w > blockPx || m1.w > blockPx || length(m1.xy - m0.xy) > 1.0;
    if (edge && !(dbg & 1)) {
        float2 cand[7];
        int n = 0;
        cand[n++] = m1.xy;
        if (length(m0.xy - m1.xy) > 1.0) cand[n++] = m0.xy;
        const int2 block = clamp(int2(floor(p / toOut)) / cell, int2(0), mlim);
        const int2 beside[4] = { int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
        for (int i = 0; i < 4; ++i) {
            const float4 nb = motion.read(uint2(clamp(block + beside[i], int2(0), mlim)));
            if (!fsr3Finite(nb.xy)) continue;
            const float2 c = nb.xy * toOut;
            bool seen = false;
            for (int k = 0; k < n; ++k) seen = seen || length(cand[k] - c) <= 1.0;
            if (!seen) cand[n++] = c;
        }
        float best = 1e30;
        bool bestOwn = false;
        for (int k = 0; k < n; ++k) {
            const float2 s = p + reach * cand[k], a = s + cand[k];
            const bool inS = all(s >= 0.0) && all(s <= outSize), inA = all(a >= 0.0) && all(a <= outSize);
            if (!inS) continue;
            // (1) what it lands on moves this way itself
            const float near = max(1.5, 0.15 * length(cand[k]));
            const bool own = length(midMotion(motion, s, toOut, cell, mlim).xy - cand[k]) <= near;
            // (2) the older frame agrees along it
            const float c = (inA ? midCost(before, after, a, s, inv) : 0.06) + (own ? 0.0 : 0.05) + (k == 0 ? 0.0 : 0.003);
            if (c < best) { best = c; v = cand[k]; bestOwn = own; }
        }
        sure = bestOwn && best < 0.08;
    }
    // A HUD over a moving scene.
    if (length(v) > 0.5) {
        const float still = midLumaDiff(before, after, p, p, inv);
        if (still < 0.008 && midLumaDiff(before, after, p + v, p, inv) > 0.06) { v = float2(0.0); sure = true; }
    }
    // Carried no further than 48 display pixels for certain: past that a turn of the camera costs most.
    const float carried = reach * length(v);
    const float trust = sure ? saturate(1.0 - max(0.0, carried - 48.0) / 48.0) : 0.0;
    const float2 s = p + trust * reach * v;
    const bool inS = all(s >= 0.0) && all(s <= outSize);
    half3 result = inS ? saturate(fsr3History(after, s * inv, outSize).rgb) : saturate(after.read(gid).rgb);
    if (!(dbg & 48)) {
        constexpr sampler lin(coord::normalized, filter::linear, address::clamp_to_edge);
        const float2 q = p * inv, o = 1.0 / float2(apartMap.get_width(), apartMap.get_height());
        const float d = 0.25 * (float(apartMap.sample(lin, q + o * float2(-1.0, -1.0)).r) + float(apartMap.sample(lin, q + o * float2(1.0, -1.0)).r)
                              + float(apartMap.sample(lin, q + o * float2(-1.0, 1.0)).r) + float(apartMap.sample(lin, q + o * float2(1.0, 1.0)).r));
        const float take = smoothstep(0.2, 0.45, d);
        if (take > 0.0) result = mix(result, saturate(after.read(gid).rgb), half(take));
        if (dbg & 64) result = half3(half(take), result.g * 0.5h, result.b * 0.5h);
    }
    dst.write(float4(anvilCounterOver(float3(result), int2(gid), w, h, params), 1.0), gid);
}

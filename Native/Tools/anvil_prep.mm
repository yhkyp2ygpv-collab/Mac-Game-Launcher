// anvil-prep — Graphics Prep's work, in a process of its own so that nothing it does can
// take Anvil or a game down with it.
//
//   anvil-prep prepare <archive> <game WxH> <shown WxH> <pixel format> [sharpness] [aa]
//       Compiles Anvil's shaders (from where ANVIL_METALLIB / ANVIL_METAL_SOURCE /
//       ANVIL_METAL_PACK say, exactly as libanvil does), writes every pipeline into a Metal
//       binary archive at <archive>, then runs FSR on the GPU at the game's sizes and in its
//       format: a flat colour must come out as it went in, the one-pass version must give the
//       two-pass version's picture, and both are timed. The quicker is reported. Then FSR 3
//       for every game (Anvil's temporal pass, then FSR 1) runs on a moving test scene at the
//       same sizes, against FSR 1 alone and a supersampled reference of the same scene: it is
//       kept for the game only if it comes out closer to the reference, with nothing broken.
//       "aa": the game smooths its own edges over time (its own temporal AA), so the scene is
//       drawn anti-aliased, as such a game hands its frames over, and FSR 3 blends at most
//       kAnvilFSR3FramesGameAA of them, as it then will in the game.
//   anvil-prep verify <archive>
//       Compiles the library again and makes every pipeline from <archive>, failing on a miss —
//       run under Rosetta, as the game is, it shows the game will find them.
//
// One JSON object per line on stdout, as each step finishes; the last is "done", "verified"
// or "failed". Manual retain/release, like the shader code it shares (anvil_shaderset.mm).
#include "../AnvilMetal/anvil_shaderset.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#include <simd/simd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include <algorithm>
#include <vector>

static void emit(NSDictionary* object) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void note(const char* format, ...) {
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
    fputc('\n', stderr);
}

static int fail(NSString* why) {
    emit(@{@"event": @"failed", @"why": why});
    return 3;
}

static const char* arch() {
#if defined(__x86_64__)
    return "x86_64";
#else
    return "arm64";
#endif
}

// --- The game's format ------------------------------------------------------------------

/// FSR to the display works on an sRGB frame through a plain view of it (libanvil's rawView),
/// so the plain format is the one that is measured.
static MTLPixelFormat plainFormat(NSUInteger f) {
    switch (f) {
        case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: return MTLPixelFormatRGBA8Unorm;
        case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB: return MTLPixelFormatBGRA8Unorm;
        case MTLPixelFormatRGB10A2Unorm: return MTLPixelFormatRGB10A2Unorm;
        case MTLPixelFormatBGR10A2Unorm: return MTLPixelFormatBGR10A2Unorm;
        case MTLPixelFormatRGBA16Float: return MTLPixelFormatRGBA16Float;
        default: return MTLPixelFormatInvalid;
    }
}

static size_t bytesPerPixel(MTLPixelFormat f) { return f == MTLPixelFormatRGBA16Float ? 8 : 4; }

static void packPixel(MTLPixelFormat f, uint8_t* p, float r, float g, float b) {
    auto q8 = [](float v) { return (uint8_t)lrintf(std::clamp(v, 0.0f, 1.0f) * 255.0f); };
    auto q10 = [](float v) { return (uint32_t)lrintf(std::clamp(v, 0.0f, 1.0f) * 1023.0f); };
    switch (f) {
        case MTLPixelFormatRGBA8Unorm: p[0] = q8(r); p[1] = q8(g); p[2] = q8(b); p[3] = 255; break;
        case MTLPixelFormatBGRA8Unorm: p[0] = q8(b); p[1] = q8(g); p[2] = q8(r); p[3] = 255; break;
        case MTLPixelFormatRGB10A2Unorm: { uint32_t v = q10(r) | q10(g) << 10 | q10(b) << 20 | 3u << 30; memcpy(p, &v, 4); break; }
        case MTLPixelFormatBGR10A2Unorm: { uint32_t v = q10(b) | q10(g) << 10 | q10(r) << 20 | 3u << 30; memcpy(p, &v, 4); break; }
        case MTLPixelFormatRGBA16Float: { __fp16 h[4] = {(__fp16)r, (__fp16)g, (__fp16)b, (__fp16)1.0f}; memcpy(p, h, 8); break; }
        default: break;
    }
}

static simd_float3 unpackPixel(MTLPixelFormat f, const uint8_t* p) {
    switch (f) {
        case MTLPixelFormatRGBA8Unorm: return simd_make_float3(p[0], p[1], p[2]) / 255.0f;
        case MTLPixelFormatBGRA8Unorm: return simd_make_float3(p[2], p[1], p[0]) / 255.0f;
        case MTLPixelFormatRGB10A2Unorm: { uint32_t v; memcpy(&v, p, 4); return simd_make_float3(v & 1023, (v >> 10) & 1023, (v >> 20) & 1023) / 1023.0f; }
        case MTLPixelFormatBGR10A2Unorm: { uint32_t v; memcpy(&v, p, 4); return simd_make_float3((v >> 20) & 1023, (v >> 10) & 1023, v & 1023) / 1023.0f; }
        case MTLPixelFormatRGBA16Float: { __fp16 h[4]; memcpy(h, p, 8); return simd_make_float3(h[0], h[1], h[2]); }
        default: return simd_make_float3(0, 0, 0);
    }
}

static id<MTLTexture> privateTexture(id<MTLDevice> device, MTLPixelFormat f, NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    d.storageMode = MTLStorageModePrivate;
    return [device newTextureWithDescriptor:d];
}

/// A frame like a game's — gradients, hard edges, thin lines and grain — or one flat colour.
static void fill(id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLTexture> texture, bool flat) {
    const NSUInteger w = texture.width, h = texture.height;
    const size_t bpp = bytesPerPixel(texture.pixelFormat);
    id<MTLBuffer> staging = [device newBufferWithLength:w * h * bpp options:MTLResourceStorageModeShared];
    uint8_t* px = (uint8_t*)staging.contents;
    uint32_t seed = 12345;
    for (NSUInteger y = 0; y < h; y++) for (NSUInteger x = 0; x < w; x++) {
        float r = 200 / 255.0f, g = 60 / 255.0f, b = 40 / 255.0f;
        if (!flat) {
            seed = seed * 1664525u + 1013904223u;
            const float n = ((seed >> 24) & 31) / 255.0f;
            const bool edge = ((x / 37) + (y / 23)) & 1;
            const bool line = (x % 61) < 2 || ((x + y) % 97) < 2;
            r = (float)x / w * 0.5f + (edge ? 0.35f : 0.04f) + n;
            g = (float)y / h * 0.5f + (line ? 0.63f : 0.12f) + n;
            b = 0.24f + (edge ? 0.47f : 0.0f) + n;
        }
        packPixel(texture.pixelFormat, px + (y * w + x) * bpp, std::min(r, 1.0f), std::min(g, 1.0f), std::min(b, 1.0f));
    }
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromBuffer:staging sourceOffset:0 sourceBytesPerRow:w * bpp sourceBytesPerImage:w * h * bpp
              sourceSize:MTLSizeMake(w, h, 1) toTexture:texture destinationSlice:0 destinationLevel:0
       destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    [staging release];
}

static id<MTLBuffer> readBack(id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLTexture> texture) {
    const NSUInteger w = texture.width, h = texture.height;
    const size_t bpp = bytesPerPixel(texture.pixelFormat);
    id<MTLBuffer> buffer = [device newBufferWithLength:w * h * bpp options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(w, h, 1) toBuffer:buffer destinationOffset:0
   destinationBytesPerRow:w * bpp destinationBytesPerImage:w * h * bpp];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return buffer;
}

static bool parseSize(const char* text, NSUInteger* w, NSUInteger* h) {
    unsigned a = 0, b = 0;
    if (sscanf(text, "%ux%u", &a, &b) != 2 || a < 16 || b < 16 || a > 16384 || b > 16384) return false;
    *w = a; *h = b;
    return true;
}

// --- FSR 3's test scene ----------------------------------------------------------------------

// Compiled here, not shipped in Anvil's shader library: it is only ever drawn by this test.
static const char* const kSceneSource = R"MSL(
#include <metal_stdlib>
using namespace metal;

struct Scene { float2 camera; float2 sprite; float2 scale; float2 shown; float samples; float band; float2 pad; };

static float wrap(float x, float m) { return x - m * floor(x / m); }

// Value noise for the natural variant: irregular, like most of a game's surfaces.
static float hash2(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static float vnoise(float2 p) {
    const float2 i = floor(p), f = p - i, u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash2(i), hash2(i + float2(1, 0)), u.x), mix(hash2(i + float2(0, 1)), hash2(i + float2(1, 1)), u.x), u.y);
}

// The test picture at screen position s, in the shown frame's pixels: a world that moves with
// the camera — a turned chequerboard, lines 1.2 and 1.6 pixels wide, a band of fine stripes, a
// soft gradient — a disc that moves on its own, and a HUD panel of text-like strokes that
// doesn't move. Drawn with one sample per pixel at the game's size it aliases as a game does
// without anti-aliasing; with 4x4 per pixel at the shown size it is the reference.
static float3 scenePixel(float2 s, constant Scene& sc) {
    const float2 hq = s - float2(0.04, 0.05) * sc.shown;
    if (all(hq >= 0.0) && all(hq < float2(0.11, 0.045) * sc.shown)) {
        const bool stroke = wrap(floor(hq.x / 5.0), 3.0) < 2.0 && wrap(hq.y, 22.0) > 8.0 && wrap(hq.y, 22.0) < 18.0;
        return stroke ? float3(1.0, 0.95, 0.85) : float3(0.07, 0.09, 0.13);
    }
    const float r = length(s - sc.sprite);
    if (r < 0.045 * sc.shown.x) return wrap(r, 16.0) < 8.0 ? float3(0.95, 0.25, 0.1) : float3(1.0, 0.85, 0.25);
    // What a game's heavy scenes have and the plain scene doesn't (development only, ANVIL_PREP_HARD, bits):
    // 4, sparks flying fast each their own way; 2, a heat haze that ripples the picture behind it differently
    // every frame; 1, a reflection over the lower third that moves its own way, as a floor's does; 8, landmarks
    // over the repeating floor (below).
    const int hard = int(sc.pad.y + 0.5);
    if (hard & 4) {
        for (int i = 0; i < 48; ++i) {
            const float2 base = float2(hash2(float2(i, 1.7)), hash2(float2(i, 9.3))) * sc.shown;
            const float2 vel = (float2(hash2(float2(i, 4.1)), hash2(float2(i, 6.6))) - 0.5) * 6.0;
            const float2 at = float2(wrap(base.x + vel.x * sc.camera.x, sc.shown.x), wrap(base.y + vel.y * sc.camera.x, sc.shown.y));
            if (length(s - at) < 3.5) return float3(1.0, 0.82, 0.45);
        }
    }
    float2 w = s + sc.camera;
    if (hard & 2) {
        const float2 hc = float2(0.68, 0.32) * sc.shown;
        const float hr = 0.11 * sc.shown.x, d = length(s - hc);
        if (d < hr) w += 7.0 * (1.0 - d / hr) * float2(sin(s.y * 0.09 + sc.camera.x * 0.9), cos(s.x * 0.08 + sc.camera.x * 1.3));
    }
    const float a = 0.12;
    const float2 t = float2(cos(a) * w.x - sin(a) * w.y, sin(a) * w.x + cos(a) * w.y);
    const bool odd = ((int(floor(t.x / 23.0)) + int(floor(t.y / 23.0))) & 1) != 0;
    float3 c = odd ? float3(0.82, 0.83, 0.78) : float3(0.16, 0.2, 0.26);
    if (sc.pad.x > 0.5) {
        // Natural (development only): irregular texture at four scales in place of the chequerboard.
        const float n = 0.45 * vnoise(w / 64.0) + 0.3 * vnoise(w / 23.0) + 0.17 * vnoise(w / 8.5) + 0.08 * vnoise(w / 3.2);
        c = mix(float3(0.12, 0.14, 0.18), float3(0.86, 0.8, 0.66), saturate(1.6 * n - 0.3));
    }
    if (abs(wrap(w.x * 0.8 + w.y * 0.6, 61.0) - 30.5) > 29.7) c = float3(0.15, 0.85, 0.35);
    if (abs(wrap(w.x * 0.28 - w.y * 0.96, 97.0) - 48.5) > 47.9) c = float3(0.9, 0.3, 0.6);
    const float band = wrap(w.y, 900.0);
    if (sc.band > 0.5 && band > 600.0 && band < 760.0) c *= 0.55 + 0.45 * step(0.0, sin(w.x * 0.85));
    // 8: what a game's repeating floor has around it — light and shade over it at a large scale, and a few
    // big shapes (pillars, crates) — moving with it: the pattern repeats, the picture as a whole doesn't.
    if (hard & 8) {
        c *= 0.7 + 0.6 * vnoise(w / 220.0);
        const float2 cell = floor(w / 400.0);
        const float2 inCell = w - cell * 400.0;
        if (hash2(cell) > 0.45 && all(abs(inCell - 200.0) < float2(40.0 + 50.0 * hash2(cell + 3.1), 70.0)))
            c = mix(float3(0.55, 0.32, 0.18), float3(0.25, 0.4, 0.62), hash2(cell + 7.7)) * (0.8 + 0.2 * (inCell.y / 400.0));
    }
    if ((hard & 1) && s.y > 0.62 * sc.shown.y) {
        const float2 rf = float2(s.x + 0.4 * sc.camera.x, 1.24 * sc.shown.y - s.y - 1.6 * sc.camera.y);
        const float lamp = smoothstep(0.55, 0.75, vnoise(rf / 40.0));
        const float bars = step(0.5, fract(rf.x / 37.0)) * step(0.7, fract(rf.y / 53.0));
        c = mix(c, float3(0.95, 0.9, 0.7), 0.45 * max(lamp, bars));
    }
    return c * (0.72 + 0.28 * s.y / sc.shown.y);
}

kernel void prep_scene(texture2d<float, access::write> dst [[texture(0)]],
                       constant Scene& sc [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    const int n = max(int(sc.samples), 1);
    float3 sum = 0.0;
    for (int j = 0; j < n; ++j)
        for (int i = 0; i < n; ++i)
            sum += scenePixel((float2(gid) + (float2(i, j) + 0.5) / float(n)) * sc.scale, sc);
    dst.write(float4(sum / float(n * n), 1.0), gid);
}

// Per 256 pixels of a row: x = |out - ref|, y = |(out - outBefore) - (ref - refBefore)| (the
// change from the frame before that the reference doesn't have: flicker), each the mean of
// red, green and blue; z = pixels that aren't numbers; w = x within `near` of the disc.
struct Truth { float2 cameraStep; float2 sprite; float2 spriteStep; float2 scale; float2 shown; float cell; float pad; };
// The scene's true motion per block of `cell` game pixels, as anvil_fsr3_motion reports it.
kernel void prep_truth(texture2d<float, access::write> motion [[texture(0)]],
                       constant Truth& tr [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= motion.get_width() || gid.y >= motion.get_height()) return;
    const float2 s = (float2(gid) + 0.5) * tr.cell * tr.scale;
    const float2 hq = s - float2(0.04, 0.05) * tr.shown;
    float2 v = tr.cameraStep;
    if (all(hq >= 0.0) && all(hq < float2(0.11, 0.045) * tr.shown)) v = 0.0;
    else if (length(s - tr.sprite) < 0.045 * tr.shown.x) v = -tr.spriteStep;
    motion.write(float4(v / tr.scale, 1.0, 0.0), gid);
}

struct Compare { float2 sprite; float near; float pad; };
kernel void prep_compare(texture2d<float, access::read> outNow    [[texture(0)]],
                         texture2d<float, access::read> refNow    [[texture(1)]],
                         texture2d<float, access::read> outBefore [[texture(2)]],
                         texture2d<float, access::read> refBefore [[texture(3)]],
                         device float4* sums [[buffer(0)]],
                         constant Compare& cp [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    const uint w = outNow.get_width(), h = outNow.get_height();
    const uint segments = (w + 255) / 256;
    if (gid.x >= segments || gid.y >= h) return;
    float4 acc = 0.0;
    for (uint x = gid.x * 256; x < min(w, gid.x * 256 + 256); ++x) {
        const uint2 p = uint2(x, gid.y);
        const float3 o = outNow.read(p).rgb, r = refNow.read(p).rgb;
        if (!all(isfinite(o))) { acc.z += 1.0; continue; }
        const float e = (abs(o.r - r.r) + abs(o.g - r.g) + abs(o.b - r.b)) / 3.0;
        const float3 d = (o - outBefore.read(p).rgb) - (r - refBefore.read(p).rgb);
        acc.x += e;
        acc.y += (abs(d.r) + abs(d.g) + abs(d.b)) / 3.0;
        // cp.pad > 0 (ANVIL_PREP_BAD): pixels further than that from the reference, counted.
        if (cp.pad > 0.0) acc.w += e > cp.pad ? 1.0 : 0.0;
        else if (length(float2(p) - cp.sprite) < cp.near) acc.w += e;
    }
    sums[gid.y * segments + gid.x] = acc;
}
)MSL";

struct SceneParams { simd_float2 camera, sprite, scale, shown; float samples, band; float pad[2]; };
struct CompareParams { simd_float2 sprite; float near; float pad; };
struct TruthParams { simd_float2 cameraStep, sprite, spriteStep, scale, shown; float cell, pad; };

/// A texture as a PNG, for looking at what the test made (ANVIL_PREP_DUMP).
static void dumpPNG(id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLTexture> t, NSString* path) {
    id<MTLBuffer> back = [device newBufferWithLength:t.width * t.height * (t.pixelFormat == MTLPixelFormatRGBA16Float ? 8 : 4)
                                             options:MTLResourceStorageModeShared];
    const size_t bpp = t.pixelFormat == MTLPixelFormatRGBA16Float ? 8 : 4;
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:back destinationOffset:0
   destinationBytesPerRow:t.width * bpp destinationBytesPerImage:t.width * t.height * bpp];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    std::vector<uint8_t> rgba(t.width * t.height * 4);
    for (NSUInteger i = 0; i < t.width * t.height; i++) {
        simd_float3 c;
        if (t.pixelFormat == MTLPixelFormatRGBA16Float) { __fp16 h[4]; memcpy(h, (uint8_t*)back.contents + i * 8, 8); c = simd_make_float3(h[0], h[1], h[2]); }
        else if (t.pixelFormat == MTLPixelFormatBGRA8Unorm) { const uint8_t* q = (uint8_t*)back.contents + i * 4; c = simd_make_float3(q[2], q[1], q[0]) / 255.0f; }
        else if (t.pixelFormat == MTLPixelFormatRGBA8Unorm) { const uint8_t* q = (uint8_t*)back.contents + i * 4; c = simd_make_float3(q[0], q[1], q[2]) / 255.0f; }
        else { uint32_t v; memcpy(&v, (uint8_t*)back.contents + i * 4, 4);
               c = t.pixelFormat == MTLPixelFormatBGR10A2Unorm ? simd_make_float3((v >> 20) & 1023, (v >> 10) & 1023, v & 1023) / 1023.0f
                                                               : simd_make_float3(v & 1023, (v >> 10) & 1023, (v >> 20) & 1023) / 1023.0f; }
        for (int k = 0; k < 3; k++) rgba[i * 4 + k] = (uint8_t)lrintf(std::clamp(c[k], 0.0f, 1.0f) * 255.0f);
        rgba[i * 4 + 3] = 255;
    }
    [back release];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(rgba.data(), t.width, t.height, 8, t.width * 4, space, kCGImageAlphaPremultipliedLast);
    CGImageRef whole = CGBitmapContextCreateImage(ctx);
    CGImageRef image = whole;
    // A part of it, as fractions of the frame: ANVIL_PREP_CROP=x,y,w,h.
    float cx = 0, cy = 0, cw = 1, ch = 1;
    if (const char* crop = getenv("ANVIL_PREP_CROP")) sscanf(crop, "%f,%f,%f,%f", &cx, &cy, &cw, &ch);
    if (whole && (cw < 1 || ch < 1)) {
        image = CGImageCreateWithImageInRect(whole, CGRectMake(floor(cx * t.width), floor(cy * t.height), floor(cw * t.width), floor(ch * t.height)));
        CGImageRelease(whole);
    }
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    if (dest && image) { CGImageDestinationAddImage(dest, image, NULL); CGImageDestinationFinalize(dest); }
    if (dest) CFRelease(dest);
    if (image) CGImageRelease(image);
    CGContextRelease(ctx);
    CGColorSpaceRelease(space);
}

/// FSR 3 for every game at the game's sizes and in its format: the moving test scene through
/// it and through FSR 1 alone, both against the reference, then both timed. The results go
/// into "done"; `fsr3` is whether the game gets it.
static NSDictionary* testFSR3(id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLLibrary> library,
                              id<MTLBinaryArchive> archive, MTLPixelFormat format,
                              NSUInteger gw, NSUInteger gh, NSUInteger sw, NSUInteger sh, float sharpness,
                              id<MTLComputePipelineState> easu, id<MTLComputePipelineState> finish,
                              id<MTLComputePipelineState> fused, MTLSize shape, int fsr1Pass, bool gameAA) {
    auto refuse = [](NSString* why) { return @{@"fsr3": @NO, @"fsr3_why": why}; };
    const bool native = gw == sw && gh == sh;
    bool fromArchive = false;
    AnvilFSR3 st = {};
    st.luma = AnvilPipeline(device, library, kAnvilFsr3Luma, archive, &fromArchive);
    st.flow = AnvilPipeline(device, library, kAnvilOpticalFlow, archive, &fromArchive);
    st.motion = AnvilPipeline(device, library, kAnvilFsr3Motion, archive, &fromArchive);
    st.settle = AnvilPipeline(device, library, kAnvilFsr3Settle, archive, &fromArchive);
    if (!getenv("ANVIL_PREP_NO_WIDE")) st.widen = AnvilPipeline(device, library, kAnvilFsr3Wide, archive, &fromArchive);
    // The pan (0.54): left out with ANVIL_PREP_NO_PAN (development only), to compare.
    if (!getenv("ANVIL_PREP_NO_PAN")) {
        st.panCost = AnvilPipeline(device, library, kAnvilFsr3PanCost, archive, &fromArchive);
        st.panPick = AnvilPipeline(device, library, kAnvilFsr3PanPick, archive, &fromArchive);
        st.panFineCost = AnvilPipeline(device, library, kAnvilFsr3PanFineCost, archive, &fromArchive);
        st.panFinePick = AnvilPipeline(device, library, kAnvilFsr3PanFinePick, archive, &fromArchive);
    }
    if (gameAA) st.maxFrames = kAnvilFSR3FramesGameAA;
    // Graphics Prep's own trials of the blend (development only).
    if (const char* v = getenv("ANVIL_PREP_FSR3_FRAMES")) st.maxFrames = atof(v);
    if (const char* v = getenv("ANVIL_PREP_FSR3_CLIP")) st.clip = atof(v);
    if (const char* v = getenv("ANVIL_PREP_FSR3_AGREE")) st.agree = atof(v);
    if (const char* v = getenv("ANVIL_PREP_FSR3_PRIOR")) st.prior = atof(v);
    if (const char* v = getenv("ANVIL_PREP_FSR3_BRIGHT")) st.bright = atof(v);
    if (const char* v = getenv("ANVIL_PREP_FSR3_SCALE")) st.askScale = atoi(v);
    float nativeShare = 0.5f;
    if (const char* v = getenv("ANVIL_PREP_NATIVE_SHARPEN")) nativeShare = atof(v);

    st.resolve = AnvilPipeline(device, library, kAnvilFsr3Resolve, archive, &fromArchive);
    if (const char* v = getenv("ANVIL_PREP_RESOLVE")) {
        // A variant of the resolve pass, by name, from the library given (development only).
        id<MTLFunction> fn = [library newFunctionWithName:@(v)];
        NSError* e = nil;
        id<MTLComputePipelineState> variant = fn ? [device newComputePipelineStateWithFunction:fn error:&e] : nil;
        [fn release];
        if (variant) { [st.resolve release]; st.resolve = variant; }
        else note("no resolve variant %s", v);
    }
    if (const char* v = getenv("ANVIL_PREP_FSR3_TILE")) {
        unsigned tw = 0, th = 0;
        if (sscanf(v, "%ux%u", &tw, &th) == 2) st.shape = AnvilFusedShape(st.resolve, device, MTLSizeMake(tw, th, 1));
    }
    if (getenv("ANVIL_PREP_DEBUG") && st.resolve)
        note("resolve pipeline: %lu threads a group at most, SIMD %lu, %lu bytes of its own threadgroup memory",
             (unsigned long)st.resolve.maxTotalThreadsPerThreadgroup, (unsigned long)st.resolve.threadExecutionWidth,
             (unsigned long)st.resolve.staticThreadgroupMemoryLength);
    struct Cleanup { AnvilFSR3* s; ~Cleanup() { AnvilFSR3Free(s); [s->luma release]; [s->flow release]; [s->motion release]; [s->settle release]; [s->resolve release]; [s->widen release]; [s->panCost release]; [s->panPick release]; [s->panFineCost release]; [s->panFinePick release]; } } cleanup{&st};
    if (!st.luma || !st.flow || !st.motion || !st.settle || !st.resolve) return refuse(@"FSR 3's pipelines didn't build");
    if (!AnvilFSR3Ensure(&st, device, gw, gh, sw, sh)) return refuse(@"the GPU hadn't room for FSR 3's textures at this size");

    NSError* error = nil;
    MTLCompileOptions* opts = [[MTLCompileOptions alloc] init];
    id<MTLLibrary> sceneLib = [device newLibraryWithSource:@(kSceneSource) options:opts error:&error];
    [opts release];
    if (!sceneLib) return refuse([NSString stringWithFormat:@"the test scene didn't compile: %@", error.localizedDescription]);
    id<MTLFunction> sceneFn = [sceneLib newFunctionWithName:@"prep_scene"];
    id<MTLFunction> compareFn = [sceneLib newFunctionWithName:@"prep_compare"];
    id<MTLFunction> truthFn = [sceneLib newFunctionWithName:@"prep_truth"];
    id<MTLComputePipelineState> truth = truthFn ? [device newComputePipelineStateWithFunction:truthFn error:&error] : nil;
    [truthFn autorelease];
    [truth autorelease];
    const bool oracle = getenv("ANVIL_PREP_TRUE_MOTION") != nullptr;
    id<MTLComputePipelineState> scene = sceneFn ? [device newComputePipelineStateWithFunction:sceneFn error:&error] : nil;
    id<MTLComputePipelineState> compare = compareFn ? [device newComputePipelineStateWithFunction:compareFn error:&error] : nil;
    [sceneFn release]; [compareFn release]; [sceneLib release];
    if (!scene || !compare) { [scene release]; [compare release]; return refuse(@"the test scene's pipelines didn't build"); }

    id<MTLTexture> frame = privateTexture(device, format, gw, gh);
    id<MTLTexture> scratch = privateTexture(device, format, sw, sh);
    id<MTLTexture> out1 = privateTexture(device, format, sw, sh), out1Before = privateTexture(device, format, sw, sh);
    id<MTLTexture> out3 = privateTexture(device, format, sw, sh), out3Before = privateTexture(device, format, sw, sh);
    id<MTLTexture> ref = privateTexture(device, MTLPixelFormatRGBA16Float, sw, sh), refBefore = privateTexture(device, MTLPixelFormatRGBA16Float, sw, sh);
    NSArray* owned = @[];
    if (frame && scratch && out1 && out1Before && out3 && out3Before && ref && refBefore)
        owned = @[frame, scratch, out1, out1Before, out3, out3Before, ref, refBefore];
    [frame release]; [scratch release]; [out1 release]; [out1Before release]; [out3 release]; [out3Before release]; [ref release]; [refBefore release];
    if (owned.count != 8) { [scene release]; [compare release]; return refuse(@"the GPU hadn't room for the test frames"); }

    const NSUInteger segments = (sw + 255) / 256;
    id<MTLBuffer> sums = [device newBufferWithLength:segments * sh * sizeof(simd_float4) options:MTLResourceStorageModeShared];
    const simd_float4 params = {sharpness, 0.0f, 1.0f, -1.0f};
    // At the display's own size there's nothing to upscale: the game's frame is shown as it is,
    // and FSR 3 is the temporal pass and RCAS alone.
    const simd_float4 nativeParams = {sharpness * nativeShare, 0.0f, 1.0f, -1.0f};
    const char* dump = getenv("ANVIL_PREP_DUMP");

    // How fast it moves (development only): 1 is the shipped test, a camera at 5.3 by 2.1 shown
    // pixels a frame and the disc at 7.7; a game's fast scenes go five to ten times that.
    float speed = 1.0f;
    if (const char* v = getenv("ANVIL_PREP_SPEED")) speed = std::clamp((float)atof(v), 0.1f, 20.0f);
    // ANVIL_PREP_RAMP=n (development only): the camera reaches its speed over n frames from still, as a game's does,
    // rather than at once.
    const float ramp = getenv("ANVIL_PREP_RAMP") ? std::max(0.0f, (float)atof(getenv("ANVIL_PREP_RAMP"))) : 0.0f;
    auto sceneAt = [&](float t, simd_float2* camera, simd_float2* sprite) {
        const float moving = std::min(t, 23.0f);      // still from frame 24 on
        const float travelled = ramp <= 0.0f ? moving : (moving < ramp ? moving * moving / (2.0f * ramp) : moving - ramp / 2.0f);
        *camera = simd_make_float2(5.3f, 2.1f) * travelled * speed;
        *sprite = simd_make_float2(0.3f * sw + 7.7f * moving * std::min(speed, 4.0f),
                                   0.55f * sh + 60.0f * std::min(speed, 4.0f) * sinf(moving * 0.37f));
    };
    auto draw = [&](id<MTLComputeCommandEncoder> enc, id<MTLTexture> dst, float t, int samples) {
        SceneParams sp = {};
        sceneAt(t, &sp.camera, &sp.sprite);
        sp.scale = simd_make_float2((float)sw / dst.width, (float)sh / dst.height);
        sp.shown = simd_make_float2(sw, sh);
        sp.samples = samples;
        sp.band = getenv("ANVIL_PREP_NO_BAND") ? 0.0f : 1.0f;
        sp.pad[0] = getenv("ANVIL_PREP_NATURAL") ? 1.0f : 0.0f;
        sp.pad[1] = getenv("ANVIL_PREP_HARD") ? (float)atoi(getenv("ANVIL_PREP_HARD")) : 0.0f;
        [enc setComputePipelineState:scene];
        [enc setTexture:dst atIndex:0];
        [enc setBytes:&sp length:sizeof(sp) atIndex:0];
        AnvilDispatch2D(enc, scene, dst.width, dst.height);
    };
    struct Totals { double error = 0, flicker = 0, nearDisc = 0, broken = 0; int frames = 0; };
    Totals moving1, moving3, still1, still3;
    auto measure = [&](id<MTLTexture> out, id<MTLTexture> before, simd_float2 sprite, Totals& into) {
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        CompareParams cp = {sprite, 0.045f * sw + 48.0f * std::max(speed, 1.0f), 0};
        [enc setComputePipelineState:compare];
        [enc setTexture:out atIndex:0];
        [enc setTexture:owned[6] atIndex:1];
        [enc setTexture:before atIndex:2];
        [enc setTexture:owned[7] atIndex:3];
        [enc setBuffer:sums offset:0 atIndex:0];
        [enc setBytes:&cp length:sizeof(cp) atIndex:1];
        AnvilDispatch2D(enc, compare, segments, sh);
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        const simd_float4* v = (const simd_float4*)sums.contents;
        simd_double4 total = 0;
        for (NSUInteger i = 0; i < segments * sh; i++) total += simd_double(v[i]);
        into.error += total.x; into.flicker += total.y; into.broken += total.z; into.nearDisc += total.w; into.frames++;
    };

    // Smooth Motion's frame (development: ANVIL_PREP_GEN): made from the last two FSR 3 frames and
    // FSR 3's motion exactly as libanvil makes it, half a frame on, against the scene rendered at
    // that moment — and against showing the newest frame again, which it must beat to be worth it.
    const bool genTest = getenv("ANVIL_PREP_GEN") != nullptr;
    // ANVIL_PREP_GEN_MID: the frame between the last two instead (anvil_midpoint), against the scene
    // half a frame back — and against the older frame still on screen, what's seen without it.
    const bool genMid = genTest && getenv("ANVIL_PREP_GEN_MID") != nullptr;
    // ANVIL_PREP_GEN_AHEAD: the frame made ahead of the newest at the lowest latency (anvil_ahead, 0.69), from the same
    // pictures, motion and check as frames between, against the scene `reach` of a frame on (ANVIL_PREP_GEN_REACH, 0.5).
    const bool genAhead = genTest && !genMid && getenv("ANVIL_PREP_GEN_AHEAD") != nullptr;
    id<MTLComputePipelineState> extrap = genTest ? AnvilPipeline(device, library, genMid ? kAnvilMidpoint : genAhead ? kAnvilAhead : kAnvilExtrapolate,
                                                                 archive, &fromArchive) : nil;
    double midMs = 0.0;
    // Smooth Motion's check (0.51), in every prepare: the frame it makes halfway between two of FSR 3's pictures,
    // against the scene drawn at that moment and against the older frame still on screen, what's seen without it.
    // (0.51 checked a quarter and three-quarters of the way too, for four frames a frame; held back since 0.52.)
    const bool smoothCheck = !genTest;
    id<MTLComputePipelineState> midPSO = smoothCheck ? AnvilPipeline(device, library, kAnvilMidpoint, archive, &fromArchive) : nil;
    // The made frames' check (0.52), as libanvil runs it before each: the two frames looked at, a pixel in 64, and
    // the nearer real frame shown in the made one's place where they disagree over too much of the picture.
    id<MTLComputePipelineState> checkPSO = AnvilPipeline(device, library, kAnvilMidpointCheck, archive, &fromArchive);
    id<MTLComputePipelineState> judgePSO = AnvilPipeline(device, library, kAnvilMidpointJudge, archive, &fromArchive);
    struct CheckState { uint32_t looked, apart; float score; uint32_t hold, judged, held; float share, most; uint32_t parted; };
    id<MTLBuffer> checkState = [device newBufferWithLength:sizeof(CheckState) options:MTLResourceStorageModeShared];
    memset(checkState.contents, 0, sizeof(CheckState));
    // As libanvil's (g_midCheck*): apart; the share of the picture from which the nearer real frame is shown whole; the
    // share from which a made frame counts as taking its pixels where the two disagree.
    float ruleApart = 0.015f, ruleShare = 0.3f, rulePart = 0.04f;
    if (const char* v = getenv("ANVIL_PREP_MID_CHECK")) sscanf(v, "%f,%f,%f", &ruleApart, &ruleShare, &rulePart);
    const simd_float4 checkRule = {ruleApart, ruleShare, rulePart, 0};
    // Where the two frames disagree, a value for each 4x4 of the luma planes (made as the planes are known).
    id<MTLTexture> apartMap = nil;
    auto ensureApartMap = [&]() -> id<MTLTexture> {
        id<MTLTexture> luma = AnvilFSR3Luma(&st);
        const NSUInteger mw = luma ? std::max<NSUInteger>(1, (luma.width + 3) / 4) : 1, mh = luma ? std::max<NSUInteger>(1, (luma.height + 3) / 4) : 1;
        if (!apartMap || apartMap.width != mw || apartMap.height != mh) {
            MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Float width:mw height:mh mipmapped:NO];
            d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            d.storageMode = MTLStorageModePrivate;
            [apartMap release];
            apartMap = [device newTextureWithDescriptor:d];
        }
        return apartMap;
    };
    double shareSum = 0.0;
    int shareFrames = 0;
    auto encodeCheck = [&](id<MTLComputeCommandEncoder> e, simd_float4 game) {
        id<MTLTexture> lumaBefore = AnvilFSR3LumaBefore(&st), luma = AnvilFSR3Luma(&st);
        if (!checkPSO || !judgePSO || !lumaBefore || !luma) return;
        const simd_float4 halfway = {0.5f, 0, 0, 0};
        const simd_float4 planes = {game.x, game.y, game.z, (float)st.scale};
        [e setComputePipelineState:checkPSO];
        [e setTexture:lumaBefore atIndex:0];
        [e setTexture:luma atIndex:1];
        [e setTexture:AnvilFSR3Motion(&st) atIndex:2];
        [e setTexture:ensureApartMap() atIndex:3];
        [e setBuffer:checkState offset:0 atIndex:0];
        [e setBytes:&halfway length:sizeof(halfway) atIndex:1];
        [e setBytes:&planes length:sizeof(planes) atIndex:2];
        [e setBytes:&checkRule length:sizeof(checkRule) atIndex:3];
        AnvilDispatch2D(e, checkPSO, (luma.width + 3) / 4, (luma.height + 3) / 4);
        [e setComputePipelineState:judgePSO];
        [e setBuffer:checkState offset:0 atIndex:0];
        [e setBytes:&checkRule length:sizeof(checkRule) atIndex:1];
        [e dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    };
    id<MTLTexture> smoothOut = midPSO ? privateTexture(device, format, sw, sh) : nil;
    id<MTLTexture> smoothRef = midPSO ? privateTexture(device, MTLPixelFormatRGBA16Float, sw, sh) : nil;
    Totals smoothMade, smoothOlder;
    double smoothMs = 0.0;
    id<MTLTexture> genOut = genTest ? privateTexture(device, format, sw, sh) : nil;
    id<MTLTexture> refHalf = genTest ? privateTexture(device, MTLPixelFormatRGBA16Float, sw, sh) : nil;
    Totals genMade, genRepeat, genNewer;
    // ANVIL_PREP_BAD=x (development only): the made frames' pixels further than x from the true picture counted, in
    // place of the error around the disc — what's seen as a made frame gone wrong.
    const float badAt = getenv("ANVIL_PREP_BAD") ? (float)atof(getenv("ANVIL_PREP_BAD")) : 0.0f;
    auto measureAgainst = [&](id<MTLTexture> out, id<MTLTexture> before, id<MTLTexture> refNow, id<MTLTexture> refBefore,
                              simd_float2 sprite, Totals& into) {
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        CompareParams cp = {sprite, 0.045f * sw + 48.0f * std::max(speed, 1.0f), badAt};
        [enc setComputePipelineState:compare];
        [enc setTexture:out atIndex:0];
        [enc setTexture:refNow atIndex:1];
        [enc setTexture:before atIndex:2];
        [enc setTexture:refBefore atIndex:3];
        [enc setBuffer:sums offset:0 atIndex:0];
        [enc setBytes:&cp length:sizeof(cp) atIndex:1];
        AnvilDispatch2D(enc, compare, segments, sh);
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        const simd_float4* v = (const simd_float4*)sums.contents;
        simd_double4 total = 0;
        for (NSUInteger i = 0; i < segments * sh; i++) total += simd_double(v[i]);
        into.error += total.x; into.flicker += total.y; into.broken += total.z; into.nearDisc += total.w; into.frames++;
    };

    const int lastFrame = 31;
    for (int t = 0; t <= lastFrame; t++) {
        simd_float2 camera, sprite;
        sceneAt(t, &camera, &sprite);
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        draw(enc, owned[0], t, (gameAA || getenv("ANVIL_PREP_AA")) ? 3 : 1);
        // FSR 1 alone, as every game has had it (or, at the display's size, the frame as it is).
        if (native) {
            [enc endEncoding];
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit copyFromTexture:owned[0] toTexture:owned[2]];
            [blit endEncoding];
            enc = [cb computeCommandEncoder];
        } else {
            AnvilEncodeFSR(enc, fsr1Pass, shape, easu, finish, fused, owned[0], owned[1], owned[2], params);
        }
        // FSR 3: the temporal pass, then FSR 1 from its result (RCAS alone at the display's size).
        if (oracle && truth && t > 0) {
            simd_float2 c0, s0;
            sceneAt(t - 1, &c0, &s0);
            TruthParams tp = {camera - c0, sprite, sprite - s0, simd_make_float2((float)sw / gw, (float)sh / gh),
                              simd_make_float2(sw, sh), 8.0f * st.scale, 0};
            [enc setComputePipelineState:truth];
            [enc setTexture:st.fine[st.current] atIndex:0];
            [enc setBytes:&tp length:sizeof(tp) atIndex:0];
            AnvilDispatch2D(enc, truth, st.fine[st.current].width, st.fine[st.current].height);
            st.given = true;
        }
        // FSR 3: EASU, RCAS and the blend in one pass (RCAS at half strength at the display's size).
        const bool encoded = AnvilEncodeFSR3(&st, enc, owned[0], owned[4], native ? nativeParams : params);
        st.given = false;
        if (!encoded) { [enc endEncoding]; [cb commit]; [scene release]; [compare release]; [sums release]; return refuse(@"FSR 3 couldn't be encoded"); }
        const bool measured = (t >= 12 && t <= 23) || t >= 26;
        if (measured || t == 11 || t == 25) draw(enc, owned[6], t, 4);
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.error) { [scene release]; [compare release]; [sums release]; return refuse([NSString stringWithFormat:@"the GPU stopped FSR 3: %@", cb.error.localizedDescription]); }
        if (getenv("ANVIL_PREP_DEBUG") && (t == 20 || t == 30)) {
            // How well the motion was measured: the camera moved (5.3, 2.1) shown pixels a frame.
            id<MTLTexture> mt = AnvilFSR3Motion(&st);
            const float sx = (float)gw / sw, sy = (float)gh / sh;
            const simd_float2 truth = t <= 23 ? simd_make_float2(5.3f * sx, 2.1f * sy) * speed : simd_make_float2(0, 0);
            id<MTLBuffer> mb = [device newBufferWithLength:mt.width * mt.height * 8 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> rb = [queue commandBuffer];
            id<MTLBlitCommandEncoder> bl = [rb blitCommandEncoder];
            [bl copyFromTexture:mt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                     sourceSize:MTLSizeMake(mt.width, mt.height, 1) toBuffer:mb destinationOffset:0
         destinationBytesPerRow:mt.width * 8 destinationBytesPerImage:mt.width * mt.height * 8];
            [bl endEncoding]; [rb commit]; [rb waitUntilCompleted];
            int n = 0, within25 = 0, within1 = 0; double sumx = 0, sumy = 0, trust = 0, err = 0;
            for (NSUInteger y = 0; y < mt.height; y++) for (NSUInteger x = 0; x < mt.width; x++) {
                // Leave out the HUD and the disc, which move differently.
                const float cell = 8.0f * st.scale;
                const float px = (x * cell + cell / 2) / sx, py = (y * cell + cell / 2) / sy;
                if (px < 0.17f * sw && py < 0.11f * sh) continue;
                if (simd_length(simd_make_float2(px, py) - sprite) < 0.045f * sw + 24) continue;
                __fp16 h[4]; memcpy(h, (uint8_t*)mb.contents + (y * mt.width + x) * 8, 8);
                const simd_float2 v = simd_make_float2(h[0], h[1]);
                const float e = simd_length(v - truth);
                n++; sumx += v.x; sumy += v.y; trust += (float)h[2]; err += e;
                if (e < 0.25f) within25++;
                if (e < 1.0f) within1++;
            }
            note("motion at frame %d: truth %.2f,%.2f; mean %.2f,%.2f; mean error %.2f px; %.0f%% within 0.25 px, %.0f%% within 1 px; trust %.2f (%d blocks)",
                 t, truth.x, truth.y, sumx / n, sumy / n, err / n, 100.0 * within25 / n, 100.0 * within1 / n, trust / n, n);
            [mb release];
            if (st.pan && st.panCost) {
                // The pan, in game pixels, and how sure.
                id<MTLBuffer> pb = [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
                id<MTLCommandBuffer> pr = [queue commandBuffer];
                id<MTLBlitCommandEncoder> pbl = [pr blitCommandEncoder];
                [pbl copyFromTexture:st.pan sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(1, 1, 1) toBuffer:pb destinationOffset:0 destinationBytesPerRow:16 destinationBytesPerImage:16];
                [pbl endEncoding]; [pr commit]; [pr waitUntilCompleted];
                const float* v = (const float*)pb.contents;
                note("pan at frame %d: %.2f,%.2f game px; sure %.2f; the plane's difference %.4f", t, v[0] * st.scale, v[1] * st.scale, v[2], v[3]);
                [pb release];
            }
            if (st.wide) {
                // The widest field, in game pixels: what the widest search measured.
                id<MTLTexture> wt = st.wide;
                id<MTLBuffer> wb = [device newBufferWithLength:wt.width * wt.height * 8 options:MTLResourceStorageModeShared];
                id<MTLCommandBuffer> wr = [queue commandBuffer];
                id<MTLBlitCommandEncoder> wbl = [wr blitCommandEncoder];
                [wbl copyFromTexture:wt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(wt.width, wt.height, 1) toBuffer:wb destinationOffset:0
              destinationBytesPerRow:wt.width * 8 destinationBytesPerImage:wt.width * wt.height * 8];
                [wbl endEncoding]; [wr commit]; [wr waitUntilCompleted];
                int wn = 0, wright = 0; double wx = 0, wy = 0, wc = 0;
                for (NSUInteger i = 0; i < wt.width * wt.height; i++) {
                    __fp16 h[4]; memcpy(h, (uint8_t*)wb.contents + i * 8, 8);
                    const simd_float2 v = simd_make_float2(h[0], h[1]) * (float)st.scale;
                    wn++; wx += v.x; wy += v.y; wc += (float)h[2];
                    if (simd_length(v - truth) < 2.0f * st.scale) wright++;
                }
                note("widest field at frame %d: mean %.2f,%.2f game px; %.0f%% within %d px of the truth; confidence %.2f (%d blocks)",
                     t, wx / wn, wy / wn, 100.0 * wright / wn, 2 * st.scale, wc / wn, wn);
                [wb release];
            }
        }
        if (measured) {
            measure(owned[2], owned[3], sprite, t <= 23 ? moving1 : still1);
            measure(owned[4], owned[5], sprite, t <= 23 ? moving3 : still3);
        }
        if (genMid && extrap && genOut && refHalf && t >= 12 && t <= 22 && AnvilFSR3PictureBefore(&st)) {
            // The moment between the two frames the made one is for (ANVIL_PREP_GEN_PHASE, 0.5 by default; 0.25
            // and 0.75 are Smooth Motion's other two at four frames a frame), and the scene drawn at it.
            static const float phase = getenv("ANVIL_PREP_GEN_PHASE") ? std::clamp((float)atof(getenv("ANVIL_PREP_GEN_PHASE")), 0.05f, 0.95f) : 0.5f;
            const float at = t - (1.0f - phase);
            simd_float2 cHalf, sHalf;
            sceneAt(at, &cHalf, &sHalf);
            id<MTLTexture> motionBefore = AnvilFSR3MotionBefore(&st);
            const simd_float4 mp = {phase, motionBefore ? 1.0f : 0.0f, getenv("ANVIL_PREP_GEN_MID_FLAGS") ? (float)atoi(getenv("ANVIL_PREP_GEN_MID_FLAGS")) : 0.0f, 0};
            const simd_float4 gp = {(float)gw, (float)gh, 8.0f * st.scale, 0};
            const simd_float4 cp = {0, 0, 1, -1};
            auto encodeMid = [&](id<MTLComputeCommandEncoder> e) {
                [e setComputePipelineState:extrap];
                [e setTexture:AnvilFSR3PictureBefore(&st) atIndex:0];
                [e setTexture:AnvilFSR3Picture(&st) atIndex:1];
                [e setTexture:AnvilFSR3Motion(&st) atIndex:2];
                [e setTexture:motionBefore ? motionBefore : AnvilFSR3Motion(&st) atIndex:3];
                [e setTexture:genOut atIndex:4];
                [e setTexture:ensureApartMap() atIndex:5];
                [e setBytes:&cp length:sizeof(cp) atIndex:0];
                [e setBytes:&mp length:sizeof(mp) atIndex:1];
                [e setBytes:&gp length:sizeof(gp) atIndex:2];
                [e setBuffer:checkState offset:0 atIndex:3];
                AnvilDispatch2D(e, extrap, sw, sh);
            };
            id<MTLCommandBuffer> gb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> ge = [gb computeCommandEncoder];
            encodeCheck(ge, gp);
            encodeMid(ge);
            draw(ge, refHalf, at, 4);
            [ge endEncoding];
            [gb commit];
            [gb waitUntilCompleted];
            // The made frame and the older real one (on screen until the newer is shown), each against
            // the scene half a frame back; the change from the older frame against the scene's.
            measureAgainst(genOut, owned[5], refHalf, owned[7], sHalf, genMade);
            measureAgainst(owned[5], owned[5], refHalf, owned[7], sHalf, genRepeat);
            measureAgainst(owned[4], owned[5], refHalf, owned[7], sHalf, genNewer);
            shareSum += ((const CheckState*)checkState.contents)->share; shareFrames++;
            if (t == 20) {
                // Its time on this GPU at these sizes: twenty in one command buffer.
                id<MTLCommandBuffer> tb = [queue commandBuffer];
                id<MTLComputeCommandEncoder> te = [tb computeCommandEncoder];
                for (int i = 0; i < 20; i++) encodeMid(te);
                [te endEncoding];
                [tb commit];
                [tb waitUntilCompleted];
                midMs = (tb.GPUEndTime - tb.GPUStartTime) * 1000.0 / 20.0;
                // The check on its own, the same way (development only).
                if (badAt > 0) {
                    id<MTLCommandBuffer> kb = [queue commandBuffer];
                    id<MTLComputeCommandEncoder> ke = [kb computeCommandEncoder];
                    for (int i = 0; i < 20; i++) encodeCheck(ke, gp);
                    [ke endEncoding];
                    [kb commit];
                    [kb waitUntilCompleted];
                    note("the made frames' check: %.3f ms a frame", (kb.GPUEndTime - kb.GPUStartTime) * 1000.0 / 20.0);
                }
            }
            if (dump && t == 20) {
                NSString* dir = @(dump);
                dumpPNG(device, queue, genOut, [dir stringByAppendingPathComponent:@"mid-made.png"]);
                dumpPNG(device, queue, refHalf, [dir stringByAppendingPathComponent:@"mid-reference.png"]);
                dumpPNG(device, queue, owned[5], [dir stringByAppendingPathComponent:@"mid-older.png"]);
                dumpPNG(device, queue, owned[4], [dir stringByAppendingPathComponent:@"mid-newer.png"]);
            }
        }
        if (smoothCheck && midPSO && smoothOut && smoothRef && t >= 12 && t <= 22 && AnvilFSR3PictureBefore(&st)) {
            id<MTLTexture> motionBefore = AnvilFSR3MotionBefore(&st);
            const simd_float4 gp = {(float)gw, (float)gh, 8.0f * st.scale, 0};
            const simd_float4 cp = {0, 0, 1, -1};
            // Halfway, as Smooth Motion shows it (one made between each two since 0.52).
            for (int q = 2; q <= 2; ++q) {
                const float phase = 0.25f * q;
                const float at = t - (1.0f - phase);
                simd_float2 cAt, sAt;
                sceneAt(at, &cAt, &sAt);
                const simd_float4 mp = {phase, motionBefore ? 1.0f : 0.0f, 0, 0};
                auto encode = [&](id<MTLComputeCommandEncoder> e) {
                    [e setComputePipelineState:midPSO];
                    [e setTexture:AnvilFSR3PictureBefore(&st) atIndex:0];
                    [e setTexture:AnvilFSR3Picture(&st) atIndex:1];
                    [e setTexture:AnvilFSR3Motion(&st) atIndex:2];
                    [e setTexture:motionBefore ? motionBefore : AnvilFSR3Motion(&st) atIndex:3];
                    [e setTexture:smoothOut atIndex:4];
                    [e setTexture:ensureApartMap() atIndex:5];
                    [e setBuffer:checkState offset:0 atIndex:3];
                    [e setBytes:&cp length:sizeof(cp) atIndex:0];
                    [e setBytes:&mp length:sizeof(mp) atIndex:1];
                    [e setBytes:&gp length:sizeof(gp) atIndex:2];
                    AnvilDispatch2D(e, midPSO, sw, sh);
                };
                id<MTLCommandBuffer> gb = [queue commandBuffer];
                id<MTLComputeCommandEncoder> ge = [gb computeCommandEncoder];
                encodeCheck(ge, gp);
                encode(ge);
                draw(ge, smoothRef, at, 4);
                [ge endEncoding];
                [gb commit];
                [gb waitUntilCompleted];
                measureAgainst(smoothOut, owned[5], smoothRef, owned[7], sAt, smoothMade);
                measureAgainst(owned[5], owned[5], smoothRef, owned[7], sAt, smoothOlder);
                if (t == 20 && q == 2) {
                    id<MTLCommandBuffer> tb = [queue commandBuffer];
                    id<MTLComputeCommandEncoder> te = [tb computeCommandEncoder];
                    for (int i = 0; i < 12; i++) encode(te);
                    [te endEncoding];
                    [tb commit];
                    [tb waitUntilCompleted];
                    smoothMs = (tb.GPUEndTime - tb.GPUStartTime) * 1000.0 / 12.0;
                }
            }
        }
        if (genTest && !genMid && extrap && genOut && refHalf && t >= 12 && t <= 22 && (!genAhead || AnvilFSR3PictureBefore(&st))) {
            static const float reach = getenv("ANVIL_PREP_GEN_REACH") ? std::clamp((float)atof(getenv("ANVIL_PREP_GEN_REACH")), 0.05f, 1.0f) : 0.5f;
            const float onTo = genAhead ? reach : 0.5f;
            simd_float2 cHalf, sHalf;
            sceneAt(t + onTo, &cHalf, &sHalf);
            id<MTLCommandBuffer> gb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> ge = [gb computeCommandEncoder];
            const simd_float4 agp = {(float)gw, (float)gh, 8.0f * st.scale, 0};
            auto encodeAhead = [&](id<MTLComputeCommandEncoder> e) {
                const simd_float4 ap = {reach, 0, getenv("ANVIL_PREP_GEN_MID_FLAGS") ? (float)atoi(getenv("ANVIL_PREP_GEN_MID_FLAGS")) : 0.0f, 0};
                const simd_float4 cp = {0, 0, 1, -1};
                [e setComputePipelineState:extrap];
                [e setTexture:AnvilFSR3PictureBefore(&st) atIndex:0];
                [e setTexture:AnvilFSR3Picture(&st) atIndex:1];
                [e setTexture:AnvilFSR3Motion(&st) atIndex:2];
                [e setTexture:genOut atIndex:4];
                [e setTexture:ensureApartMap() atIndex:5];
                [e setBytes:&cp length:sizeof(cp) atIndex:0];
                [e setBytes:&ap length:sizeof(ap) atIndex:1];
                [e setBytes:&agp length:sizeof(agp) atIndex:2];
                [e setBuffer:checkState offset:0 atIndex:3];
                AnvilDispatch2D(e, extrap, sw, sh);
            };
            if (genAhead) {
                encodeCheck(ge, agp);
                encodeAhead(ge);
            } else {
                [ge setComputePipelineState:extrap];
                [ge setTexture:owned[5] atIndex:0];
                [ge setTexture:owned[4] atIndex:1];
                [ge setTexture:AnvilFSR3Motion(&st) atIndex:2];
                [ge setTexture:genOut atIndex:3];
                const simd_float4 gp = {0.5f, (float)sw / (float)gw, 0, 0};
                [ge setBytes:&gp length:sizeof(gp) atIndex:0];
                AnvilDispatch2D(ge, extrap, sw, sh);
            }
            draw(ge, refHalf, t + onTo, 4);
            [ge endEncoding];
            [gb commit];
            [gb waitUntilCompleted];
            // The made frame and the newest real one, each against the scene half a frame on; the
            // change from the real frame against the scene's own change (owned[6] is the scene now).
            measureAgainst(genOut, owned[4], refHalf, owned[6], sHalf, genMade);
            measureAgainst(owned[4], owned[4], refHalf, owned[6], sHalf, genRepeat);
            if (genAhead && t == 20) {
                id<MTLCommandBuffer> tb = [queue commandBuffer];
                id<MTLComputeCommandEncoder> te = [tb computeCommandEncoder];
                for (int i = 0; i < 20; i++) encodeAhead(te);
                [te endEncoding];
                [tb commit];
                [tb waitUntilCompleted];
                midMs = (tb.GPUEndTime - tb.GPUStartTime) * 1000.0 / 20.0;
            }
            if (dump && t == 20) {
                NSString* dir = @(dump);
                dumpPNG(device, queue, genOut, [dir stringByAppendingPathComponent:@"half-made.png"]);
                dumpPNG(device, queue, refHalf, [dir stringByAppendingPathComponent:@"half-reference.png"]);
                dumpPNG(device, queue, owned[4], [dir stringByAppendingPathComponent:@"half-newest.png"]);
            }
        }
        if (getenv("ANVIL_PREP_DEBUG") && t == 23) {
            // Where FSR 1's and FSR 3's pictures sit against the reference: the shift that matches best.
            auto grab = [&](id<MTLTexture> tex) {
                const size_t bpp = tex.pixelFormat == MTLPixelFormatRGBA16Float ? 8 : 4;
                id<MTLBuffer> b = [device newBufferWithLength:tex.width * tex.height * bpp options:MTLResourceStorageModeShared];
                id<MTLCommandBuffer> rb = [queue commandBuffer];
                id<MTLBlitCommandEncoder> bl = [rb blitCommandEncoder];
                [bl copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                         sourceSize:MTLSizeMake(tex.width, tex.height, 1) toBuffer:b destinationOffset:0
             destinationBytesPerRow:tex.width * bpp destinationBytesPerImage:tex.width * tex.height * bpp];
                [bl endEncoding]; [rb commit]; [rb waitUntilCompleted];
                std::vector<float> g(tex.width * tex.height);
                for (NSUInteger i = 0; i < g.size(); i++) {
                    const simd_float3 c = tex.pixelFormat == MTLPixelFormatRGBA16Float
                        ? unpackPixel(MTLPixelFormatRGBA16Float, (uint8_t*)b.contents + i * 8)
                        : unpackPixel(format, (uint8_t*)b.contents + i * 4);
                    g[i] = c.x * 0.2126f + c.y * 0.7152f + c.z * 0.0722f;
                }
                [b release];
                return g;
            };
            std::vector<float> r = grab(owned[6]), a = grab(owned[2]), b3 = grab(owned[4]);
            for (int which = 0; which < 2; which++) {
                std::vector<float>& o = which == 0 ? a : b3;
                double bestE = 1e9; int bx = 0, by = 0; double at0 = 0;
                for (int dy = -6; dy <= 6; dy++) for (int dx = -6; dx <= 6; dx++) {
                    double e = 0; long n = 0;
                    for (NSUInteger y = sh / 4; y < sh * 3 / 4; y += 2) for (NSUInteger x = sw / 2; x < sw * 3 / 4; x += 2) {
                        e += fabs(o[y * sw + x] - r[(y + dy) * sw + x + dx]); n++;
                    }
                    e = e / n * 255;
                    if (dx == 0 && dy == 0) at0 = e;
                    if (e < bestE) { bestE = e; bx = dx; by = dy; }
                }
                note("%s: %.2f against the reference as it is; %.2f moved by %d,%d", which == 0 ? "FSR 1" : "FSR 3", at0, bestE, bx, by);
            }
        }
        if (dump && (t == 23 || t == lastFrame)) {
            NSString* dir = @(dump);
            NSString* tag = t == 23 ? @"moving" : @"still";
            dumpPNG(device, queue, owned[0], [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-game.png", tag]]);
            dumpPNG(device, queue, owned[2], [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-fsr1.png", tag]]);
            dumpPNG(device, queue, owned[4], [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-fsr3.png", tag]]);
            dumpPNG(device, queue, owned[6], [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-reference.png", tag]]);
        }
        // This frame becomes the one before.
        id<MTLCommandBuffer> keep = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [keep blitCommandEncoder];
        [blit copyFromTexture:owned[2] toTexture:owned[3]];
        [blit copyFromTexture:owned[4] toTexture:owned[5]];
        [blit copyFromTexture:owned[6] toTexture:owned[7]];
        [blit endEncoding];
        [keep commit];
        [keep waitUntilCompleted];
    }
    [scene release];
    [compare release];
    [sums release];

    // Per pixel, in 255ths.
    const double pixels = (double)sw * sh;
    auto per = [&](const Totals& x, double v) { return x.frames ? v / x.frames / pixels * 255.0 : 0.0; };
    if (genMid && genMade.frames) {
        note("Smooth Motion between frames at speed %.1f: made frame %.2f from the scene half a frame back, the older frame "
             "still on screen %.2f; change against the scene's %.2f (older %.2f); around the moving disc %.0f%% of the older's "
             "error; %.2f ms a frame; %s",
             speed, per(genMade, genMade.error), per(genRepeat, genRepeat.error), per(genMade, genMade.flicker),
             per(genRepeat, genRepeat.flicker), genRepeat.nearDisc > 0 ? 100.0 * genMade.nearDisc / genRepeat.nearDisc : 0.0,
             midMs, genMade.broken > 0 ? "SOME PIXELS NOT NUMBERS" : "all numbers");
        if (badAt > 0)
            note("Smooth Motion between frames at speed %.1f: pixels further than %.2f from the scene: made %.3f%%, older %.3f%%, "
                 "newer %.3f%%; error made %.2f, older %.2f, newer %.2f; check: apart over %.1f%% of the picture on average, "
                 "%u of %u made frames the nearer real one, %u with its pixels where the two disagreed",
                 speed, badAt, 100.0 * genMade.nearDisc / genMade.frames / ((double)sw * sh),
                 100.0 * genRepeat.nearDisc / genRepeat.frames / ((double)sw * sh), 100.0 * genNewer.nearDisc / genNewer.frames / ((double)sw * sh),
                 per(genMade, genMade.error), per(genRepeat, genRepeat.error), per(genNewer, genNewer.error),
                 shareFrames ? 100.0 * shareSum / shareFrames : 0.0, ((const CheckState*)checkState.contents)->held,
                 ((const CheckState*)checkState.contents)->judged, ((const CheckState*)checkState.contents)->parted);
    } else if (genTest && genMade.frames) {
        note("Smooth Motion%s at speed %.1f: made frame %.2f from the scene half a frame on, the newest frame again %.2f; "
             "change against the scene's %.2f (repeat %.2f); around the moving disc %.0f%% of the repeat's error; %.2f ms a frame; %s",
             genAhead ? " made ahead (lowest latency)" : "", speed, per(genMade, genMade.error), per(genRepeat, genRepeat.error), per(genMade, genMade.flicker),
             per(genRepeat, genRepeat.flicker), genRepeat.nearDisc > 0 ? 100.0 * genMade.nearDisc / genRepeat.nearDisc : 0.0,
             midMs, genMade.broken > 0 ? "SOME PIXELS NOT NUMBERS" : "all numbers");
    }
    [genOut release]; [refHalf release]; [extrap release];
    const double smMade = per(smoothMade, smoothMade.error), smOlder = per(smoothOlder, smoothOlder.error);
    const bool smoothBroken = smoothMade.broken > 0;
    if (smoothMade.frames)
        note("Smooth Motion check: the frame made halfway between two came out %.2f from the scene at its moment, the older "
             "frame %.2f; %.2f ms%s", smMade, smOlder, smoothMs, smoothBroken ? "; SOME PIXELS NOT NUMBERS" : "");
    [smoothOut release]; [smoothRef release]; [midPSO release]; [checkPSO release]; [judgePSO release]; [checkState release];
    const double e1 = per(moving1, moving1.error), e3 = per(moving3, moving3.error);
    const double f1 = per(moving1, moving1.flicker), f3 = per(moving3, moving3.flicker);
    const double s1 = per(still1, still1.error), s3 = per(still3, still3.error);
    const double d1 = moving1.nearDisc, d3 = moving3.nearDisc;
    const bool broken = moving3.broken + still3.broken > 0;

    // Timed: a frame's worth of each, eight at a time, taking turns.
    std::vector<double> t1, t3;
    for (int rep = 0; rep < 12; rep++) {
        for (int which = 0; which < 2; which++) {
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            for (int i = 0; i < 8; i++) {
                if (which == 0) {
                    if (!native) AnvilEncodeFSR(enc, fsr1Pass, shape, easu, finish, fused, owned[0], owned[1], owned[2], params);
                } else {
                    AnvilEncodeFSR3(&st, enc, owned[0], owned[4], native ? nativeParams : params);
                }
            }
            [enc endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            const double ms = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0 / 8;
            if (rep >= 2 && !cb.error) (which == 0 ? t1 : t3).push_back(ms);
        }
    }
    auto median = [](std::vector<double>& v) { if (v.empty()) return 0.0; std::sort(v.begin(), v.end()); return v[v.size() / 2]; };
    const double ms1 = native ? 0.0 : median(t1), ms3 = median(t3);
    if (getenv("ANVIL_PREP_DEBUG")) {
        // Each part on its own: the motion passes, then the resolve pass.
        const char* names[2] = {"motion", "resolve"};
        for (int part = 1; part <= 2; part++) {
            std::vector<double> tp;
            for (int rep = 0; rep < 10; rep++) {
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                for (int i = 0; i < 8; i++) {
                    st.only = part;
                    AnvilEncodeFSR3(&st, enc, owned[0], owned[4], params);
                    st.only = 0;
                }
                [enc endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                if (rep >= 2) tp.push_back((cb.GPUEndTime - cb.GPUStartTime) * 1000.0 / 8);
            }
            note("FSR 3 part %s: %.3f ms (%lux%lu groups)", names[part - 1], median(tp), (unsigned long)st.shape.width, (unsigned long)st.shape.height);
        }
        // The resolve pass with nothing to blend: EASU, RCAS and the writes alone.
        std::vector<double> tp;
        for (int rep = 0; rep < 10; rep++) {
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            for (int i = 0; i < 8; i++) { AnvilFSR3Reset(&st); st.only = 2; AnvilEncodeFSR3(&st, enc, owned[0], owned[4], params); st.only = 0; }
            [enc endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            if (rep >= 2) tp.push_back((cb.GPUEndTime - cb.GPUStartTime) * 1000.0 / 8);
        }
        note("FSR 3 part resolve with nothing to blend: %.3f ms", median(tp));
    }

    // Kept when it is closer to the reference in motion, no further from it when nothing moves,
    // no worse around the moving disc (where a wrong history would trail), and nothing broke.
    NSString* why = nil;
    if (broken) why = @"some of its pixels came out as no number at all";
    else if (e3 > e1 * 1.0) why = [NSString stringWithFormat:@"in motion it came out no closer to the reference than FSR 1 (%.2f against %.2f)", e3, e1];
    else if (s3 > s1 * 1.03 + 0.05) why = [NSString stringWithFormat:@"standing still it came out further from the reference than FSR 1 (%.2f against %.2f)", s3, s1];
    else if (d3 > d1 * 1.05) why = @"around the moving disc it came out further from the reference than FSR 1: a trail";
    NSMutableDictionary* r = [NSMutableDictionary dictionary];
    r[@"fsr3"] = @(why == nil);
    if (why) r[@"fsr3_why"] = why;
    r[@"fsr3_native"] = @(native);
    r[@"fsr3_game_aa"] = @(gameAA);
    r[@"fsr3_ms"] = @(round(ms3 * 1000) / 1000);
    r[@"fsr1_ms"] = @(round(ms1 * 1000) / 1000);
    r[@"fsr3_error"] = @(round(e3 * 1000) / 1000);
    r[@"fsr1_error"] = @(round(e1 * 1000) / 1000);
    r[@"fsr3_flicker"] = @(round(f3 * 1000) / 1000);
    r[@"fsr1_flicker"] = @(round(f1 * 1000) / 1000);
    r[@"fsr3_still_error"] = @(round(s3 * 1000) / 1000);
    r[@"fsr1_still_error"] = @(round(s1 * 1000) / 1000);
    r[@"fsr3_trail"] = @(d1 > 0 ? round(d3 / d1 * 1000) / 1000 : 1.0);
    if (smoothMade.frames) {
        r[@"smooth_made_error"] = @(round(smMade * 1000) / 1000);
        r[@"smooth_older_error"] = @(round(smOlder * 1000) / 1000);
        r[@"smooth_ms"] = @(round(smoothMs * 1000) / 1000);
        if (smoothBroken) r[@"smooth_broken"] = @YES;
    }
    return r;
}

// --- prepare ------------------------------------------------------------------------------

static int prepare(int argc, char** argv) {
    if (argc < 6) return fail(@"usage: anvil-prep prepare <archive> <game WxH> <shown WxH> <pixel format> [sharpness]");
    NSString* archivePath = [NSString stringWithUTF8String:argv[2]];
    NSUInteger gw, gh, sw, sh;
    if (!parseSize(argv[3], &gw, &gh) || !parseSize(argv[4], &sw, &sh)) return fail(@"the sizes given aren't sizes");
    const NSUInteger requested = (NSUInteger)atoi(argv[5]);
    const float sharpness = argc > 6 ? (float)atof(argv[6]) : 0.9f;
    const bool gameAA = argc > 7 && !strcmp(argv[7], "aa");

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return fail(@"Metal has no GPU to give this process");
    emit(@{@"event": @"device", @"gpu": device.name, @"arch": @(arch())});

    // 1. The library, compiled as the game will compile it.
    double compileMs = 0;
    id<MTLLibrary> library = AnvilShaderLibrary(device, note, &compileMs);
    if (!library) return fail(@"Anvil's shaders didn't compile");
    emit(@{@"event": @"compiled", @"ms": @(lrint(compileMs))});

    // 2. Every pipeline into an archive for this GPU.
    const CFTimeInterval a0 = CACurrentMediaTime();
    MTLBinaryArchiveDescriptor* ad = [[MTLBinaryArchiveDescriptor alloc] init];
    NSError* error = nil;
    id<MTLBinaryArchive> archive = [device newBinaryArchiveWithDescriptor:ad error:&error];
    [ad release];
    if (!archive) return fail([NSString stringWithFormat:@"Metal wouldn't make an archive: %@", error.localizedDescription]);
    int added = 0;
    NSMutableArray* missing = [NSMutableArray array];
    for (int k = 0; k < kAnvilKernelCount; k++) {
        MTLComputePipelineDescriptor* d = AnvilPipelineDescriptor(library, k);
        if (d && [archive addComputePipelineFunctionsWithDescriptor:d error:&error]) added++;
        else [missing addObject:@(AnvilKernelName(k))];
        [d release];
    }
    [[NSFileManager defaultManager] removeItemAtPath:archivePath error:nil];
    if (![archive serializeToURL:[NSURL fileURLWithPath:archivePath] error:&error])
        return fail([NSString stringWithFormat:@"the archive couldn't be saved: %@", error.localizedDescription]);
    emit(@{@"event": @"archived", @"pipelines": @(added), @"of": @(kAnvilKernelCount), @"missing": missing,
           @"ms": @(lrint((CACurrentMediaTime() - a0) * 1000.0))});

    // 3. FSR on the GPU, at the game's sizes and in its format.
    const MTLPixelFormat format = plainFormat(requested);
    if (format == MTLPixelFormatInvalid) {
        NSString* why = [NSString stringWithFormat:@"pixel format %lu isn't one FSR to the display takes", (unsigned long)requested];
        emit(@{@"event": @"done", @"pass": @"split", @"tested": @NO, @"why": why, @"fsr3": @NO, @"fsr3_why": why});
        return 0;
    }
    if (gw > sw || gh > sh) {
        emit(@{@"event": @"done", @"pass": @"split", @"tested": @NO,
               @"why": @"the game draws larger than the display: FSR has nothing to upscale",
               @"fsr3": @NO, @"fsr3_why": @"the game draws larger than the display"});
        return 0;
    }
    bool fromArchive = false;
    id<MTLComputePipelineState> easu = AnvilPipeline(device, library, kAnvilFsrEasu, archive, &fromArchive);
    id<MTLComputePipelineState> finish = AnvilPipeline(device, library, kAnvilFinish, archive, &fromArchive);
    id<MTLComputePipelineState> fused = AnvilPipeline(device, library, kAnvilFsrFused, archive, &fromArchive);
    if (!easu || !finish) return fail(@"FSR's pipelines didn't build");
    const MTLSize shape = AnvilFusedShape(fused, device, MTLSizeMake(32, 32, 1));

    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLTexture> input = privateTexture(device, format, gw, gh);
    id<MTLTexture> scratch = privateTexture(device, format, sw, sh);
    id<MTLTexture> outSplit = privateTexture(device, format, sw, sh);
    id<MTLTexture> outFused = privateTexture(device, format, sw, sh);
    if (!input || !scratch || !outSplit || !outFused) return fail(@"the GPU hadn't room for a test frame at these sizes");
    const simd_float4 params = {sharpness, 0.0f, 1.0f, -1.0f};
    auto run = [&](int pass, id<MTLTexture> target, int times) -> id<MTLCommandBuffer> {
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        for (int i = 0; i < times; i++)
            AnvilEncodeFSR(enc, pass, shape, easu, finish, fused, input, scratch, target, params);
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        return cb;
    };
    const bool canFuse = fused && shape.width > 0;

    // A flat colour comes out the colour it went in, both ways.
    fill(device, queue, input, true);
    NSMutableArray* passes = [NSMutableArray arrayWithObject:@(kAnvilFSRSplit)];
    if (canFuse) [passes addObject:@(kAnvilFSRFused)];
    for (NSNumber* pass in passes) {
        id<MTLTexture> target = pass.intValue == kAnvilFSRFused ? outFused : outSplit;
        id<MTLCommandBuffer> cb = run(pass.intValue, target, 1);
        if (cb.error) return fail([NSString stringWithFormat:@"the GPU stopped FSR: %@", cb.error.localizedDescription]);
        id<MTLBuffer> back = readBack(device, queue, target);
        const size_t bpp = bytesPerPixel(format);
        const NSUInteger points[3][2] = {{sw / 2, sh / 2}, {0, 0}, {sw - 1, sh - 1}};
        for (auto& pt : points) {
            const simd_float3 c = unpackPixel(format, (const uint8_t*)back.contents + (pt[1] * sw + pt[0]) * bpp) * 255.0f;
            if (fabsf(c.x - 200) > 1.5f || fabsf(c.y - 60) > 1.5f || fabsf(c.z - 40) > 1.5f) {
                [back release];
                return fail([NSString stringWithFormat:@"FSR%@ changed a flat colour: (200, 60, 40) came out (%.0f, %.0f, %.0f)",
                             pass.intValue == kAnvilFSRFused ? @" in one pass" : @"", c.x, c.y, c.z]);
            }
        }
        [back release];
    }

    // A frame like a game's: the one-pass picture against the two-pass one.
    fill(device, queue, input, false);
    double maxDiff = 0, meanDiff = 0;
    NSUInteger emitApart = 0;
    bool fusedOK = false;
    {
        id<MTLCommandBuffer> cb = run(kAnvilFSRSplit, outSplit, 1);
        if (cb.error) return fail([NSString stringWithFormat:@"the GPU stopped FSR: %@", cb.error.localizedDescription]);
        if (canFuse) {
            cb = run(kAnvilFSRFused, outFused, 1);
            if (!cb.error) {
                id<MTLBuffer> a = readBack(device, queue, outSplit), b = readBack(device, queue, outFused);
                const size_t bpp = bytesPerPixel(format);
                double sum = 0;
                NSUInteger worst = 0, apart = 0, broken = 0;
                for (NSUInteger i = 0; i < sw * sh; i++) {
                    const simd_float3 x = unpackPixel(format, (const uint8_t*)a.contents + i * bpp);
                    const simd_float3 y = unpackPixel(format, (const uint8_t*)b.contents + i * bpp);
                    // Not a number where two passes give one: wrong, wherever it is. (Out of 0–1
                    // alone isn't: RCAS lands a 16-bit float frame a little outside it both ways —
                    // 1.07 measured — and the display clips it.)
                    if ((!isfinite(y.x) || !isfinite(y.y) || !isfinite(y.z)) && isfinite(simd_reduce_add(x))) broken++;
                    const simd_float3 d = simd_abs(x - y) * 255.0f;
                    const float m = simd_reduce_max(d);
                    if (m > maxDiff) { maxDiff = m; worst = i; }
                    if (m > 16.0f) apart++;
                    sum += d.x + d.y + d.z;
                }
                meanDiff = sum / (3.0 * sw * sh);
                // Not equal to the last bit: one pass keeps EASU's result in 16-bit floats where
                // two round it to the drawable's format in between, and RCAS magnifies the odd
                // difference where its neighbours nearly cancel — measured on an M4: 0.48/255 on
                // average, and at most 29/255 on 9 pixels of 5.85 million. A mistake in the one-pass
                // version would be whole rows or tiles wrong; this lets a handful of pixels differ.
                fusedOK = broken == 0 && meanDiff <= 1.0 && apart * 10000 <= sw * sh;
                emitApart = apart;
                if (getenv("ANVIL_PREP_DEBUG")) {
                    const NSUInteger wx = worst % sw, wy = worst / sw;
                    note("largest difference %.1f/255 at %lu,%lu of %lux%lu; %lu pixels over 16/255; %lu not numbers",
                         maxDiff, (unsigned long)wx, (unsigned long)wy, (unsigned long)sw, (unsigned long)sh,
                         (unsigned long)apart, (unsigned long)broken);
                    for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
                        const long px = std::clamp((long)wx + dx, 0L, (long)sw - 1), py = std::clamp((long)wy + dy, 0L, (long)sh - 1);
                        const simd_float3 x = unpackPixel(format, (const uint8_t*)a.contents + (py * sw + px) * bpp) * 255.0f;
                        const simd_float3 y = unpackPixel(format, (const uint8_t*)b.contents + (py * sw + px) * bpp) * 255.0f;
                        note("  %+d,%+d  two passes %.1f %.1f %.1f   one pass %.1f %.1f %.1f", dx, dy, x.x, x.y, x.z, y.x, y.y, y.z);
                    }
                }
                [a release];
                [b release];
            }
        }
    }

    // Both timed, taking turns, eight at a time.
    std::vector<double> tSplit, tFused;
    for (int rep = 0; rep < 14; rep++) {
        id<MTLCommandBuffer> cb = run(kAnvilFSRSplit, outSplit, 8);
        if (rep >= 2 && !cb.error) tSplit.push_back((cb.GPUEndTime - cb.GPUStartTime) * 1000.0 / 8);
        if (fusedOK) {
            cb = run(kAnvilFSRFused, outFused, 8);
            if (rep >= 2 && !cb.error) tFused.push_back((cb.GPUEndTime - cb.GPUStartTime) * 1000.0 / 8);
        }
    }
    auto median = [](std::vector<double>& v) { if (v.empty()) return 0.0; std::sort(v.begin(), v.end()); return v[v.size() / 2]; };
    const double splitMs = median(tSplit), fusedMs = median(tFused);
    // One pass only when it is clearly quicker: within 3% is the same, and two passes is
    // what every game has run until now.
    const bool chooseFused = fusedOK && fusedMs > 0 && splitMs > 0 && fusedMs < splitMs * 0.97;
    emit(@{@"event": @"timed", @"pass": chooseFused ? @"fused" : @"split",
           @"split_ms": @(round(splitMs * 1000) / 1000), @"fused_ms": @(round(fusedMs * 1000) / 1000),
           @"fused_ok": @(fusedOK), @"max_diff": @(round(maxDiff * 10) / 10), @"mean_diff": @(round(meanDiff * 1000) / 1000),
           @"pixels_apart": @(emitApart)});

    // Frame generation's pipelines: compiled into the archive with the rest.
    const int fgKernels[] = {kAnvilLumaPyramid, kAnvilOpticalFlow, kAnvilExtrapolate, kAnvilInterpolate,
                             kAnvilFlowToMotion, kAnvilDownsample, kAnvilUpsample};
    int fgReady = 0;
    for (int k : fgKernels) if (![missing containsObject:@(AnvilKernelName(k))]) fgReady++;

    // 4. FSR 3 for every game, on the moving test scene.
    NSMutableDictionary* fsr3 = [NSMutableDictionary dictionaryWithDictionary:
        testFSR3(device, queue, library, archive, format, gw, gh, sw, sh, sharpness, easu, finish, fused, shape,
                 chooseFused ? kAnvilFSRFused : kAnvilFSRSplit, gameAA)];
    NSMutableDictionary* event = [fsr3 mutableCopy];
    event[@"event"] = @"fsr3";
    emit(event);
    [event release];

    NSMutableDictionary* done = [NSMutableDictionary dictionaryWithDictionary:@{
        @"event": @"done", @"pass": chooseFused ? @"fused" : @"split", @"tested": @YES,
        @"tile": [NSString stringWithFormat:@"%lux%lu", (unsigned long)shape.width, (unsigned long)shape.height],
        @"frame_generation": @(fgReady), @"frame_generation_of": @(sizeof(fgKernels) / sizeof(fgKernels[0]))}];
    [done addEntriesFromDictionary:fsr3];
    emit(done);
    return 0;
}

// --- verify -------------------------------------------------------------------------------

static int verify(int argc, char** argv) {
    if (argc < 3) return fail(@"usage: anvil-prep verify <archive>");
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return fail(@"Metal has no GPU to give this process");
    double compileMs = 0;
    id<MTLLibrary> library = AnvilShaderLibrary(device, note, &compileMs);
    if (!library) return fail(@"Anvil's shaders didn't compile");
    id<MTLBinaryArchive> archive = AnvilOpenArchive(device, argv[2], note);
    if (!archive) return fail(@"the archive didn't open");
    int made = 0, ready = 0;
    const CFTimeInterval t0 = CACurrentMediaTime();
    for (int k = 0; k < kAnvilKernelCount; k++) {
        bool fromArchive = false;
        id<MTLComputePipelineState> p = AnvilPipeline(device, library, k, archive, &fromArchive);
        if (p) made++;
        if (fromArchive) ready++;
        [p release];
    }
    emit(@{@"event": @"verified", @"arch": @(arch()), @"ready": @(ready), @"of": @(kAnvilKernelCount), @"made": @(made),
           @"compile_ms": @(lrint(compileMs)), @"pipelines_ms": @(round((CACurrentMediaTime() - t0) * 10000) / 10)});
    return ready == kAnvilKernelCount ? 0 : 4;
}

int main(int argc, char** argv) {
    @autoreleasepool {
        // However the GPU behaves, never longer than this: Anvil is waiting with a game to start.
        alarm(90);
        if (argc >= 2 && !strcmp(argv[1], "prepare")) return prepare(argc, argv);
        if (argc >= 2 && !strcmp(argv[1], "verify")) return verify(argc, argv);
        return fail(@"usage: anvil-prep prepare|verify …");
    }
}

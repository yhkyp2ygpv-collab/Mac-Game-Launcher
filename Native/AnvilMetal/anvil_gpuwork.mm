// What the GPU does with a game's frames — and textures made sharp for FSR.
//
// 1. Texture detail for FSR. A game drawn at half the display's width and upscaled picks its
//    textures' mip levels for the size it draws at, so every texture is a level blurrier than
//    the picture FSR builds from it: on 12 October LEGO Star Wars' tree bark at Endor was a
//    smear of brown at 1512x982 upscaled to 3024x1964. AMD's guidance for FSR is a negative
//    mip bias of log2(drawn ÷ shown) — the level the display's own size would pick — and
//    D3DMetal has no bias of its own to set (D3DM_LOD_BIAS only switches the game's on). Since
//    macOS 26 a Metal sampler carries a bias, so each sampler D3DMetal makes for the game's
//    filtered, mipmapped textures gets ANVIL_LOD_BIAS added (−1 at 2×) and its anisotropic
//    filtering raised to ANVIL_ANISOTROPY (8×), which keeps ground and walls seen at an angle
//    sharp too. Comparison samplers (shadow maps), unfiltered ones and textures without mip
//    levels (lookup tables, the interface) are left exactly as asked for.
//
// 2. Shader compiles. Every pipeline the game has built (mesh pipelines too, D3DMetal's for geometry
//    shaders, since 0.58) — on the thread that asked, which
//    for a draw is the game's render thread, so the frame waits — is timed: how many, how long
//    in all, the longest, how many failed. A stutter as a new area loads reads as "shaders
//    compiled 14 (310 ms, longest 120 ms)" in that stretch of game.log.
//
// 3. Where the GPU time goes. One frame in every two seconds, each render and compute pass is
//    timed on the GPU itself with Metal's timestamp counters at the pass's start and end (the
//    stage boundaries Apple GPUs sample at), and put in a kind by what it draws into: shadows
//    (square targets, or depth alone at another size), the scene (colour and depth at the
//    game's size), full-size effects (colour without depth: lighting, anti-aliasing, tone),
//    smaller effects (bloom, ambient occlusion at reduced size), compute, and Anvil's own (FSR
//    and frame generation). Only the profiled frame's pass descriptors are copied; every other
//    frame goes through untouched. In a heavy stretch the three passes that took longest in its
//    heaviest timed frame are named too, with what they draw into: in LEGO Star Wars' heaviest
//    scene on 13 October (18–23 fps for twelve minutes, "lots of shadows") "the scene" was 28–36
//    ms of a frame, and which of its passes that was is what decides what can be done about it.
//
// 4. The frame's anatomy (0.52), once a session: one timed frame's passes in order — see collect().
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <objc/runtime.h>
#include <mach/mach_time.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <vector>

/// Whether a texture is the picture the game draws to be shown — a stand-in for one of the layer's drawables
/// (anvil_inject.mm).
extern "C" bool AnvilIsShownPicture(void* texture);

namespace {

// --- Settings ----------------------------------------------------------------------------------

float g_lodBias = 0.0f;          // ANVIL_LOD_BIAS: added to filtered, mipmapped samplers (≤ 0)
int g_anisotropy = 0;            // ANVIL_ANISOTROPY: at least this much, where filtered and mipmapped
bool g_profile = true;           // ANVIL_GPU_PROFILE=0 turns the pass timing off

void readSettings() {
    static std::once_flag once;
    std::call_once(once, [] {
        if (const char* e = getenv("ANVIL_LOD_BIAS")) g_lodBias = std::clamp(static_cast<float>(atof(e)), -3.0f, 0.0f);
        if (const char* e = getenv("ANVIL_ANISOTROPY")) g_anisotropy = std::clamp(atoi(e), 0, 16);
        if (const char* e = getenv("ANVIL_GPU_PROFILE")) g_profile = e[0] != '0';
    });
}

double nowSeconds() {
    static mach_timebase_info_data_t tb = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
    return static_cast<double>(mach_absolute_time()) * tb.numer / tb.denom * 1e-9;
}

// --- 1. Samplers -------------------------------------------------------------------------------

IMP g_originalSampler = nullptr;
std::atomic<int> g_samplersSeen{0}, g_samplersSharpened{0};

bool sharpenable(MTLSamplerDescriptor* d) {
    return d.mipFilter != MTLSamplerMipFilterNotMipmapped && d.minFilter == MTLSamplerMinMagFilterLinear
        && d.compareFunction == MTLCompareFunctionNever && d.normalizedCoordinates && d.lodMaxClamp > 0.0f;
}

id hookedNewSampler(id self, SEL cmd, MTLSamplerDescriptor* d) {
    auto original = (id (*)(id, SEL, MTLSamplerDescriptor*))g_originalSampler;
    if (!d) return original(self, cmd, d);
    g_samplersSeen.fetch_add(1, std::memory_order_relaxed);
    if ((g_lodBias == 0.0f && g_anisotropy <= 1) || !sharpenable(d)) return original(self, cmd, d);
    MTLSamplerDescriptor* sharp = [d copy];
    bool changed = false;
    if (g_lodBias != 0.0f) {
        if (@available(macOS 26.0, *)) { sharp.lodBias = d.lodBias + g_lodBias; changed = true; }
    }
    if (g_anisotropy > 1 && d.mipFilter == MTLSamplerMipFilterLinear && d.maxAnisotropy < static_cast<NSUInteger>(g_anisotropy)) {
        sharp.maxAnisotropy = static_cast<NSUInteger>(g_anisotropy);
        changed = true;
    }
    id state = original(self, cmd, changed ? sharp : d);
    [sharp release];
    if (changed) g_samplersSharpened.fetch_add(1, std::memory_order_relaxed);
    return state;
}

// --- 2. Shader compiles ------------------------------------------------------------------------

struct Compiles {
    std::atomic<uint64_t> count{0}, ns{0}, longest{0}, failed{0};
    void add(uint64_t took, bool ok) {
        count.fetch_add(1, std::memory_order_relaxed);
        ns.fetch_add(took, std::memory_order_relaxed);
        uint64_t was = longest.load(std::memory_order_relaxed);
        while (took > was && !longest.compare_exchange_weak(was, took, std::memory_order_relaxed)) {}
        if (!ok) failed.fetch_add(1, std::memory_order_relaxed);
    }
};
Compiles g_window, g_session;
std::atomic<int> g_compileBefore{-1}, g_maxCompile{-1};   // Metal's compiles at once, before and after asking for most
thread_local bool t_anvilOwn = false;      // Anvil's own pipelines and passes, not the game's

uint64_t nanos() {
    static mach_timebase_info_data_t tb = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
    return mach_absolute_time() * tb.numer / tb.denom;
}

void noteCompile(uint64_t start, bool ok) {
    if (t_anvilOwn) return;
    const uint64_t took = nanos() - start;
    g_window.add(took, ok);
    g_session.add(took, ok);
}

IMP g_origRender1 = nullptr, g_origRender2 = nullptr, g_origCompute1 = nullptr, g_origCompute2 = nullptr, g_origMesh = nullptr;

id hookedRender1(id self, SEL cmd, MTLRenderPipelineDescriptor* d, NSError** error) {
    const uint64_t t0 = nanos();
    id p = ((id (*)(id, SEL, MTLRenderPipelineDescriptor*, NSError**))g_origRender1)(self, cmd, d, error);
    noteCompile(t0, p != nil);
    return p;
}
id hookedRender2(id self, SEL cmd, MTLRenderPipelineDescriptor* d, MTLPipelineOption o, MTLAutoreleasedRenderPipelineReflection* r, NSError** error) {
    const uint64_t t0 = nanos();
    id p = ((id (*)(id, SEL, MTLRenderPipelineDescriptor*, MTLPipelineOption, MTLAutoreleasedRenderPipelineReflection*, NSError**))
                g_origRender2)(self, cmd, d, o, r, error);
    noteCompile(t0, p != nil);
    return p;
}
// The mesh pipelines D3DMetal builds for a game's geometry shaders (0.58): until then untimed, so a stutter compiling
// one read as the game's own work.
id hookedMesh(id self, SEL cmd, MTLMeshRenderPipelineDescriptor* d, MTLPipelineOption o, MTLAutoreleasedRenderPipelineReflection* r,
              NSError** error) {
    const uint64_t t0 = nanos();
    id p = ((id (*)(id, SEL, MTLMeshRenderPipelineDescriptor*, MTLPipelineOption, MTLAutoreleasedRenderPipelineReflection*, NSError**))
                g_origMesh)(self, cmd, d, o, r, error);
    noteCompile(t0, p != nil);
    return p;
}
id hookedCompute1(id self, SEL cmd, id<MTLFunction> f, NSError** error) {
    const uint64_t t0 = nanos();
    id p = ((id (*)(id, SEL, id<MTLFunction>, NSError**))g_origCompute1)(self, cmd, f, error);
    noteCompile(t0, p != nil);
    return p;
}
id hookedCompute2(id self, SEL cmd, MTLComputePipelineDescriptor* d, MTLPipelineOption o, MTLAutoreleasedComputePipelineReflection* r, NSError** error) {
    const uint64_t t0 = nanos();
    id p = ((id (*)(id, SEL, MTLComputePipelineDescriptor*, MTLPipelineOption, MTLAutoreleasedComputePipelineReflection*, NSError**))
                g_origCompute2)(self, cmd, d, o, r, error);
    noteCompile(t0, p != nil);
    return p;
}

/// One method of the device's class, hooked on the class itself; its original kept once.
void hook(Class cls, SEL sel, IMP replacement, IMP* original) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP current = method_getImplementation(m);
    if (current == replacement) return;
    if (*original && current != *original) return;          // a second, different class of device
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(m))) method_setImplementation(m, replacement);
    *original = current;
}

// --- 3. Where the GPU time goes ----------------------------------------------------------------

enum Kind : int { kShadows, kDepth, kScene, kEffects, kSmallEffects, kCompute, kCopies, kAnvil, kKinds };
const char* kKindNames[kKinds] = {"shadows", "depth", "scene", "effects", "smaller effects", "compute", "copies", "Anvil"};

// Metal's most in one sample buffer is 32 KB, 4096 timestamps (measured on the M4, 17 October): 1024 passes. It was 192,
// and LEGO Star Wars' heaviest frames have more — on 16 October a 10 fps stretch read "GPU work 34 ms a frame" with the GPU
// 90% busy at 95 ms a frame, and Anvil's own passes, which come last, read 0.0: the rest of the frame went untimed.
constexpr int kMaxPasses = 1024;
constexpr double kProfileEvery = 2.0;      // seconds between profiled frames

// A render pass is sampled four times — its vertex stage's start and end, its fragment stage's
// start and end — so the wait between them (a pass binned and queued behind another's pixels)
// isn't counted as its work. A compute pass, twice.
struct Pass { int kind; uint32_t start; bool render; char what[72]; bool shown; char load; int depth; };

// The frame's anatomy, once a session (4. below): its passes in order, for the log.
bool g_anatomyDone = false, g_anatomyReady = false;
char g_anatomy[3072] = {};
double g_firstFrameAt = 0.0;
std::vector<void*> g_depthSeen;   // the timed frame's depth targets, numbered as first seen

std::mutex g_profileLock;
std::atomic<bool> g_recording{false};     // g_state == recording, read without the lock
id<MTLDevice> g_device = nil;
id<MTLCounterSampleBuffer> g_samples = nil;
enum class Profile { idle, recording, done } g_state = Profile::idle;
std::vector<Pass> g_passes;
double g_recordedAt = 0.0, g_doneAt = 0.0;
MTLTimestamp g_cpu0 = 0, g_gpu0 = 0;
double g_gameW = 0.0, g_gameH = 0.0;
bool g_profileFailed = false;

// Sums since the stats line last asked: per kind, the frames timed, and their span.
double g_kindMs[kKinds] = {};
double g_frameMs = 0.0;
int g_framesTimed = 0, g_passesTimed = 0;
// The heaviest timed frame since the stats line last asked: its three longest passes.
struct Heavy { int kind; double ms; char what[72]; };
Heavy g_heaviest[3] = {};
double g_heaviestFrameMs = 0.0;

IMP g_origRenderEncoder = nullptr, g_origParallelEncoder = nullptr, g_origCompute = nullptr,
    g_origComputeType = nullptr, g_origComputeDesc = nullptr, g_origBlit = nullptr, g_origBlitDesc = nullptr;

bool ensureSamples() {
    if (g_samples || g_profileFailed) return g_samples != nil;
    g_profileFailed = true;
    if (!g_device || ![g_device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) return false;
    @autoreleasepool {
    id<MTLCounterSet> timestamps = nil;
    for (id<MTLCounterSet> set in g_device.counterSets)
        if ([set.name isEqualToString:MTLCommonCounterSetTimestamp]) timestamps = set;
    if (!timestamps) return false;
    MTLCounterSampleBufferDescriptor* d = [MTLCounterSampleBufferDescriptor new];
    d.counterSet = timestamps;
    d.storageMode = MTLStorageModeShared;
    d.sampleCount = 4 * kMaxPasses;
    d.label = @"Anvil GPU work";
    NSError* error = nil;
    g_samples = [g_device newCounterSampleBufferWithDescriptor:d error:&error];
    [d release];
    }
    g_profileFailed = g_samples == nil;
    return g_samples != nil;
}

/// Slots for this pass's samples, while a frame is being timed. `what`: what it draws into; for a render pass, whether
/// it draws into the picture shown, how (`load`: L kept, C cleared, D neither), and its depth target (0: none).
bool takeSlot(int kind, bool render, uint32_t* start, const char* what = "", bool shown = false, char load = 0, void* depth = nullptr) {
    std::lock_guard<std::mutex> hold(g_profileLock);
    if (g_state != Profile::recording || static_cast<int>(g_passes.size()) >= kMaxPasses || !ensureSamples()) return false;
    *start = static_cast<uint32_t>(g_passes.size() * 4);
    int depthId = 0;
    if (depth) {
        auto at = std::find(g_depthSeen.begin(), g_depthSeen.end(), depth);
        if (at == g_depthSeen.end()) { g_depthSeen.push_back(depth); depthId = static_cast<int>(g_depthSeen.size()); }
        else depthId = static_cast<int>(at - g_depthSeen.begin()) + 1;
    }
    Pass p{kind, *start, render, {}, shown, load, depthId};
    strlcpy(p.what, what ? what : "", sizeof p.what);
    g_passes.push_back(p);
    return true;
}

const char* formatName(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatBGRA8Unorm:
    case MTLPixelFormatBGRA8Unorm_sRGB: return "8-bit";
    case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatBGR10A2Unorm: return "10-bit";
    case MTLPixelFormatRG11B10Float: return "11-bit float";
    case MTLPixelFormatRGBA16Float: return "16-bit float";
    case MTLPixelFormatRGBA32Float: return "32-bit float";
    case MTLPixelFormatR16Float: case MTLPixelFormatRG16Float: return "16-bit float, 1–2 channels";
    case MTLPixelFormatR32Float: case MTLPixelFormatRG32Float: return "32-bit float, 1–2 channels";
    case MTLPixelFormatR8Unorm: case MTLPixelFormatRG8Unorm: return "8-bit, 1–2 channels";
    default: return nullptr;
    }
}

/// What a render pass draws into, in a few words: "1512x982, 4 colour (8-bit) + depth".
void describe(MTLRenderPassDescriptor* d, char* out, size_t room) {
    id<MTLTexture> first = nil;
    int colours = 0;
    for (NSUInteger i = 0; i < 8; ++i) {
        id<MTLTexture> t = d.colorAttachments[i].texture;
        if (t) { ++colours; if (!first) first = t; }
    }
    id<MTLTexture> depth = d.depthAttachment.texture ? d.depthAttachment.texture : d.stencilAttachment.texture;
    id<MTLTexture> target = first ? first : depth;
    if (!target) { strlcpy(out, "no target", room); return; }
    int used = snprintf(out, room, "%lux%lu", (unsigned long)target.width, (unsigned long)target.height);
    const NSUInteger slices = d.renderTargetArrayLength > 1 ? d.renderTargetArrayLength
                            : (target.textureType == MTLTextureType2DArray ? target.arrayLength : 1);
    if (slices > 1 && used < (int)room) used += snprintf(out + used, room - used, " x%lu", (unsigned long)slices);
    if (colours && used < (int)room) {
        const char* f = formatName(first.pixelFormat);
        used += f ? snprintf(out + used, room - used, ", %d colour (%s)", colours, f)
                  : snprintf(out + used, room - used, ", %d colour (format %lu)", colours, (unsigned long)first.pixelFormat);
    }
    if (depth && used < (int)room) used += snprintf(out + used, room - used, colours ? " + depth" : ", depth only");
    if (target.sampleCount > 1 && used < (int)room) snprintf(out + used, room - used, ", %lux MSAA", (unsigned long)target.sampleCount);
}

bool profilingNow() { return g_profile && g_recording.load(std::memory_order_relaxed); }

int renderKind(MTLRenderPassDescriptor* d) {
    if (t_anvilOwn) return kAnvil;
    id<MTLTexture> first = nil;
    int colours = 0;
    for (NSUInteger i = 0; i < 8; ++i) {
        id<MTLTexture> t = d.colorAttachments[i].texture;
        if (t) { ++colours; if (!first) first = t; }
    }
    id<MTLTexture> depth = d.depthAttachment.texture ? d.depthAttachment.texture : d.stencilAttachment.texture;
    id<MTLTexture> target = first ? first : depth;
    if (!target) return kEffects;
    const double w = static_cast<double>(target.width), h = static_cast<double>(target.height);
    const bool gameSized = g_gameW > 0 ? (w >= 0.9 * g_gameW && h >= 0.9 * g_gameH) : (w >= 1024 && w != h);
    if (target.textureType == MTLTextureTypeCube || target.textureType == MTLTextureTypeCubeArray) return kSmallEffects;
    // D3DMetal makes every render target a 2D array, one slice for an ordinary one (12 October:
    // every pass of LEGO Star Wars' read as "shadows" until this looked at the slices): only
    // several slices drawn at once — a shadow map's cascades — or a square target are shadows.
    const bool layered = d.renderTargetArrayLength > 1 || (target.textureType == MTLTextureType2DArray && target.arrayLength > 1 && !colours);
    if (layered || (w == h && w >= 512)) return kShadows;
    if (!colours) return gameSized ? kDepth : kShadows;
    if (!gameSized) return kSmallEffects;
    return depth ? kScene : kEffects;
}

MTLRenderPassDescriptor* timed(MTLRenderPassDescriptor* d) {
    if (!d || !profilingNow()) return nil;
    NSUInteger slot = NSNotFound;
    for (NSUInteger i = 0; i < 4; ++i)
        if (!d.sampleBufferAttachments[i].sampleBuffer) { slot = i; break; }
    uint32_t start = 0;
    char what[72];
    describe(d, what, sizeof what);
    id<MTLTexture> colour = d.colorAttachments[0].texture;
    const bool shown = colour && AnvilIsShownPicture((__bridge void*)colour);
    const MTLLoadAction la = d.colorAttachments[0].loadAction;
    const char load = !colour ? 0 : la == MTLLoadActionLoad ? 'L' : la == MTLLoadActionClear ? 'C' : 'D';
    id<MTLTexture> depth = d.depthAttachment.texture;
    if (slot == NSNotFound || !takeSlot(renderKind(d), true, &start, what, shown, load, (__bridge void*)depth)) return nil;
    MTLRenderPassDescriptor* copy = [d copy];
    MTLRenderPassSampleBufferAttachmentDescriptor* a = copy.sampleBufferAttachments[slot];
    a.sampleBuffer = g_samples;
    a.startOfVertexSampleIndex = start;
    a.endOfVertexSampleIndex = start + 1;
    a.startOfFragmentSampleIndex = start + 2;
    a.endOfFragmentSampleIndex = start + 3;
    return copy;
}

id hookedRenderEncoder(id self, SEL cmd, MTLRenderPassDescriptor* d) {
    auto original = (id (*)(id, SEL, MTLRenderPassDescriptor*))g_origRenderEncoder;
    MTLRenderPassDescriptor* copy = timed(d);
    id encoder = original(self, cmd, copy ? copy : d);
    [copy release];
    return encoder;
}
id hookedParallelEncoder(id self, SEL cmd, MTLRenderPassDescriptor* d) {
    auto original = (id (*)(id, SEL, MTLRenderPassDescriptor*))g_origParallelEncoder;
    MTLRenderPassDescriptor* copy = timed(d);
    id encoder = original(self, cmd, copy ? copy : d);
    [copy release];
    return encoder;
}

/// A compute pass through a descriptor with this pass's samples, when one is being timed.
id timedCompute(id self, MTLDispatchType type) {
    if (!g_origComputeDesc || !profilingNow()) return nil;
    uint32_t start = 0;
    if (!takeSlot(t_anvilOwn ? kAnvil : kCompute, false, &start)) return nil;
    MTLComputePassDescriptor* d = [MTLComputePassDescriptor new];
    d.dispatchType = type;
    d.sampleBufferAttachments[0].sampleBuffer = g_samples;
    d.sampleBufferAttachments[0].startOfEncoderSampleIndex = start;
    d.sampleBufferAttachments[0].endOfEncoderSampleIndex = start + 1;
    id encoder = ((id (*)(id, SEL, MTLComputePassDescriptor*))g_origComputeDesc)(self, @selector(computeCommandEncoderWithDescriptor:), d);
    [d release];
    return encoder;
}
id hookedCompute(id self, SEL cmd) {
    if (id e = timedCompute(self, MTLDispatchTypeSerial)) return e;
    return ((id (*)(id, SEL))g_origCompute)(self, cmd);
}
id hookedComputeType(id self, SEL cmd, MTLDispatchType type) {
    if (id e = timedCompute(self, type)) return e;
    return ((id (*)(id, SEL, MTLDispatchType))g_origComputeType)(self, cmd, type);
}
id hookedComputeDesc(id self, SEL cmd, MTLComputePassDescriptor* d) {
    auto original = (id (*)(id, SEL, MTLComputePassDescriptor*))g_origComputeDesc;
    if (!d || !profilingNow()) return original(self, cmd, d);
    NSUInteger slot = NSNotFound;
    for (NSUInteger i = 0; i < 4; ++i)
        if (!d.sampleBufferAttachments[i].sampleBuffer) { slot = i; break; }
    uint32_t start = 0;
    if (slot == NSNotFound || !takeSlot(t_anvilOwn ? kAnvil : kCompute, false, &start)) return original(self, cmd, d);
    MTLComputePassDescriptor* copy = [d copy];
    copy.sampleBufferAttachments[slot].sampleBuffer = g_samples;
    copy.sampleBufferAttachments[slot].startOfEncoderSampleIndex = start;
    copy.sampleBufferAttachments[slot].endOfEncoderSampleIndex = start + 1;
    id encoder = original(self, cmd, copy);
    [copy release];
    return encoder;
}

/// Copies and uploads — textures streamed in as an area loads, buffers filled — timed like a
/// compute pass, through a descriptor with the frame's samples.
id hookedBlit(id self, SEL cmd) {
    if (g_origBlitDesc && profilingNow()) {
        uint32_t start = 0;
        if (takeSlot(t_anvilOwn ? kAnvil : kCopies, false, &start)) {
            MTLBlitPassDescriptor* d = [MTLBlitPassDescriptor new];
            d.sampleBufferAttachments[0].sampleBuffer = g_samples;
            d.sampleBufferAttachments[0].startOfEncoderSampleIndex = start;
            d.sampleBufferAttachments[0].endOfEncoderSampleIndex = start + 1;
            id encoder = ((id (*)(id, SEL, MTLBlitPassDescriptor*))g_origBlitDesc)(self, @selector(blitCommandEncoderWithDescriptor:), d);
            [d release];
            return encoder;
        }
    }
    return ((id (*)(id, SEL))g_origBlit)(self, cmd);
}
id hookedBlitDesc(id self, SEL cmd, MTLBlitPassDescriptor* d) {
    auto original = (id (*)(id, SEL, MTLBlitPassDescriptor*))g_origBlitDesc;
    if (!d || !profilingNow()) return original(self, cmd, d);
    NSUInteger slot = NSNotFound;
    for (NSUInteger i = 0; i < 4; ++i)
        if (!d.sampleBufferAttachments[i].sampleBuffer) { slot = i; break; }
    uint32_t start = 0;
    if (slot == NSNotFound || !takeSlot(t_anvilOwn ? kAnvil : kCopies, false, &start)) return original(self, cmd, d);
    MTLBlitPassDescriptor* copy = [d copy];
    copy.sampleBufferAttachments[slot].sampleBuffer = g_samples;
    copy.sampleBufferAttachments[slot].startOfEncoderSampleIndex = start;
    copy.sampleBufferAttachments[slot].endOfEncoderSampleIndex = start + 1;
    id encoder = original(self, cmd, copy);
    [copy release];
    return encoder;
}

/// The timed frame's samples read back — it finished on the GPU long ago — and added up.
void collect() {
    if (!g_samples || g_passes.empty()) { g_passes.clear(); return; }
    @autoreleasepool {
    MTLTimestamp cpu1 = 0, gpu1 = 0;
    [g_device sampleTimestamps:&cpu1 gpuTimestamp:&gpu1];
    double nsPerTick = 1.0;
    if (gpu1 > g_gpu0 && cpu1 > g_cpu0) nsPerTick = static_cast<double>(cpu1 - g_cpu0) / static_cast<double>(gpu1 - g_gpu0);
    if (!(nsPerTick > 0.01 && nsPerTick < 100.0)) nsPerTick = 1.0;
    NSData* data = [g_samples resolveCounterRange:NSMakeRange(0, g_passes.size() * 4)];
    if (!data || data.length < g_passes.size() * 4 * sizeof(MTLCounterResultTimestamp)) { g_passes.clear(); return; }
    const auto* t = static_cast<const MTLCounterResultTimestamp*>(data.bytes);
    // Passes the GPU runs side by side overlap in time, so each one's own start-to-end can't be
    // added up. The frame is swept from its first pass's start to its last one's end, and every
    // stretch is shared out among the passes running in it: a kind's figure is its part of the
    // time the GPU was busy, and the kinds add up to that.
    struct Edge { uint64_t at; int pass; int delta; };
    std::vector<Edge> edges;
    edges.reserve(g_passes.size() * 4);
    int good = 0;
    auto span = [&](uint64_t a, uint64_t b, int pass) {
        if (a == MTLCounterErrorValue || b == MTLCounterErrorValue || a == 0 || b <= a) return false;
        if (static_cast<double>(b - a) * nsPerTick > 1e9) return false;
        edges.push_back({a, pass, +1});
        edges.push_back({b, pass, -1});
        return true;
    };
    for (size_t i = 0; i < g_passes.size(); ++i) {
        const Pass& p = g_passes[i];
        bool any = span(t[p.start].timestamp, t[p.start + 1].timestamp, (int)i);
        if (p.render) any = span(t[p.start + 2].timestamp, t[p.start + 3].timestamp, (int)i) || any;
        if (any) ++good;
    }
    std::sort(edges.begin(), edges.end(), [](const Edge& x, const Edge& y) { return x.at != y.at ? x.at < y.at : x.delta < y.delta; });
    // Each stretch shared out among the passes running in it; a kind's figure is its passes'.
    std::vector<double> share(g_passes.size(), 0.0);
    std::vector<int> running(g_passes.size(), 0);
    int active = 0;
    uint64_t last = 0;
    double busyMs = 0.0;
    for (const Edge& e : edges) {
        if (active > 0 && e.at > last) {
            const double ms = static_cast<double>(e.at - last) * nsPerTick * 1e-6;
            busyMs += ms;
            for (size_t i = 0; i < running.size(); ++i)
                if (running[i]) share[i] += ms * running[i] / active;
        }
        running[e.pass] += e.delta;
        active += e.delta;
        last = e.at;
    }
    double kinds[kKinds] = {};
    for (size_t i = 0; i < g_passes.size(); ++i) kinds[g_passes[i].kind] += share[i];
    if (good && busyMs > g_heaviestFrameMs) {
        // The heaviest frame yet in this stretch: its three longest passes, Anvil's own left out.
        g_heaviestFrameMs = busyMs;
        for (Heavy& h : g_heaviest) h = Heavy{0, 0.0, {}};
        for (size_t i = 0; i < g_passes.size(); ++i) {
            if (g_passes[i].kind == kAnvil) continue;
            for (int slot = 0; slot < 3; ++slot) {
                if (share[i] <= g_heaviest[slot].ms) continue;
                for (int j = 2; j > slot; --j) g_heaviest[j] = g_heaviest[j - 1];
                g_heaviest[slot].kind = g_passes[i].kind;
                g_heaviest[slot].ms = share[i];
                strlcpy(g_heaviest[slot].what, g_passes[i].what, sizeof g_heaviest[slot].what);
                break;
            }
        }
    }
    // 4. The frame's anatomy, once a session, from a frame of the game's 3D world a minute in: its passes in order,
    // what each draws into and its share of the GPU's time, which share a depth target, and which draw into the
    // picture shown — the game's last passes, where a HUD is drawn over the finished scene. Where an effect of
    // Anvil's own that needs the scene's depth (screen-space ray-traced light) could go in, under the HUD.
    if (!g_anatomyDone && good && g_firstFrameAt > 0.0 && nowSeconds() - g_firstFrameAt > 60.0
        && std::any_of(g_passes.begin(), g_passes.end(), [](const Pass& p) { return p.kind == kScene; }) && g_passes.size() >= 6) {
        g_anatomyDone = true;
        int used = snprintf(g_anatomy, sizeof g_anatomy, "%zu passes, %.1f ms of GPU time:", g_passes.size(), busyMs);
        for (size_t i = 0; i < g_passes.size() && used < (int)sizeof g_anatomy - 1; ) {
            // Passes alike in a row, as one: "×4".
            size_t j = i + 1;
            double ms = share[i];
            while (j < g_passes.size() && g_passes[j].kind == g_passes[i].kind && g_passes[j].shown == g_passes[i].shown
                   && g_passes[j].depth == g_passes[i].depth && !strcmp(g_passes[j].what, g_passes[i].what)) ms += share[j++];
            const Pass& p = g_passes[i];
            char extra[64] = {};
            int e = 0;
            if (p.depth) e += snprintf(extra + e, sizeof extra - e, ", depth #%d", p.depth);
            if (p.shown) e += snprintf(extra + e, sizeof extra - e, ", INTO THE PICTURE SHOWN%s", p.load == 'L' ? " (over what's there)" : p.load == 'C' ? " (cleared first)" : "");
            used += snprintf(g_anatomy + used, sizeof g_anatomy - used, "%s %zu%s %s %.2f ms%s%s%s%s", i ? ";" : "", i + 1,
                             j - i > 1 ? ("–" + std::to_string(j)).c_str() : "", kKindNames[p.kind], ms,
                             p.what[0] ? " (" : "", p.what, p.what[0] ? ")" : "", extra);
            i = j;
        }
        g_anatomyReady = true;
    }
    g_passes.clear();
    g_depthSeen.clear();
    if (!good) return;
    for (int k = 0; k < kKinds; ++k) g_kindMs[k] += kinds[k];
    g_frameMs += busyMs;
    g_framesTimed += 1;
    g_passesTimed += good;
    }
}

} // namespace

// --- Called from the rest of libanvil ----------------------------------------------------------

extern "C" void AnvilOwnGpuWork(bool own);
extern "C" void (*AnvilShaderSetOwnHook)(bool);

/// The device D3DMetal made, as it is made (anvil_guard.mm): samplers and pipeline compiles.
extern "C" void AnvilWatchDevice(id<MTLDevice> device) {
    if (!device) return;
    readSettings();
    AnvilShaderSetOwnHook = &AnvilOwnGpuWork;
    static std::mutex lock;
    std::lock_guard<std::mutex> hold(lock);
    if (!g_device) g_device = [device retain];
    // The game's shaders compiled on as many of the Mac's cores at once as Metal allows (0.55). A game through
    // D3DMetal makes its pipelines as it first draws with them, several threads at a time: LEGO Star Wars' stutters
    // of 16 October were 25 of 30 its compiles — 38 shaders in 168 ms in a frame of 66, where they'd been 9 ms —
    // and Metal may compile on fewer threads than it could. On an M4 it already allowed 10 at once, its most, under
    // Rosetta (Anvil's stand-in, 16 October): there asking changes nothing. What it does is Metal's to say.
    if (g_maxCompile.load() < 0 && [device respondsToSelector:@selector(setShouldMaximizeConcurrentCompilation:)]) {
        if (@available(macOS 13.3, *)) {
            const NSUInteger before = device.maximumConcurrentCompilationTaskCount;
            device.shouldMaximizeConcurrentCompilation = YES;
            g_compileBefore = (int)before;
            g_maxCompile = (int)device.maximumConcurrentCompilationTaskCount;
        }
    }
    Class cls = object_getClass(device);
    hook(cls, @selector(newSamplerStateWithDescriptor:), (IMP)hookedNewSampler, &g_originalSampler);
    hook(cls, @selector(newRenderPipelineStateWithDescriptor:error:), (IMP)hookedRender1, &g_origRender1);
    hook(cls, @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:), (IMP)hookedRender2, &g_origRender2);
    if (@available(macOS 13.0, *))
        hook(cls, @selector(newRenderPipelineStateWithMeshDescriptor:options:reflection:error:), (IMP)hookedMesh, &g_origMesh);
    hook(cls, @selector(newComputePipelineStateWithFunction:error:), (IMP)hookedCompute1, &g_origCompute1);
    hook(cls, @selector(newComputePipelineStateWithDescriptor:options:reflection:error:), (IMP)hookedCompute2, &g_origCompute2);
}

/// The game's command buffers' class, from the first one seen (anvil_inject.mm): its passes.
extern "C" void AnvilWatchCommandBuffers(Class cls) {
    readSettings();
    if (!cls || !g_profile) return;
    static std::mutex lock;
    std::lock_guard<std::mutex> hold(lock);
    hook(cls, @selector(computeCommandEncoderWithDescriptor:), (IMP)hookedComputeDesc, &g_origComputeDesc);
    hook(cls, @selector(renderCommandEncoderWithDescriptor:), (IMP)hookedRenderEncoder, &g_origRenderEncoder);
    hook(cls, @selector(parallelRenderCommandEncoderWithDescriptor:), (IMP)hookedParallelEncoder, &g_origParallelEncoder);
    hook(cls, @selector(computeCommandEncoder), (IMP)hookedCompute, &g_origCompute);
    hook(cls, @selector(computeCommandEncoderWithDispatchType:), (IMP)hookedComputeType, &g_origComputeType);
    hook(cls, @selector(blitCommandEncoderWithDescriptor:), (IMP)hookedBlitDesc, &g_origBlitDesc);
    hook(cls, @selector(blitCommandEncoder), (IMP)hookedBlit, &g_origBlit);
}

/// Anvil's own pipelines and passes (FSR, frame generation) from here until `false`.
extern "C" void AnvilOwnGpuWork(bool own) { t_anvilOwn = own; }

/// The size the game draws at, once a frame has shown it: what "the scene" is measured against.
extern "C" void AnvilGpuGameSize(double width, double height) { g_gameW = width; g_gameH = height; }

/// A frame of the game's ended (presented, with Anvil's own passes after it). Every two seconds
/// the next frame is timed; a timed frame is read back at the frame half a second after it.
extern "C" void AnvilGpuFrameEnd() {
    if (!g_profile || !g_device) return;
    std::lock_guard<std::mutex> hold(g_profileLock);
    const double now = nowSeconds();
    if (g_firstFrameAt == 0.0) g_firstFrameAt = now;
    switch (g_state) {
    case Profile::recording:
        g_state = Profile::done;
        g_recording.store(false, std::memory_order_relaxed);
        g_doneAt = now;
        break;
    case Profile::done:
        if (now - g_doneAt >= 0.5) { collect(); g_state = Profile::idle; }
        break;
    case Profile::idle:
        if (now - g_recordedAt >= kProfileEvery && !g_profileFailed) {
            g_passes.clear();
            [g_device sampleTimestamps:&g_cpu0 gpuTimestamp:&g_gpu0];
            g_recordedAt = now;
            g_state = Profile::recording;
            g_recording.store(true, std::memory_order_relaxed);
        }
        break;
    }
}

/// The frame's anatomy, once, when it's been read (4. above): true with it in `out`.
extern "C" bool AnvilGpuFrameAnatomy(char* out, size_t room) {
    std::lock_guard<std::mutex> hold(g_profileLock);
    if (!g_anatomyReady) return false;
    g_anatomyReady = false;
    strlcpy(out, g_anatomy, room);
    return true;
}

/// For the stats line: the shader compiles and the GPU's frame since the last one asked.
extern "C" int AnvilGpuWorkWindow(char* out, size_t room) {
    int used = 0;
    const uint64_t n = g_window.count.exchange(0), ns = g_window.ns.exchange(0), longest = g_window.longest.exchange(0),
                   failed = g_window.failed.exchange(0);
    if (n > 0 && used < static_cast<int>(room)) {
        const std::string failedText = failed ? ", " + std::to_string(failed) + " failed" : "";
        used += snprintf(out + used, room - used, " | shaders compiled %llu (%.0f ms, longest %.0f ms%s)",
                         static_cast<unsigned long long>(n), ns * 1e-6, longest * 1e-6, failedText.c_str());
    }
    std::lock_guard<std::mutex> hold(g_profileLock);
    if (g_framesTimed > 0 && used < static_cast<int>(room)) {
        used += snprintf(out + used, room - used, " | GPU work %.1f ms a frame:", g_frameMs / g_framesTimed);
        int order[kKinds];
        for (int k = 0; k < kKinds; ++k) order[k] = k;
        std::sort(order, order + kKinds, [](int a, int b) { return g_kindMs[a] > g_kindMs[b]; });
        bool firstKind = true;
        for (int i = 0; i < kKinds && used < static_cast<int>(room); ++i) {
            const int k = order[i];
            const double ms = g_kindMs[k] / g_framesTimed;
            if (ms < 0.05) continue;
            used += snprintf(out + used, room - used, "%s %s %.1f", firstKind ? "" : ",", kKindNames[k], ms);
            firstKind = false;
        }
        // In a heavy stretch — its heaviest frame's GPU work past what 70 fps allows — the passes
        // that took longest in it, by name.
        if (g_heaviestFrameMs >= 14.0 && g_heaviest[0].ms > 0.0 && used < static_cast<int>(room)) {
            used += snprintf(out + used, room - used, " | heaviest passes (of a %.1f ms frame):", g_heaviestFrameMs);
            for (int i = 0; i < 3 && used < static_cast<int>(room); ++i) {
                const Heavy& h = g_heaviest[i];
                if (h.ms < 0.3) break;
                used += snprintf(out + used, room - used, "%s %s %.1f ms%s%s%s", i ? ";" : "", kKindNames[h.kind], h.ms,
                                 h.what[0] ? " (" : "", h.what, h.what[0] ? ")" : "");
            }
        }
        for (double& v : g_kindMs) v = 0.0;
        g_frameMs = 0.0;
        g_framesTimed = 0;
        g_passesTimed = 0;
        g_heaviestFrameMs = 0.0;
        for (Heavy& h : g_heaviest) h = Heavy{0, 0.0, {}};
    }
    return used;
}

/// Once, for the log: what the texture detail did.
extern "C" void AnvilTextureDetailReport(int* seen, int* sharpened, float* bias, int* anisotropy) {
    readSettings();
    *seen = g_samplersSeen.load();
    *sharpened = g_samplersSharpened.load();
    *bias = g_lodBias;
    *anisotropy = g_anisotropy;
}

/// How many of the game's shaders Metal compiles at once, before Anvil asked for as many as it can and after
/// (-1, -1: not asked — a Metal without the setting).
extern "C" void AnvilCompileConcurrency(int* before, int* after) {
    *before = g_compileBefore.load();
    *after = g_maxCompile.load();
}

/// The session's shader compiles, for the closing line.
extern "C" void AnvilCompileTotals(uint64_t* count, double* ms, double* longestMs, uint64_t* failed) {
    *count = g_session.count.load();
    *ms = g_session.ns.load() * 1e-6;
    *longestMs = g_session.longest.load() * 1e-6;
    *failed = g_session.failed.load();
}

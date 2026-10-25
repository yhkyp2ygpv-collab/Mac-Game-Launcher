// Anvil's compute shaders as one set, shared by libanvil (in the game) and anvil-prep
// (Graphics Prep, before it): where the library comes from and how it is compiled, the
// kernels in it, how a pipeline is made — from Graphics Prep's archive when it holds one —
// and how FSR is encoded. What Graphics Prep compiles, checks and times is then exactly
// what the game runs.
//
// Manual retain/release, as libanvil is: a function that makes an object returns it +1.
#pragma once
#import <Metal/Metal.h>
#include <simd/simd.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*AnvilShaderNote)(const char* format, ...);

/// The library, from where the environment says: ANVIL_METALLIB, else the source in
/// ANVIL_METAL_SOURCE, else the public edition's ANVIL_METAL_PACK. `compileMs`, when given,
/// is how long a compile from source took (0 for a precompiled library). nil if none loads.
id<MTLLibrary> AnvilShaderLibrary(id<MTLDevice> device, AnvilShaderNote note, double* compileMs)
    __attribute__((ns_returns_retained));

enum {
    kAnvilRcas, kAnvilEasu, kAnvilFsrEasu, kAnvilFsrFused, kAnvilOverlay, kAnvilFinish,
    kAnvilCounter, kAnvilFlowToMotion, kAnvilDownsample, kAnvilUpsample, kAnvilLumaPyramid,
    kAnvilOpticalFlow, kAnvilInterpolate, kAnvilExtrapolate,
    kAnvilFsr3Luma, kAnvilFsr3Motion, kAnvilFsr3Settle, kAnvilFsr3Resolve, kAnvilFsr3Wide,
    kAnvilMidpoint, kAnvilMidpointCheck, kAnvilMidpointJudge,
    kAnvilFsr3PanCost, kAnvilFsr3PanPick, kAnvilFsr3PanFineCost, kAnvilFsr3PanFinePick,
    kAnvilAhead,
    kAnvilKernelCount
};
const char* AnvilKernelName(int kernel);

/// How a kernel's pipeline is described — the same in the game and in Graphics Prep, so
/// a pipeline in the archive is found again. +1, or nil when the library hasn't the kernel.
MTLComputePipelineDescriptor* AnvilPipelineDescriptor(id<MTLLibrary> library, int kernel)
    __attribute__((ns_returns_retained));

/// A kernel's pipeline: taken ready-made from `archive` when it holds it (`*fromArchive`
/// set), else compiled. nil when the library hasn't the kernel or it doesn't compile.
id<MTLComputePipelineState> AnvilPipeline(id<MTLDevice> device, id<MTLLibrary> library, int kernel,
                                          id<MTLBinaryArchive> archive, bool* fromArchive)
    __attribute__((ns_returns_retained));

/// Graphics Prep's archive at `path`, if Metal opens it. nil otherwise — then every
/// pipeline compiles as it always has.
id<MTLBinaryArchive> AnvilOpenArchive(id<MTLDevice> device, const char* path, AnvilShaderNote note)
    __attribute__((ns_returns_retained));

/// FSR's two ways: EASU into a scratch texture and RCAS from it, or both in one dispatch
/// with the upscaled tile kept in threadgroup memory (anvil_fsr_fused).
enum { kAnvilFSRSplit = 0, kAnvilFSRFused = 1 };

/// The threadgroup shape the one-pass FSR runs in: `wanted` if the pipeline and the GPU
/// take it, else the largest of 32x16, 16x16, 16x8 and 8x8 that does; zero width if none.
MTLSize AnvilFusedShape(id<MTLComputePipelineState> fused, id<MTLDevice> device, MTLSize wanted);

/// The threadgroup memory the one-pass FSR needs at a shape: its tile and a texel of border.
NSUInteger AnvilFusedMemory(MTLSize shape);

/// A full-coverage 2D dispatch, in the pipeline's widest shape.
void AnvilDispatch2D(id<MTLComputeCommandEncoder> enc, id<MTLComputePipelineState> pso,
                     NSUInteger width, NSUInteger height);

/// FSR from `input` (the game's size) into `target` (the display's), in an open compute
/// encoder: through `scratch` (the target's size and format) in two passes, or in one.
/// params: x = sharpness, y = fps, z = counter scale, w = counter corner (negative: none).
void AnvilEncodeFSR(id<MTLComputeCommandEncoder> enc, int pass, MTLSize fusedShape,
                    id<MTLComputePipelineState> easu, id<MTLComputePipelineState> finish,
                    id<MTLComputePipelineState> fused,
                    id<MTLTexture> input, id<MTLTexture> scratch, id<MTLTexture> target,
                    simd_float4 params);

/// FSR 3 for every game (AnvilShaders.metal, "FSR 3 for every game"): the temporal pass's
/// pipelines and textures for one pair of sizes — the game's frame and the display's — and
/// which of each pair of textures this frame writes. Zeroed to start; AnvilFSR3Free lets
/// everything go.
typedef struct AnvilFSR3 {
    id<MTLComputePipelineState> luma, flow, motion, settle, resolve;     // not owned
    id<MTLComputePipelineState> widen;  // not owned; nil leaves out the widest search (below)
    id<MTLComputePipelineState> panCost, panPick, panFineCost, panFinePick;   // not owned; nil leaves out the pan (below)
    id<MTLTexture> plane[2], coarsePlane[2], coarse, raw, fine[2];       // from the game's frame
    // The widest search: the luma plane through a Gaussian, a quarter its size each way — 8
    // game pixels a pixel at the usual scale, where a repeating pattern has blurred away —
    // searched in blocks of 64 game pixels.
    id<MTLTexture> widePlane[2], wide;
    // The pan: the whole picture's motion, scored at every offset of the widest plane over all of it — what a
    // block of gentle shading over a repeating floor can't tell — and picked: anvil_fsr3_pan_cost/_pick.
    id<MTLTexture> panCostTex, panCoarse, panFineTex, pan;
    id<MTLTexture> history[2];                                           // at the display's size
    NSUInteger width, height;           // the game's frame
    NSUInteger outWidth, outHeight;     // the display's
    int scale;                          // game pixels per pixel of the luma plane motion is matched on
    MTLSize shape;                      // the resolve pass's threadgroup
    int current;      // the pair member this frame writes; the other holds the last frame's
    int frames;       // frames since the history started over
    // How it blends — zero takes the defaults below. Tuned on Graphics Prep's moving test
    // scene on an M4 (see anvil_prep.mm).
    float maxFrames;  // the most frames a pixel's history holds
    float clip;       // how far past its neighbourhood's spread, in standard deviations, a history colour is believed
    float agree;      // what a pixel of disagreement with neighbouring blocks' motion costs (anvil_fsr3_settle)
    float prior;      // what a pixel of motion costs a guess other than last frame's (anvil_fsr3_motion)
    float bright;     // how much less a bright sample counts in the blend (negative: not at all)
    bool given;       // tests only: this frame's motion is already in fine[current] — don't measure it
    int only;         // tests only: 1 the motion passes alone, 2 the resolve pass alone (0: both)
    int askScale;     // tests only: the luma plane's scale to use (0: chosen by size)
} AnvilFSR3;

#define kAnvilFSR3Frames 10.0f          // upscaling
#define kAnvilFSR3FramesNative 5.0f     // at the display's own size, where a shorter memory measured better
// A game that smooths its own edges over time (its own temporal AA on) hands over frames already
// blended: ten more on top lost to FSR 1 on Graphics Prep's scene drawn anti-aliased (11 October,
// 7.72 against 7.24, and trailing more around the moving disc); three beat it at every speed.
#define kAnvilFSR3FramesGameAA 3.0f
#define kAnvilFSR3Clip 1.0f
#define kAnvilFSR3Agree 0.003f
#define kAnvilFSR3Prior 0.0005f

/// Textures for the game's frames at `width` x `height` shown at `outWidth` x `outHeight`
/// (the same, at the display's own size): kept while the sizes hold, made again (and the
/// history started over) when they change. False when the GPU hasn't room for them.
bool AnvilFSR3Ensure(AnvilFSR3* fsr3, id<MTLDevice> device, NSUInteger width, NSUInteger height,
                     NSUInteger outWidth, NSUInteger outHeight);

/// The next frame starts a new history: shown as it is, with nothing blended in.
void AnvilFSR3Reset(AnvilFSR3* fsr3);

/// FSR 3 from `input` (the game's frame, `width` x `height`, read as encoded) into `target`
/// (`outWidth` x `outHeight`, the frame shown) in an open compute encoder: motion measured,
/// the frame upscaled with EASU, sharpened with RCAS and blended with the picture so far, and
/// the counter drawn over it. params as AnvilEncodeFSR's. False when a pipeline is missing or
/// a size doesn't match — nothing encoded then.
bool AnvilEncodeFSR3(AnvilFSR3* fsr3, id<MTLComputeCommandEncoder> enc, id<MTLTexture> input,
                     id<MTLTexture> target, simd_float4 params);

/// This frame's picture without the counter, as the next frame will blend with it: 16-bit
/// float at the display's size, owned by `fsr3`. nil before a frame is encoded.
id<MTLTexture> AnvilFSR3Picture(const AnvilFSR3* fsr3);

/// The motion the last encoded frame measured — per 16x16 block, x and y in pixels towards
/// where it was a frame earlier, z how far it is trusted — or nil before two frames.
id<MTLTexture> AnvilFSR3Motion(const AnvilFSR3* fsr3);

/// The frame before the last one encoded, as AnvilFSR3Picture had it — kept until the next frame
/// is encoded — or nil before two frames. Smooth Motion makes the frame between it and the last.
id<MTLTexture> AnvilFSR3PictureBefore(const AnvilFSR3* fsr3);

/// The motion that frame measured (towards the one before it), or nil before three frames.
id<MTLTexture> AnvilFSR3MotionBefore(const AnvilFSR3* fsr3);
/// The luma planes motion is matched on — the last frame's, and the one before (nil before there's one): the game's
/// frames a pixel of the plane for every `scale` of theirs each way. Smooth Motion's check looks at them.
id<MTLTexture> AnvilFSR3Luma(const AnvilFSR3* fsr3);
id<MTLTexture> AnvilFSR3LumaBefore(const AnvilFSR3* fsr3);

void AnvilFSR3Free(AnvilFSR3* fsr3);

#ifdef __cplusplus
}
#endif

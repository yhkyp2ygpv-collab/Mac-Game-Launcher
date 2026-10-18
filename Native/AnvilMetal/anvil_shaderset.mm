// Anvil's compute shaders as one set — see anvil_shaderset.h. Manual retain/release.
#include "anvil_shaderset.h"
#include "anvil_pack.h"
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <stdlib.h>

static const char* const kKernelNames[kAnvilKernelCount] = {
    "anvil_rcas", "anvil_easu", "anvil_fsr_easu", "anvil_fsr_fused", "anvil_overlay", "anvil_finish",
    "anvil_counter", "anvil_flow_to_motion", "anvil_downsample", "anvil_upsample",
    "anvil_luma_pyramid", "anvil_optical_flow", "anvil_interpolate", "anvil_extrapolate",
    "anvil_fsr3_luma", "anvil_fsr3_motion", "anvil_fsr3_settle", "anvil_fsr3_resolve", "anvil_fsr3_wide",
    "anvil_midpoint", "anvil_midpoint_check", "anvil_midpoint_judge",
    "anvil_fsr3_pan_cost", "anvil_fsr3_pan_pick", "anvil_fsr3_pan_fine_cost", "anvil_fsr3_pan_fine_pick",
};

const char* AnvilKernelName(int kernel) {
    return kernel >= 0 && kernel < kAnvilKernelCount ? kKernelNames[kernel] : "";
}

id<MTLLibrary> AnvilShaderLibrary(id<MTLDevice> device, AnvilShaderNote note, double* compileMs) {
    if (compileMs) *compileMs = 0;
    if (!device) return nil;
    // The precompiled library first; the shader source as a fallback.
    //
    // Xcode 27 no longer ships the Metal toolchain — it is a separate download — so a
    // machine that updated Xcode can build Anvil but cannot precompile its shaders.
    // Metal can compile source at runtime without that toolchain, so when the
    // precompiled library is missing or unreadable Anvil compiles the source instead,
    // and the pipeline keeps working rather than silently turning itself off.
    NSError* error = nil;
    id<MTLLibrary> library = nil;
    if (const char* libPath = getenv("ANVIL_METALLIB")) {
        NSString* path = [NSString stringWithUTF8String:libPath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            library = [device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&error];
            if (library) note("[anvil] metallib loaded");
            else note("[anvil] metallib load failed: %s — trying source", error.localizedDescription.UTF8String);
            // A precompiled library without the newest kernel was built from older
            // source; the source shipped beside it is the one this library expects.
            if (library && getenv("ANVIL_METAL_SOURCE")) {
                id<MTLFunction> newest = [library newFunctionWithName:@"anvil_fsr3_pan_fine_pick"];
                if (!newest) {
                    note("[anvil] metallib predates this build's shaders — compiling the source instead");
                    [library release];
                    library = nil;
                }
                [newest release];
            }
        }
    }
    if (library) return library;

    NSString* source = nil;
    if (const char* srcPath = getenv("ANVIL_METAL_SOURCE")) {
        source = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:srcPath]
                                           encoding:NSUTF8StringEncoding error:&error];
    }
    // The public edition carries its shaders packed rather than as readable source.
    if (!source) {
        if (const char* packPath = getenv("ANVIL_METAL_PACK")) {
            NSData* pack = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:packPath]];
            size_t length = 0;
            char* text = pack ? anvil_unpack_source((const uint8_t*)pack.bytes, pack.length, &length) : NULL;
            if (text) {
                source = [[[NSString alloc] initWithBytesNoCopy:text length:length
                                                       encoding:NSUTF8StringEncoding freeWhenDone:YES] autorelease];
                if (!source) free(text);
            }
            if (!source) note("[anvil] the packed shaders couldn't be read");
        }
    }
    if (!source) {
        note("[anvil] no shader library (%s)", error ? error.localizedDescription.UTF8String : "no path given");
        return nil;
    }
    MTLCompileOptions* opts = [[MTLCompileOptions alloc] init];
    opts.mathMode = MTLMathModeFast;
    // The language version, named. Left to Metal it is the newest the *program* was built
    // for: Wine is built with the macOS 15.2 SDK and anvil-prep with 27.0, so the game compiled
    // these shaders as a different language version from Graphics Prep's, its archive held
    // pipelines for functions the game never had, and LEGO found 0 of 14 in it in every
    // session on 0.28 — where anvil-prep's own check, on its own SDK, found 14 of 14. 3.1 is
    // macOS 14's, the oldest Anvil runs on, and has everything these shaders use.
    opts.languageVersion = MTLLanguageVersion3_1;
    const CFTimeInterval t0 = CACurrentMediaTime();
    library = [device newLibraryWithSource:source options:opts error:&error];
    [opts release];
    const double ms = (CACurrentMediaTime() - t0) * 1000.0;
    if (compileMs) *compileMs = ms;
    if (library) note("[anvil] shaders compiled from source in %.0f ms", ms);
    else note("[anvil] no shader library (%s)", error ? error.localizedDescription.UTF8String : "the source didn't compile");
    return library;
}

MTLComputePipelineDescriptor* AnvilPipelineDescriptor(id<MTLLibrary> library, int kernel) {
    if (!library || kernel < 0 || kernel >= kAnvilKernelCount) return nil;
    id<MTLFunction> fn = [library newFunctionWithName:[NSString stringWithUTF8String:kKernelNames[kernel]]];
    if (!fn) return nil;
    MTLComputePipelineDescriptor* d = [[MTLComputePipelineDescriptor alloc] init];
    d.computeFunction = fn;
    [fn release];
    return d;
}

// Set by anvil_gpuwork.mm in libanvil: Anvil's own pipelines aren't counted among the game's
// shader compiles. Nothing in anvil-prep, which has no game.
extern "C" { void (*AnvilShaderSetOwnHook)(bool) = nullptr; }

id<MTLComputePipelineState> AnvilPipeline(id<MTLDevice> device, id<MTLLibrary> library, int kernel,
                                          id<MTLBinaryArchive> archive, bool* fromArchive) {
    if (fromArchive) *fromArchive = false;
    struct Own {
        Own() { if (AnvilShaderSetOwnHook) AnvilShaderSetOwnHook(true); }
        ~Own() { if (AnvilShaderSetOwnHook) AnvilShaderSetOwnHook(false); }
    } own;
    MTLComputePipelineDescriptor* d = AnvilPipelineDescriptor(library, kernel);
    if (!d || !device) { [d release]; return nil; }
    NSError* error = nil;
    id<MTLComputePipelineState> pso = nil;
    if (archive) {
        // Ready-made, or not at all: a miss returns at once rather than compiling, and the
        // pipeline is then compiled below exactly as it would be without an archive.
        d.binaryArchives = @[archive];
        pso = [device newComputePipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss
                                                 reflection:nil error:&error];
        if (pso && fromArchive) *fromArchive = true;
        d.binaryArchives = nil;
    }
    if (!pso) pso = [device newComputePipelineStateWithDescriptor:d options:MTLPipelineOptionNone
                                                        reflection:nil error:&error];
    [d release];
    return pso;
}

id<MTLBinaryArchive> AnvilOpenArchive(id<MTLDevice> device, const char* path, AnvilShaderNote note) {
    if (!device || !path || !path[0]) return nil;
    NSString* p = [NSString stringWithUTF8String:path];
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
        note("[anvil] shaders: Graphics Prep's archive isn't there any more — compiling as usual");
        return nil;
    }
    MTLBinaryArchiveDescriptor* d = [[MTLBinaryArchiveDescriptor alloc] init];
    d.url = [NSURL fileURLWithPath:p];
    NSError* error = nil;
    id<MTLBinaryArchive> archive = [device newBinaryArchiveWithDescriptor:d error:&error];
    [d release];
    if (!archive) note("[anvil] shaders: Graphics Prep's archive didn't open (%s) — compiling as usual",
                       error ? error.localizedDescription.UTF8String : "no reason given");
    return archive;
}

NSUInteger AnvilFusedMemory(MTLSize shape) {
    // (width + 2) x (height + 2) half4s, in the 16-byte steps Metal allots it in.
    const NSUInteger bytes = (shape.width + 2) * (shape.height + 2) * 8;
    return (bytes + 15) / 16 * 16;
}

MTLSize AnvilFusedShape(id<MTLComputePipelineState> fused, id<MTLDevice> device, MTLSize wanted) {
    if (!fused || !device) return MTLSizeMake(0, 0, 1);
    const MTLSize candidates[] = { wanted, MTLSizeMake(32, 32, 1), MTLSizeMake(32, 16, 1),
                                   MTLSizeMake(16, 16, 1), MTLSizeMake(16, 8, 1), MTLSizeMake(8, 8, 1) };
    for (const MTLSize& s : candidates) {
        if (s.width < 4 || s.height < 4) continue;
        if (s.width * s.height > fused.maxTotalThreadsPerThreadgroup) continue;
        if (AnvilFusedMemory(s) + fused.staticThreadgroupMemoryLength > device.maxThreadgroupMemoryLength) continue;
        return MTLSizeMake(s.width, s.height, 1);
    }
    return MTLSizeMake(0, 0, 1);
}

void AnvilDispatch2D(id<MTLComputeCommandEncoder> enc, id<MTLComputePipelineState> pso,
                     NSUInteger width, NSUInteger height) {
    const NSUInteger tw = pso.threadExecutionWidth;
    const NSUInteger th = MAX((NSUInteger)1, pso.maxTotalThreadsPerThreadgroup / tw);
    [enc dispatchThreads:MTLSizeMake(width, height, 1) threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
}

void AnvilEncodeFSR(id<MTLComputeCommandEncoder> enc, int pass, MTLSize fusedShape,
                    id<MTLComputePipelineState> easu, id<MTLComputePipelineState> finish,
                    id<MTLComputePipelineState> fused,
                    id<MTLTexture> input, id<MTLTexture> scratch, id<MTLTexture> target,
                    simd_float4 params) {
    if (pass == kAnvilFSRFused && fused && fusedShape.width > 0) {
        [enc setComputePipelineState:fused];
        [enc setTexture:input atIndex:0];
        [enc setTexture:target atIndex:1];
        [enc setBytes:&params length:sizeof(params) atIndex:0];
        [enc setThreadgroupMemoryLength:AnvilFusedMemory(fusedShape) atIndex:0];
        // Whole groups: the kernel works out each group's tile from the full shape.
        [enc dispatchThreadgroups:MTLSizeMake((target.width + fusedShape.width - 1) / fusedShape.width,
                                              (target.height + fusedShape.height - 1) / fusedShape.height, 1)
            threadsPerThreadgroup:fusedShape];
        return;
    }
    [enc setComputePipelineState:easu];
    [enc setTexture:input atIndex:0];
    [enc setTexture:scratch atIndex:1];
    AnvilDispatch2D(enc, easu, target.width, target.height);
    [enc setComputePipelineState:finish];
    [enc setTexture:scratch atIndex:0];
    [enc setTexture:target atIndex:1];
    [enc setBytes:&params length:sizeof(params) atIndex:0];
    AnvilDispatch2D(enc, finish, target.width, target.height);
}

// --- FSR 3 for every game -------------------------------------------------------------------

static id<MTLTexture> fsr3Texture(id<MTLDevice> device, MTLPixelFormat format, NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                  width:MAX(w, (NSUInteger)1)
                                                                                 height:MAX(h, (NSUInteger)1)
                                                                              mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    d.storageMode = MTLStorageModePrivate;
    return [device newTextureWithDescriptor:d];
}

static void fsr3Drop(AnvilFSR3* s) {
    for (int i = 0; i < 2; i++) {
        [s->plane[i] release];       s->plane[i] = nil;
        [s->coarsePlane[i] release]; s->coarsePlane[i] = nil;
        [s->widePlane[i] release];   s->widePlane[i] = nil;
        [s->fine[i] release];        s->fine[i] = nil;
        [s->history[i] release];     s->history[i] = nil;
    }
    [s->coarse release]; s->coarse = nil;
    [s->wide release]; s->wide = nil;
    [s->panCostTex release]; s->panCostTex = nil;
    [s->panCoarse release]; s->panCoarse = nil;
    [s->panFineTex release]; s->panFineTex = nil;
    [s->pan release]; s->pan = nil;
    [s->raw release]; s->raw = nil;
    s->width = s->height = s->outWidth = s->outHeight = 0;
    s->frames = 0;
}

bool AnvilFSR3Ensure(AnvilFSR3* s, id<MTLDevice> device, NSUInteger w, NSUInteger h, NSUInteger ow, NSUInteger oh) {
    if (!s || !device || w < 16 || h < 16 || ow < w || oh < h) return false;
    if (s->width == w && s->height == h && s->outWidth == ow && s->outHeight == oh && s->history[1]) return true;
    fsr3Drop(s);
    // Motion is matched on a plane about a thousand pixels wide whatever the game's size, so it
    // costs the same at 4K as at 1080p.
    int S = (w > 2048 || h > 1536) ? 4 : 2;
    if (s->askScale == 1 || s->askScale == 2 || s->askScale == 4) S = s->askScale;   // tests
    const NSUInteger pw = (w + S - 1) / S, ph = (h + S - 1) / S;
    const NSUInteger cw = (w + 2 * S - 1) / (2 * S), ch = (h + 2 * S - 1) / (2 * S);
    for (int i = 0; i < 2; i++) {
        s->plane[i] = fsr3Texture(device, MTLPixelFormatR16Float, pw, ph);
        s->coarsePlane[i] = fsr3Texture(device, MTLPixelFormatR16Float, cw, ch);
        s->fine[i] = fsr3Texture(device, MTLPixelFormatRGBA16Float, (pw + 7) / 8, (ph + 7) / 8);
        s->history[i] = fsr3Texture(device, MTLPixelFormatRGBA16Float, ow, oh);
    }
    s->coarse = fsr3Texture(device, MTLPixelFormatRGBA16Float, (cw + 7) / 8, (ch + 7) / 8);
    s->raw = fsr3Texture(device, MTLPixelFormatRGBA16Float, (pw + 7) / 8, (ph + 7) / 8);
    // The widest search's plane and field; without them motion is searched as before.
    const NSUInteger ww = (pw + 3) / 4, wh = (ph + 3) / 4;
    for (int i = 0; i < 2; i++) s->widePlane[i] = fsr3Texture(device, MTLPixelFormatR16Float, ww, wh);
    s->wide = fsr3Texture(device, MTLPixelFormatRGBA16Float, (ww + 7) / 8, (wh + 7) / 8);
    s->panCostTex = fsr3Texture(device, MTLPixelFormatR32Float, 17, 17);
    s->panCoarse = fsr3Texture(device, MTLPixelFormatRGBA32Float, 1, 1);
    s->panFineTex = fsr3Texture(device, MTLPixelFormatR32Float, 7, 7);
    s->pan = fsr3Texture(device, MTLPixelFormatRGBA32Float, 1, 1);
    for (int i = 0; i < 2; i++)
        if (!s->plane[i] || !s->coarsePlane[i] || !s->fine[i] || !s->history[i]) { fsr3Drop(s); return false; }
    if (!s->coarse || !s->raw) { fsr3Drop(s); return false; }
    s->width = w;
    s->height = h;
    s->outWidth = ow;
    s->outHeight = oh;
    s->scale = S;
    s->current = 0;
    s->frames = 0;
    return true;
}

void AnvilFSR3Reset(AnvilFSR3* s) { if (s) s->frames = 0; }

bool AnvilEncodeFSR3(AnvilFSR3* s, id<MTLComputeCommandEncoder> enc, id<MTLTexture> input,
                     id<MTLTexture> target, simd_float4 params) {
    if (!s || !enc || !input || !target || !s->luma || !s->flow || !s->motion || !s->settle || !s->resolve) return false;
    if (input.width != s->width || input.height != s->height || !s->history[1]) return false;
    if (target.width != s->outWidth || target.height != s->outHeight) return false;
    // 32x32 where the GPU allows it: less of each tile's border upscaled twice. 2.58 ms against
    // 2.89 at 16x16 on an M4 at LEGO's sizes (4 October); smaller where a GPU can't fit it.
    if (s->shape.width == 0) s->shape = AnvilFusedShape(s->resolve, s->resolve.device, MTLSizeMake(32, 32, 1));
    if (s->shape.width == 0) return false;
    const int cur = s->current, prev = 1 - cur;
    const bool blend = s->frames > 0;
    const int S = s->scale;
    const bool wide = s->widen && s->widePlane[0] && s->widePlane[1] && s->wide;
    const bool panOn = wide && s->panCost && s->panPick && s->panFineCost && s->panFinePick
                    && s->panCostTex && s->panCoarse && s->panFineTex && s->pan;

    if (s->only != 2) {
        [enc setComputePipelineState:s->luma];
        [enc setTexture:input atIndex:0];
        [enc setTexture:s->plane[cur] atIndex:1];
        [enc setTexture:s->coarsePlane[cur] atIndex:2];
        [enc setBytes:&S length:sizeof(S) atIndex:0];
        AnvilDispatch2D(enc, s->luma, s->coarsePlane[cur].width, s->coarsePlane[cur].height);
        if (wide) {
            [enc setComputePipelineState:s->widen];
            [enc setTexture:s->plane[cur] atIndex:0];
            [enc setTexture:s->widePlane[cur] atIndex:1];
            AnvilDispatch2D(enc, s->widen, s->widePlane[cur].width, s->widePlane[cur].height);
        }
    }
    if (blend && !s->given && s->only != 2) {
        // Coarse: 8x8 blocks of the coarse plane, tiled, searched ±8 of its pixels.
        const int stride = 8;
        [enc setComputePipelineState:s->flow];
        [enc setTexture:s->coarsePlane[prev] atIndex:0];
        [enc setTexture:s->coarsePlane[cur] atIndex:1];
        [enc setTexture:s->coarse atIndex:2];
        [enc setBytes:&stride length:sizeof(stride) atIndex:0];
        [enc dispatchThreadgroups:MTLSizeMake(s->coarse.width, s->coarse.height, 1)
            threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        // Widest: 8x8 blocks of the wide plane — 64 game pixels at the usual scale — searched
        // ±8 of its pixels, ±64 game pixels a frame. Graphics Prep's scene panned at 13 and 26
        // game pixels a frame (11 October) came out wrong at every block with only the coarse
        // search, its chequerboard matching a whole square off; blurred this far, it can't.
        if (wide) {
            [enc setTexture:s->widePlane[prev] atIndex:0];
            [enc setTexture:s->widePlane[cur] atIndex:1];
            [enc setTexture:s->wide atIndex:2];
            [enc setBytes:&stride length:sizeof(stride) atIndex:0];
            [enc dispatchThreadgroups:MTLSizeMake(s->wide.width, s->wide.height, 1)
                threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        }
        // The pan: every offset of the widest plane over all of it, then the one it fits best.
        if (panOn) {
            [enc setComputePipelineState:s->panCost];
            [enc setTexture:s->widePlane[prev] atIndex:0];
            [enc setTexture:s->widePlane[cur] atIndex:1];
            [enc setTexture:s->panCostTex atIndex:2];
            [enc dispatchThreadgroups:MTLSizeMake(17, 17, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            const simd_float4 info = {(float)S, s->frames > 1 ? 1.0f : 0.0f, 0, 0};
            [enc setComputePipelineState:s->panPick];
            [enc setTexture:s->panCostTex atIndex:0];
            [enc setTexture:s->panCoarse atIndex:1];
            [enc setTexture:s->fine[prev] atIndex:2];
            [enc setBytes:&info length:sizeof(info) atIndex:0];
            [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            // Made exact on the luma plane.
            [enc setComputePipelineState:s->panFineCost];
            [enc setTexture:s->plane[prev] atIndex:0];
            [enc setTexture:s->plane[cur] atIndex:1];
            [enc setTexture:s->panCoarse atIndex:2];
            [enc setTexture:s->panFineTex atIndex:3];
            [enc dispatchThreadgroups:MTLSizeMake(7, 7, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [enc setComputePipelineState:s->panFinePick];
            [enc setTexture:s->panFineTex atIndex:0];
            [enc setTexture:s->panCoarse atIndex:1];
            [enc setTexture:s->pan atIndex:2];
            [enc dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        }

        // Fine: per 8x8 block of the plane, from those and last frame's own; then each block
        // settled against its neighbours.
        const float prior = s->prior > 0 ? s->prior : kAnvilFSR3Prior;
        const simd_float4 mp = { s->frames > 1 ? 1.0f : 0.0f, prior, (float)S, panOn ? 2.0f : (wide ? 1.0f : 0.0f) };
        [enc setComputePipelineState:s->motion];
        [enc setTexture:s->plane[prev] atIndex:0];
        [enc setTexture:s->plane[cur] atIndex:1];
        [enc setTexture:s->coarse atIndex:2];
        [enc setTexture:s->fine[prev] atIndex:3];
        [enc setTexture:s->raw atIndex:4];
        [enc setTexture:wide ? s->wide : s->coarse atIndex:5];
        [enc setTexture:panOn ? s->pan : s->coarse atIndex:6];
        [enc setBytes:&mp length:sizeof(mp) atIndex:0];
        [enc dispatchThreadgroups:MTLSizeMake(s->raw.width, s->raw.height, 1)
            threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        const simd_float4 sp = { s->agree > 0 ? s->agree : kAnvilFSR3Agree, prior, (float)S, 0 };
        [enc setComputePipelineState:s->settle];
        [enc setTexture:s->plane[prev] atIndex:0];
        [enc setTexture:s->plane[cur] atIndex:1];
        [enc setTexture:s->raw atIndex:2];
        [enc setTexture:s->fine[cur] atIndex:3];
        [enc setBytes:&sp length:sizeof(sp) atIndex:0];
        [enc dispatchThreadgroups:MTLSizeMake(s->raw.width, s->raw.height, 1)
            threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    }
    if (s->only == 1) { s->frames++; s->current = prev; return true; }

    // EASU, RCAS, the blend and the counter, in one pass at the display's size.
    const bool native = s->outWidth == s->width && s->outHeight == s->height;
    const simd_float4 bp = { blend ? 1.0f : 0.0f,
                             s->maxFrames > 0 ? s->maxFrames : (native ? kAnvilFSR3FramesNative : kAnvilFSR3Frames),
                             s->clip > 0 ? s->clip : kAnvilFSR3Clip, s->bright > 0 ? s->bright : 0.0f };
    const simd_float4 gp = { (float)s->width, (float)s->height, (float)(8 * S), 0 };
    [enc setComputePipelineState:s->resolve];
    [enc setTexture:input atIndex:0];
    [enc setTexture:s->history[prev] atIndex:1];
    [enc setTexture:s->fine[cur] atIndex:2];
    [enc setTexture:target atIndex:3];
    [enc setTexture:s->history[cur] atIndex:4];
    [enc setBytes:&params length:sizeof(params) atIndex:0];
    [enc setBytes:&bp length:sizeof(bp) atIndex:1];
    [enc setBytes:&gp length:sizeof(gp) atIndex:2];
    [enc setThreadgroupMemoryLength:AnvilFusedMemory(s->shape) atIndex:0];
    [enc dispatchThreadgroups:MTLSizeMake((s->outWidth + s->shape.width - 1) / s->shape.width,
                                          (s->outHeight + s->shape.height - 1) / s->shape.height, 1)
        threadsPerThreadgroup:s->shape];

    s->frames++;
    s->current = prev;
    return true;
}

id<MTLTexture> AnvilFSR3Motion(const AnvilFSR3* s) {
    if (!s || s->frames < 2) return nil;
    return s->fine[1 - s->current];
}

id<MTLTexture> AnvilFSR3Picture(const AnvilFSR3* s) {
    if (!s || s->frames < 1) return nil;
    return s->history[1 - s->current];
}

id<MTLTexture> AnvilFSR3PictureBefore(const AnvilFSR3* s) {
    if (!s || s->frames < 2) return nil;
    return s->history[s->current];
}

id<MTLTexture> AnvilFSR3MotionBefore(const AnvilFSR3* s) {
    if (!s || s->frames < 3) return nil;
    return s->fine[s->current];
}

id<MTLTexture> AnvilFSR3Luma(const AnvilFSR3* s) {
    if (!s || s->frames < 1) return nil;
    return s->plane[1 - s->current];
}

id<MTLTexture> AnvilFSR3LumaBefore(const AnvilFSR3* s) {
    if (!s || s->frames < 2) return nil;
    return s->plane[s->current];
}

void AnvilFSR3Free(AnvilFSR3* s) { if (s) fsr3Drop(s); }

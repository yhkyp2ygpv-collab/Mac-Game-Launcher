// anvil_gpuwork.mm on this Mac's real GPU (needs a terminal of the Mac's own: no GPU in a sandbox).
//
//   1. Texture detail for FSR: a texture drawn at half its size picks mip level 1 (green here);
//      through a sampler from the watched device, with ANVIL_LOD_BIAS=-1, it picks level 0 (red).
//      A comparison sampler and one without mip levels are left alone.
//   2. A pipeline compiled through the device is counted as one of the game's compiles; one of
//      Anvil's own (AnvilOwnGpuWork) isn't.
//   3. A frame of passes like a game's — a 2048² shadow map, the scene at 1512x982 with depth,
//      a full-size effect, a half-size one, a compute pass, and one of Anvil's own — is timed on
//      the GPU and each lands in its kind.
//
//   clang++ -std=c++17 -ObjC++ -O1 -framework Foundation -framework Metal \
//     Native/Tools/tests/gpuwork_test.mm Native/AnvilMetal/anvil_gpuwork.mm -o /tmp/gpuwork_test && /tmp/gpuwork_test
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <objc/runtime.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>

extern "C" void AnvilWatchDevice(id<MTLDevice> device);
extern "C" void AnvilWatchCommandBuffers(Class cls);
extern "C" void AnvilOwnGpuWork(bool own);
extern "C" void AnvilGpuGameSize(double width, double height);
extern "C" void AnvilGpuFrameEnd();
extern "C" int AnvilGpuWorkWindow(char* out, size_t room);
extern "C" void AnvilTextureDetailReport(int* seen, int* sharpened, float* bias, int* anisotropy);
extern "C" { void (*AnvilShaderSetOwnHook)(bool) = nullptr; }
// libanvil's (anvil_inject.mm): whether a texture is a stand-in for the picture shown. None here.
extern "C" bool AnvilIsShownPicture(void*) { return false; }

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { ++failures; printf("FAIL: "); } else printf("ok: "); printf(__VA_ARGS__); printf("\n"); } while (0)

static NSString* const kSource = @R"(
#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; float2 uv; };
vertex V tri(uint i [[vertex_id]]) {
    float2 p = float2((i << 1) & 2, i & 2);
    V v; v.p = float4(p * 2.0 - 1.0, 0.5, 1.0); v.uv = float2(p.x, 1.0 - p.y); return v;
}
fragment float4 show(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    return t.sample(s, v.uv * 0.5 + 0.0);   // uv runs 0..2 across the triangle, 0..1 on screen
}
fragment float4 busy(V v [[stage_in]], constant uint& n [[buffer(0)]]) {
    float x = v.p.x * 0.001;
    for (uint i = 0; i < n; ++i) x = fract(sin(x * 12.9898 + float(i)) * 43758.5453);
    return float4(x, x * 0.5, 0.0, 1.0);
}
fragment void depthOnly(V v [[stage_in]]) {}
// An effect reads the pass before it, as a game's do: the GPU runs them one after the other.
fragment float4 after(V v [[stage_in]], texture2d<float> before [[texture(0)]], constant uint& n [[buffer(0)]]) {
    float x = before.read(uint2(v.p.xy) % uint2(before.get_width(), before.get_height())).r;
    for (uint i = 0; i < n; ++i) x = fract(sin(x * 12.9898 + float(i)) * 43758.5453);
    return float4(x, 0.0, 0.0, 1.0);
}
kernel void work(device float* out [[buffer(0)]], constant uint& n [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    float x = float(id);
    for (uint i = 0; i < n; ++i) x = fract(sin(x * 1.37 + float(i)) * 1000.0);
    out[id] = x;
}
)";

int main() {
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        setenv("ANVIL_LOD_BIAS", "-1", 1);
        setenv("ANVIL_ANISOTROPY", "8", 1);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { printf("gpu work: no GPU here (a sandbox?) — skipped\n"); return 2; }
        AnvilWatchDevice(device);
        NSError* error = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:kSource options:nil error:&error];
        if (!lib) { printf("FAIL: shaders: %s\n", error.localizedDescription.UTF8String); return 1; }
        id<MTLCommandQueue> queue = [device newCommandQueue];

        // 2 first: compiles, the game's and Anvil's.
        char line[1024] = "";
        AnvilGpuWorkWindow(line, sizeof line);                         // empty the window
        auto renderPipeline = [&](NSString* fragment, MTLPixelFormat colour, MTLPixelFormat depth) {
            MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = [lib newFunctionWithName:@"tri"];
            d.fragmentFunction = [lib newFunctionWithName:fragment];
            d.colorAttachments[0].pixelFormat = colour;
            d.depthAttachmentPixelFormat = depth;
            NSError* e = nil;
            id<MTLRenderPipelineState> p = [device newRenderPipelineStateWithDescriptor:d error:&e];
            if (!p) printf("pipeline %s: %s\n", fragment.UTF8String, e.localizedDescription.UTF8String);
            return p;
        };
        id<MTLRenderPipelineState> show = renderPipeline(@"show", MTLPixelFormatRGBA8Unorm, MTLPixelFormatInvalid);
        AnvilOwnGpuWork(true);
        id<MTLComputePipelineState> own = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"work"] error:&error];
        AnvilOwnGpuWork(false);
        line[0] = 0;
        AnvilGpuWorkWindow(line, sizeof line);
        CHECK(strstr(line, "shaders compiled 1 (") != nullptr, "a game pipeline compile counted, Anvil's own not:%s", line);

        // 1. Texture detail: mip 0 red, mip 1 green, mip 2 blue.
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:YES];
        id<MTLTexture> tex = [device newTextureWithDescriptor:td];
        const uint32_t colours[4] = {0xff0000ff, 0xff00ff00, 0xffff0000, 0xff808080};
        for (NSUInteger level = 0; level < tex.mipmapLevelCount; ++level) {
            const NSUInteger n = 64 >> level;
            std::string px(n * n * 4, '\0');
            for (NSUInteger i = 0; i < n * n; ++i) memcpy(&px[i * 4], &colours[std::min<NSUInteger>(level, 3)], 4);
            [tex replaceRegion:MTLRegionMake2D(0, 0, n, n) mipmapLevel:level withBytes:px.data() bytesPerRow:n * 4];
        }
        MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.mipFilter = MTLSamplerMipFilterNearest;
        id<MTLSamplerState> sharp = [device newSamplerStateWithDescriptor:sd];
        MTLSamplerDescriptor* cmp = [MTLSamplerDescriptor new];
        cmp.minFilter = MTLSamplerMinMagFilterLinear; cmp.mipFilter = MTLSamplerMipFilterLinear;
        cmp.compareFunction = MTLCompareFunctionLess;
        [device newSamplerStateWithDescriptor:cmp];
        MTLSamplerDescriptor* flat = [MTLSamplerDescriptor new];
        flat.minFilter = MTLSamplerMinMagFilterLinear;
        [device newSamplerStateWithDescriptor:flat];
        int seen = 0, sharpened = 0, aniso = 0; float bias = 0;
        AnvilTextureDetailReport(&seen, &sharpened, &bias, &aniso);
        CHECK(seen == 3 && sharpened == 1 && bias == -1.0f && aniso == 8,
              "samplers: 1 of 3 sharpened (the filtered, mipmapped one; not the comparison or the unmipmapped) — %d of %d", sharpened, seen);
        MTLTextureDescriptor* od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:32 height:32 mipmapped:NO];
        od.usage = MTLTextureUsageRenderTarget;
        od.storageMode = MTLStorageModeShared;
        id<MTLTexture> out = [device newTextureWithDescriptor:od];
        {
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = out;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:show];
            [e setFragmentTexture:tex atIndex:0];
            [e setFragmentSamplerState:sharp atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
        }
        uint32_t px = 0;
        [out getBytes:&px bytesPerRow:32 * 4 fromRegion:MTLRegionMake2D(16, 16, 1, 1) mipmapLevel:0];
        const int r = px & 0xff, g = (px >> 8) & 0xff;
        CHECK(r > 200 && g < 50, "a texture at half size samples mip 0 (red) with the FSR bias, not mip 1 (green): r %d g %d", r, g);

        // 3. A frame of passes, timed.
        id<MTLCommandBuffer> probe = [queue commandBuffer];
        AnvilWatchCommandBuffers(object_getClass(probe));
        AnvilGpuGameSize(1512, 982);
        id<MTLRenderPipelineState> busy = renderPipeline(@"busy", MTLPixelFormatRGBA8Unorm, MTLPixelFormatDepth32Float);
        id<MTLRenderPipelineState> busyColour = renderPipeline(@"after", MTLPixelFormatRGBA8Unorm, MTLPixelFormatInvalid);
        id<MTLRenderPipelineState> depthOnly = renderPipeline(@"depthOnly", MTLPixelFormatInvalid, MTLPixelFormatDepth32Float);
        id<MTLComputePipelineState> work = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"work"] error:&error];
        auto texture = [&](NSUInteger w, NSUInteger h, MTLPixelFormat f) {
            MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
            // As D3DMetal makes them: every target a 2D array of one slice.
            d.textureType = MTLTextureType2DArray;
            d.arrayLength = 1;
            d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            d.storageMode = MTLStorageModePrivate;
            return [device newTextureWithDescriptor:d];
        };
        id<MTLTexture> shadow = texture(2048, 2048, MTLPixelFormatDepth32Float);
        id<MTLTexture> scene = texture(1512, 982, MTLPixelFormatRGBA8Unorm), sceneDepth = texture(1512, 982, MTLPixelFormatDepth32Float);
        id<MTLTexture> effect = texture(1512, 982, MTLPixelFormatRGBA8Unorm), half = texture(756, 491, MTLPixelFormatRGBA8Unorm);
        id<MTLBuffer> scratch = [device newBufferWithLength:1 << 20 options:MTLResourceStorageModePrivate];
        auto pass = [&](id<MTLCommandBuffer> cb, id<MTLTexture> colour, id<MTLTexture> depth, id<MTLRenderPipelineState> p, uint32_t n,
                        id<MTLTexture> input = nil) {
            MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
            if (colour) { rp.colorAttachments[0].texture = colour; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore; }
            if (depth) { rp.depthAttachment.texture = depth; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionStore; }
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:p];
            [e setFragmentBytes:&n length:sizeof n atIndex:0];
            if (input) [e setFragmentTexture:input atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
        };
        auto compute = [&](id<MTLCommandBuffer> cb, uint32_t n) {
            id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:work];
            [e setBuffer:scratch offset:0 atIndex:0];
            [e setBytes:&n length:sizeof n atIndex:1];
            [e dispatchThreads:MTLSizeMake(1 << 18, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [e endEncoding];
        };
        auto frame = [&]() {
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            pass(cb, nil, shadow, depthOnly, 0);
            pass(cb, scene, sceneDepth, busy, 400);
            pass(cb, effect, nil, busyColour, 150, scene);
            pass(cb, half, nil, busyColour, 100, effect);
            compute(cb, 200);
            {   // An upload, as a game streams a texture in.
                id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
                [b fillBuffer:scratch range:NSMakeRange(0, scratch.length) value:7];
                [b endEncoding];
            }
            AnvilOwnGpuWork(true);
            compute(cb, 100);
            AnvilOwnGpuWork(false);
            [cb commit];
            [cb waitUntilCompleted];
        };
        line[0] = 0;
        AnvilGpuWorkWindow(line, sizeof line);
        AnvilGpuFrameEnd();                 // the next frame is timed
        frame();
        AnvilGpuFrameEnd();                 // …and ends
        frame();                            // an untimed one
        usleep(600 * 1000);
        AnvilGpuFrameEnd();                 // read back
        line[0] = 0;
        AnvilGpuWorkWindow(line, sizeof line);
        printf("   %s\n", line);
        auto has = [&](const char* kind) { std::string s = line; return s.find(std::string(" ") + kind + " ") != std::string::npos; };
        CHECK(strstr(line, "GPU work ") != nullptr, "a frame's GPU work timed");
        CHECK(has("shadows") && has("scene") && has("effects") && has("smaller effects") && has("compute") && has("Anvil"),
              "each pass in its kind: shadows, scene, effects, smaller effects, compute, Anvil");
        // "GPU work 16.7 ms a frame: scene 6.1, effects 2.0, …": each kind's share of the busy time.
        auto kindMs = [&](const char* kind) {
            const std::string s = line, key = std::string(kind) + " ";
            size_t at = s.find(": ");
            while (at != std::string::npos) {
                const size_t from = at + 2;
                if (s.compare(from, key.size(), key) == 0) return atof(s.c_str() + from + key.size());
                at = s.find(", ", from);
            }
            return 0.0;
        };
        const double frameMs = atof(strstr(line, "GPU work ") + 9);
        double sum = 0;
        for (const char* k : {"shadows", "depth", "scene", "effects", "smaller effects", "compute", "copies", "Anvil"}) sum += kindMs(k);
        CHECK(strstr(line, "copies ") != nullptr, "an upload timed as a copy");
        CHECK(fabs(sum - frameMs) < 0.15 * frameMs + 0.3, "the kinds add up to the frame's busy time (%.1f of %.1f ms)", sum, frameMs);
        CHECK(kindMs("scene") > kindMs("effects") && kindMs("scene") > kindMs("smaller effects"),
              "the busiest pass reads as the most (scene %.2f, effects %.2f, smaller effects %.2f ms)",
              kindMs("scene"), kindMs("effects"), kindMs("smaller effects"));
        // Untimed frames go through as they were: the window is empty now.
        frame();
        AnvilGpuFrameEnd();
        line[0] = 0;
        AnvilGpuWorkWindow(line, sizeof line);
        CHECK(strstr(line, "GPU work") == nullptr, "frames between timed ones aren't timed");
        (void)own;
    }
    if (failures) { printf("gpu work: %d failure(s)\n", failures); return 1; }
    printf("gpu work: all checks passed\n");
    return 0;
}

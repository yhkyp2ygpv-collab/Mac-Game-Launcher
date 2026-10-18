// A stand-in for a GPU-bound game as Anvil sees LEGO Star Wars in its heavy scenes: it draws at half
// the display's pixels (as LEGO's 1512x982 on a 3024x1964 panel, so FSR to the display takes the
// layer over), each frame's work is GPU time rather than CPU time, and it presents the way D3DMetal
// does — the frame's work committed first, then a drawable asked for, the frame copied into it and
// presented. A moving scene (a scrolling textured floor, stripes, a disc on its own path) gives FSR
// 3's motion and Smooth Motion's frames between something to follow.
//
//   clang++ -std=c++17 -ObjC++ -O2 -framework Cocoa -framework Metal -framework QuartzCore \
//     heavy_standin.mm -o heavy_standin
//   DYLD_INSERT_LIBRARIES=.../libanvil.dylib ANVIL_LOG=... ANVIL_OUTPUT=1 ANVIL_OUTPUT_ANY_CALLER=1 ANVIL_FSR3=1 ... \
//     ./heavy_standin <GPU ms a frame> <CPU ms a frame> <seconds> [heavy from s] [heavy to s] [light GPU ms]
//
// Between `heavy from` and `heavy to` seconds (default: all of it) a frame takes the first GPU time;
// outside, the light one — a game walking from a light scene into a heavy one and out again.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <thread>
#include <atomic>
#include <chrono>
#include <cmath>

static const char* kSource = R"(
#include <metal_stdlib>
using namespace metal;
struct P { float t; float loops; float2 size; };
static float hash2(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash2(i), hash2(i + float2(1, 0)), u.x), mix(hash2(i + float2(0, 1)), hash2(i + float2(1, 1)), u.x), u.y);
}
kernel void scene(texture2d<float, access::write> dst [[texture(0)]], constant P& p [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    const float2 q = float2(gid) + 0.5;
    // The camera pans; the floor and stripes go with it, the disc on a path of its own.
    const float2 cam = float2(160.0 * p.t, 40.0 * sin(p.t * 0.7));
    const float2 w = q + cam;
    float v = 0.0, a = 0.5, f = 1.0 / 48.0;
    for (int o = 0; o < 4; ++o) { v += a * noise(w * f); a *= 0.5; f *= 2.0; }
    float3 c = mix(float3(0.12, 0.13, 0.16), float3(0.82, 0.78, 0.66), v);
    if (fmod(w.x + 0.6 * w.y, 90.0) < 2.5) c = float3(0.2, 0.8, 0.4);
    if (q.y > p.size.y * 0.78 && fmod(w.x, 6.0) < 3.0) c *= 0.55;
    const float2 disc = float2(p.size.x * (0.5 + 0.3 * sin(p.t * 0.9)), p.size.y * (0.45 + 0.2 * cos(p.t * 1.3)));
    const float r = length(q - disc);
    if (r < 90.0) c = fmod(r, 14.0) < 7.0 ? float3(1.0, 0.85, 0.2) : float3(0.9, 0.3, 0.1);
    // The frame's GPU time: arithmetic that changes nothing on screen.
    float burn = c.x;
    for (int i = 0; i < int(p.loops); ++i) burn = fract(burn * 1.0001 + sin(burn + float(i)) * 1e-6);
    c += burn * 1e-6;
    dst.write(float4(c, 1.0), gid);
}
)";

struct P { float t; float loops; float w, h; };
static std::atomic<bool> g_stop{false};
static std::atomic<uint64_t> g_gpuUs{0}, g_gpuN{0};
// From a frame's start — where a game reads the controller — to its picture on the screen, as the drawable's
// presented handler says (with Smooth Motion, the stand-in's answer: when the first frame from it is shown).
static std::atomic<uint64_t> g_latUs{0}, g_latN{0};

int main(int argc, char** argv) {
    const double gpuMs = argc > 1 ? atof(argv[1]) : 30.0;
    const double cpuMs = argc > 2 ? atof(argv[2]) : 8.0;
    const double seconds = argc > 3 ? atof(argv[3]) : 40.0;
    const double heavyFrom = argc > 4 ? atof(argv[4]) : 0.0;
    const double heavyTo = argc > 5 ? atof(argv[5]) : 1e9;
    const double lightMs = argc > 6 ? atof(argv[6]) : gpuMs;
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSScreen* screen = [NSScreen mainScreen];
        NSRect frame = [screen frame];
        NSWindow* window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless
                                                         backing:NSBackingStoreBuffered defer:NO];
        // Above other apps' windows and on every desktop, so its frames are shown whichever app has the
        // focus and whichever desktop is up.
        [window setLevel:NSStatusWindowLevel];
        window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary
                                  | NSWindowCollectionBehaviorStationary;
        NSView* view = [[NSView alloc] initWithFrame:frame];
        view.wantsLayer = YES;
        CAMetalLayer* layer = [CAMetalLayer layer];
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.contentsScale = screen.backingScaleFactor;
        view.layer = layer;
        window.contentView = view;
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        // The game's size: the window's points, as LEGO's 1512x982 — half the display's pixels.
        const NSUInteger gw = (NSUInteger)frame.size.width, gh = (NSUInteger)frame.size.height;
        layer.drawableSize = CGSizeMake(gw, gh);

        NSError* err = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:@(kSource) options:nil error:&err];
        id<MTLComputePipelineState> pso = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"scene"] error:&err];
        if (!pso) { fprintf(stderr, "scene: %s\n", err.localizedDescription.UTF8String); return 1; }
        id<MTLCommandQueue> queue = [device newCommandQueue];
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:gw height:gh mipmapped:NO];
        td.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> back[2] = {[device newTextureWithDescriptor:td], [device newTextureWithDescriptor:td]};

        // At most two frames' work on the GPU at once, as a Windows game's swap chain allows: the
        // game waits here, outside Anvil's hooks, when the GPU is behind — the time is the game's.
        dispatch_semaphore_t inFlight = dispatch_semaphore_create(2);
        // HEAVY_PRESENT_LATENCY=N: also no more than N frames presented and not yet on screen — a swap
        // chain whose frame latency is counted to the screen, not to the GPU, as LEGO Star Wars' game ran
        // under D3DMetal on 13 October (held to exactly the rate its frames reached the screen).
        const int presentLatency = getenv("HEAVY_PRESENT_LATENCY") ? atoi(getenv("HEAVY_PRESENT_LATENCY")) : 0;
        dispatch_semaphore_t onScreen = presentLatency > 0 ? dispatch_semaphore_create(presentLatency) : nullptr;
        std::thread([=] {
            // Calibrate: loops for a millisecond of this GPU's time at this size.
            double loopsPerMs = 50.0;
            for (int i = 0; i < 3; ++i) {
                @autoreleasepool {
                    id<MTLCommandBuffer> cb = [queue commandBuffer];
                    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                    P p = {0, 400, (float)gw, (float)gh};
                    [e setComputePipelineState:pso];
                    [e setTexture:back[0] atIndex:0];
                    [e setBytes:&p length:sizeof p atIndex:0];
                    [e dispatchThreads:MTLSizeMake(gw, gh, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
                    [e endEncoding];
                    [cb commit];
                    [cb waitUntilCompleted];
                    const double ms = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
                    if (ms > 0.1) loopsPerMs = 400.0 / ms;
                }
            }
            // A fixed load, for runs to compare: HEAVY_LOOPS_PER_MS.
            if (const char* fixed = getenv("HEAVY_LOOPS_PER_MS")) loopsPerMs = atof(fixed);
            printf("calibrated: %.0f loops a millisecond of GPU\n", loopsPerMs);
            const auto start = std::chrono::steady_clock::now();
            uint64_t n = 0;
            // HEAVY_HITCH_EVERY=s: every s seconds one frame takes 40 ms more on the CPU — a shader compiled at a draw, as
            // LEGO Star Wars' are (0.57's held 80 after a late frame).
            const double hitchEvery = getenv("HEAVY_HITCH_EVERY") ? atof(getenv("HEAVY_HITCH_EVERY")) : 0.0;
            double nextHitch = hitchEvery > 0.0 ? hitchEvery : 1e18;
            while (!g_stop) {
                const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
                if (elapsed > seconds) break;
                @autoreleasepool {
                    const bool heavy = elapsed >= heavyFrom && elapsed < heavyTo;
                    const double ms = heavy ? gpuMs : lightMs;
                    // The game's frame: its CPU time, then its GPU work committed.
                    dispatch_semaphore_wait(inFlight, DISPATCH_TIME_FOREVER);
                    if (onScreen) dispatch_semaphore_wait(onScreen, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC));
                    const CFTimeInterval frameStart = CACurrentMediaTime();
                    double frameCpuMs = cpuMs;
                    if (elapsed >= nextHitch) { frameCpuMs += 40.0; nextHitch += hitchEvery; }
                    std::this_thread::sleep_for(std::chrono::microseconds((long)(frameCpuMs * 1000)));
                    id<MTLTexture> t = back[n & 1];
                    id<MTLCommandBuffer> work = [queue commandBuffer];
                    id<MTLComputeCommandEncoder> e = [work computeCommandEncoder];
                    P p = {(float)elapsed, (float)std::max(0.0, ms * loopsPerMs), (float)gw, (float)gh};
                    // In passes, as a game's frame is: its time split over forty dispatches of a
                    // fortieth each, the last drawing the picture.
                    [e setComputePipelineState:pso];
                    [e setTexture:t atIndex:0];
                    const int passes = 40;
                    P part = p;
                    part.loops = p.loops / passes;
                    for (int i = 0; i < passes; ++i) {
                        [e setBytes:&part length:sizeof part atIndex:0];
                        [e dispatchThreads:MTLSizeMake(gw, gh, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
                        if ((i % 8) == 7) { [e endEncoding]; e = [work computeCommandEncoder]; [e setComputePipelineState:pso]; [e setTexture:t atIndex:0]; }
                    }
                    [e endEncoding];
                    [work addCompletedHandler:^(id<MTLCommandBuffer> b) {
                        dispatch_semaphore_signal(inFlight);
                        if (b.GPUEndTime > b.GPUStartTime) {
                            g_gpuUs.fetch_add((uint64_t)((b.GPUEndTime - b.GPUStartTime) * 1e6));
                            g_gpuN.fetch_add(1);
                        }
                    }];
                    [work commit];
                    // Present, as D3DMetal: a drawable, the frame copied in, shown.
                    id<CAMetalDrawable> d = [layer nextDrawable];
                    if (!d) { if (onScreen) dispatch_semaphore_signal(onScreen); ++n; continue; }
                    if (onScreen) [d addPresentedHandler:^(id<MTLDrawable>) { dispatch_semaphore_signal(onScreen); }];
                    [d addPresentedHandler:^(id<MTLDrawable> shown) {
                        const CFTimeInterval at = shown.presentedTime > 0 ? shown.presentedTime : CACurrentMediaTime();
                        if (at > frameStart && at - frameStart < 2.0) { g_latUs.fetch_add((uint64_t)((at - frameStart) * 1e6)); g_latN.fetch_add(1); }
                    }];
                    id<MTLCommandBuffer> cb = [queue commandBuffer];
                    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
                    if (d.texture.width == t.width && d.texture.height == t.height) [blit copyFromTexture:t toTexture:d.texture];
                    [blit endEncoding];
                    [cb presentDrawable:d];
                    [cb commit];
                    ++n;
                }
            }
            printf("frames %llu in %.0f s (%.1f fps of its own), the frame's own GPU work %.1f ms, frame start to screen %.1f ms\n",
                   (unsigned long long)n, seconds, n / seconds, g_gpuN.load() ? g_gpuUs.load() / 1000.0 / g_gpuN.load() : 0.0,
                   g_latN.load() ? g_latUs.load() / 1000.0 / g_latN.load() : 0.0);
            g_stop = true;
            dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
        }).detach();
        [NSApp run];
    }
    return 0;
}

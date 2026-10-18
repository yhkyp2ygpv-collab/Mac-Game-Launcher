// A stand-in game for Anvil's display hook: a window, a CAMetalLayer, and a render loop
// that takes a set time per frame, so the hook's pacing and frame generation can be
// watched without Wine. Run with libanvil inserted and ANVIL_LOG set; read the log.
//
//   clang++ -std=c++17 -ObjC++ -framework Cocoa -framework Metal -framework QuartzCore \
//     pacing_test.mm -o pacing_test
//   DYLD_INSERT_LIBRARIES=.../libanvil.dylib ANVIL_LOG=/tmp/p.log ANVIL_HOOK_ENABLED=1 \
//     ANVIL_FRAME_GEN=1 ANVIL_PACING=1 ANVIL_ADAPTIVE=1 ANVIL_METALLIB=... \
//     ./pacing_test <ms per frame> <seconds>

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <thread>
#include <atomic>
#include <chrono>

static std::atomic<bool> g_stop{false};

int main(int argc, char** argv) {
    const double frameMs = argc > 1 ? atof(argv[1]) : 13.3;
    const double seconds = argc > 2 ? atof(argv[2]) : 60.0;
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSRect frame = [[NSScreen mainScreen] frame];
        NSWindow* window = [[NSWindow alloc] initWithContentRect:frame
                                                       styleMask:NSWindowStyleMaskBorderless
                                                         backing:NSBackingStoreBuffered defer:NO];
        [window setLevel:NSNormalWindowLevel];
        NSView* view = [[NSView alloc] initWithFrame:frame];
        view.wantsLayer = YES;
        CAMetalLayer* layer = [CAMetalLayer layer];
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize = CGSizeMake(frame.size.width, frame.size.height);
        view.layer = layer;
        window.contentView = view;
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        id<MTLCommandQueue> queue = [device newCommandQueue];
        std::thread([=] {
            const auto start = std::chrono::steady_clock::now();
            uint64_t n = 0;
            while (!g_stop) {
                const auto t0 = std::chrono::steady_clock::now();
                const double elapsed = std::chrono::duration<double>(t0 - start).count();
                if (elapsed > seconds) break;
                @autoreleasepool {
                    // "Game work": the frame's CPU time, before it asks for a drawable,
                    // the way D3DMetal renders offscreen and blits at present.
                    std::this_thread::sleep_for(std::chrono::microseconds((long)(frameMs * 1000)));
                    id<CAMetalDrawable> d = [layer nextDrawable];
                    if (!d) continue;
                    id<MTLCommandBuffer> cb = [queue commandBuffer];
                    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
                    rp.colorAttachments[0].texture = d.texture;
                    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                    // A moving vertical band so the flow estimate has motion to follow.
                    const double phase = fmod(elapsed * 0.25, 1.0);
                    rp.colorAttachments[0].clearColor = MTLClearColorMake(phase, 0.3, 1.0 - phase, 1);
                    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
                    [enc endEncoding];
                    [cb presentDrawable:d];
                    [cb commit];
                    ++n;
                }
            }
            g_stop = true;
            dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
        }).detach();
        [NSApp run];
    }
    return 0;
}

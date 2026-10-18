// anvil_screens.mm on a real GPU: a frame of each pixel format a game draws in is pictured at
// its time, at half its size each way, with its colours, and the last picture is kept fresh.
// Needs Metal, so it runs in a terminal of the Mac's own, not a sandbox.
//
//   clang++ -std=c++17 -ObjC++ -O2 -framework Foundation -framework Metal -framework CoreGraphics \
//     -framework ImageIO Native/Tools/tests/screens_test.mm Native/AnvilMetal/anvil_screens.mm -o screens_test
//   ./screens_test bgra8 <empty folder>      (also rgba16f, rgb10a2)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#include <cstdio>
#include <cstring>
#include <unistd.h>
#include <vector>

extern "C" void anvil_screens_offer(id<MTLCommandBuffer> cb, id<MTLTexture> frame);

static int failures = 0;
static void check(bool ok, const char* what) {
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) ++failures;
}

int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: screens_test bgra8|rgba16f|rgb10a2 <folder>\n"); return 2; }
        const char* kind = argv[1];
        setenv("ANVIL_SCREENS", argv[2], 1);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { printf("FAIL: no Metal device\n"); return 1; }
        id<MTLCommandQueue> queue = [device newCommandQueue];

        const NSUInteger w = 1512, h = 982;
        MTLPixelFormat format = MTLPixelFormatBGRA8Unorm;
        size_t bpp = 4;
        if (!strcmp(kind, "rgba16f")) { format = MTLPixelFormatRGBA16Float; bpp = 8; }
        else if (!strcmp(kind, "rgb10a2")) format = MTLPixelFormatRGB10A2Unorm;
        MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        d.storageMode = MTLStorageModeShared;
        id<MTLTexture> frame = [device newTextureWithDescriptor:d];

        // Left half red, right half blue.
        std::vector<uint8_t> pixels(w * h * bpp);
        for (NSUInteger y = 0; y < h; ++y) for (NSUInteger x = 0; x < w; ++x) {
            uint8_t* p = &pixels[(y * w + x) * bpp];
            const bool left = x < w / 2;
            if (format == MTLPixelFormatBGRA8Unorm) { p[0] = left ? 0 : 255; p[1] = 0; p[2] = left ? 255 : 0; p[3] = 255; }
            else if (format == MTLPixelFormatRGB10A2Unorm) {
                const uint32_t r = left ? 1023 : 0, b = left ? 0 : 1023, v = r | (0u << 10) | (b << 20) | (3u << 30);
                memcpy(p, &v, 4);
            } else {
                __fp16* hp = (__fp16*)p;
                hp[0] = left ? 1.0 : 0.0; hp[1] = 0.0; hp[2] = left ? 0.0 : 1.0; hp[3] = 1.0;
            }
        }
        [frame replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:pixels.data() bytesPerRow:w * bpp];

        // A buffer already sent: no picture, and no harm.
        id<MTLCommandBuffer> sent = [queue commandBuffer];
        [sent commit];
        anvil_screens_offer(sent, frame);

        // Frames for 11 seconds, as a game presents them.
        const CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        int frames = 0;
        while (CFAbsoluteTimeGetCurrent() - start < 11.0) {
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            anvil_screens_offer(cb, frame);
            [cb commit];
            [cb waitUntilCompleted];
            ++frames;
            usleep(8000);
        }
        sleep(1);   // the writer finishes behind the frames
        printf("   %d frames\n", frames);

        NSString* dir = [NSString stringWithUTF8String:argv[2]];
        NSArray* names = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]
                          sortedArrayUsingSelector:@selector(compare:)];
        printf("   %s\n", [[names componentsJoinedByString:@" "] UTF8String]);
        check([names containsObject:@"005s.jpg"] && [names containsObject:@"010s.jpg"], "a picture at 5 s and at 10 s");
        check(![names containsObject:@"015s.jpg"], "none before its time");
        check([names containsObject:@"last.jpg"], "the last picture is kept");
        bool partial = false;
        for (NSString* n in names) if ([n hasPrefix:@"."]) partial = true;
        check(!partial, "no half-written file left behind");

        NSURL* url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"005s.jpg"]];
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
        CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, nullptr) : nullptr;
        check(image && CGImageGetWidth(image) == w / 2 && CGImageGetHeight(image) == h / 2, "half the frame's size each way (756x491)");
        if (image) {
            const size_t iw = CGImageGetWidth(image), ih = CGImageGetHeight(image);
            std::vector<uint8_t> rgba(iw * ih * 4);
            CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef ctx = CGBitmapContextCreate(rgba.data(), iw, ih, 8, iw * 4, space, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
            CGContextDrawImage(ctx, CGRectMake(0, 0, iw, ih), image);
            const uint8_t* l = &rgba[(ih / 2 * iw + iw / 4) * 4];
            const uint8_t* r = &rgba[(ih / 2 * iw + iw * 3 / 4) * 4];
            printf("   left %d,%d,%d  right %d,%d,%d\n", l[0], l[1], l[2], r[0], r[1], r[2]);
            check(l[0] > 200 && l[1] < 60 && l[2] < 60, "the left half is red");
            check(r[2] > 200 && r[0] < 60 && r[1] < 60, "the right half is blue");
            CGContextRelease(ctx);
            CGColorSpaceRelease(space);
            CGImageRelease(image);
        }
        if (source) CFRelease(source);
        printf("screens (%s): %s\n", kind, failures ? "FAILED" : "all passed");
        return failures ? 1 : 0;
    }
}

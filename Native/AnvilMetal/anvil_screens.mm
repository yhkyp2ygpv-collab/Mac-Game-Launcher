// Small pictures of what the game shows, for Anvil to read after the session.
//
// A game that sits on one screen leaves nothing in any log to say which screen: on 1, 3, 5
// and 8 October LEGO Star Wars was closed on a screen it drew at full speed, with only frame
// rates and GPU load to go on. Now a quarter-size JPEG of the game's own frame is kept at set
// times in its first minutes (5 s … 5 min after its first frame), every 10 minutes after that —
// a long session's picture over time: on 11 October a LEGO session's problems came 15 to 28
// minutes in, with no picture of them past the fifth minute — and `last.jpg` is the
// newest picture, replaced at least every 5 seconds for the whole session — what was on screen
// when it was closed. Anvil reads the text in them after the session (Vision, on this Mac) and says what
// the game was showing; see ScreenReader.swift.
//
// Only with ANVIL_SCREENS set (the folder for this session). The copy is one blit of the
// frame Anvil already has at present, into a shared buffer, a few times a minute; scaling and
// the JPEG happen on a background queue after the GPU is done with it. Nothing leaves the Mac.
// Manual retain/release, as the rest of libanvil.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <sys/stat.h>
#include <vector>

namespace {

/// Seconds after the first frame with a picture of their own. Loading screens, sign-in and
/// title screens all fall in the first minutes.
const int kShots[] = {5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 300};
const int kShotCount = sizeof(kShots) / sizeof(kShots[0]);
const double kLastEvery = 5.0;
/// And after those, one every this many seconds, for as long as the session lasts.
const int kLongEvery = 600;

std::atomic<bool> g_busy{false};     // one copy in flight at a time
double g_firstAt = 0.0;
int g_nextShot = 0;
int g_nextLong = kLongEvery;         // seconds after the first frame of the next long-session picture
double g_lastAt = 0.0;

const char* folder() {
    static const char* dir = [] () -> const char* {
        const char* d = getenv("ANVIL_SCREENS");
        if (!d || !*d) return nullptr;
        mkdir(d, 0700);
        return strdup(d);
    }();
    return dir;
}

void note(const char* text) {
    const char* path = getenv("ANVIL_LOG");
    if (!path) return;
    if (FILE* f = fopen(path, "a")) { fprintf(f, "[anvil] %s\n", text); fclose(f); }
}

enum class Kind { bgra8, rgba8, rgb10a2, bgr10a2, rgba16f, other };

Kind kindOf(MTLPixelFormat format) {
    switch (format) {
        case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB: return Kind::bgra8;
        case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: return Kind::rgba8;
        case MTLPixelFormatRGB10A2Unorm: return Kind::rgb10a2;
        case MTLPixelFormatBGR10A2Unorm: return Kind::bgr10a2;
        case MTLPixelFormatRGBA16Float: return Kind::rgba16f;
        default: return Kind::other;
    }
}

size_t bytesPerPixel(Kind kind) { return kind == Kind::rgba16f ? 8 : 4; }

/// One source pixel as 8-bit R, G, B (display-encoded).
inline void readPixel(const uint8_t* p, Kind kind, float rgb[3]) {
    switch (kind) {
        case Kind::bgra8: rgb[0] = p[2]; rgb[1] = p[1]; rgb[2] = p[0]; break;
        case Kind::rgba8: rgb[0] = p[0]; rgb[1] = p[1]; rgb[2] = p[2]; break;
        case Kind::rgb10a2: case Kind::bgr10a2: {
            uint32_t v; memcpy(&v, p, 4);
            const float a = (float)(v & 0x3ff) * 255.0f / 1023.0f;
            const float b = (float)((v >> 10) & 0x3ff) * 255.0f / 1023.0f;
            const float c = (float)((v >> 20) & 0x3ff) * 255.0f / 1023.0f;
            if (kind == Kind::rgb10a2) { rgb[0] = a; rgb[1] = b; rgb[2] = c; }
            else { rgb[0] = c; rgb[1] = b; rgb[2] = a; }
            break;
        }
        case Kind::rgba16f: {
            const __fp16* h = (const __fp16*)p;
            for (int i = 0; i < 3; ++i) {
                // Linear light: to sRGB for the picture.
                float x = std::fmin(std::fmax((float)h[i], 0.0f), 1.0f);
                x = x <= 0.0031308f ? x * 12.92f : 1.055f * std::pow(x, 1.0f / 2.4f) - 0.055f;
                rgb[i] = x * 255.0f;
            }
            break;
        }
        case Kind::other: rgb[0] = rgb[1] = rgb[2] = 0; break;
    }
}

/// The frame at a quarter of its pixels (half each way, 2x2 averaged), written as a JPEG —
/// through a temporary name, so Anvil never reads half a file.
void writeJPEG(id<MTLBuffer> buffer, size_t width, size_t height, size_t rowBytes, Kind kind, std::string name) {
    const size_t w = std::max<size_t>(1, width / 2), h = std::max<size_t>(1, height / 2);
    const size_t bpp = bytesPerPixel(kind);
    const uint8_t* src = (const uint8_t*)buffer.contents;
    std::vector<uint8_t> out(w * h * 4);
    for (size_t y = 0; y < h; ++y) {
        for (size_t x = 0; x < w; ++x) {
            float sum[3] = {0, 0, 0};
            for (int dy = 0; dy < 2; ++dy) for (int dx = 0; dx < 2; ++dx) {
                const size_t sx = std::min(width - 1, x * 2 + dx), sy = std::min(height - 1, y * 2 + dy);
                float rgb[3];
                readPixel(src + sy * rowBytes + sx * bpp, kind, rgb);
                sum[0] += rgb[0]; sum[1] += rgb[1]; sum[2] += rgb[2];
            }
            uint8_t* d = &out[(y * w + x) * 4];
            d[0] = (uint8_t)std::lround(sum[0] / 4); d[1] = (uint8_t)std::lround(sum[1] / 4);
            d[2] = (uint8_t)std::lround(sum[2] / 4); d[3] = 255;
        }
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(out.data(), w, h, 8, w * 4, space,
                                             kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) return;
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!image) return;
    NSMutableData* jpeg = [NSMutableData data];
    bool encoded = false;
    if (CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, nullptr)) {
        NSDictionary* options = @{ (__bridge NSString*)kCGImageDestinationLossyCompressionQuality: @0.7 };
        CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)options);
        encoded = CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }
    CGImageRelease(image);
    if (!encoded) return;
    // Under its own name, and as last.jpg: the newest picture is always there by that name.
    const std::string dir = folder();
    for (const std::string& as : name == "last.jpg" ? std::vector<std::string>{name} : std::vector<std::string>{name, "last.jpg"}) {
        const std::string final = dir + "/" + as, temp = dir + "/." + as + ".part";
        if ([jpeg writeToFile:[NSString stringWithUTF8String:temp.c_str()] atomically:NO]) rename(temp.c_str(), final.c_str());
        else remove(temp.c_str());
    }
}

dispatch_queue_t writer() {
    static dispatch_queue_t queue = dispatch_queue_create("anvil.screens", dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    return queue;
}

} // namespace

/// At present, with the game's frame and its still-open command buffer: a copy of the frame
/// when one is due. Anything that doesn't fit — a frame that can't be read, a buffer already
/// sent — is simply no picture this time.
extern "C" void anvil_screens_offer(id<MTLCommandBuffer> cb, id<MTLTexture> frame) {
    if (!folder() || !cb || !frame) return;
    const double now = CFAbsoluteTimeGetCurrent();
    if (g_firstAt <= 0.0) {
        g_firstAt = now;
        note("screens: a small picture of what the game shows is kept now and then this session, for Anvil to "
             "read what's on screen (on this Mac only)");
    }
    const double since = now - g_firstAt;
    std::string name;
    bool isLong = false;
    if (g_nextShot < kShotCount && since >= kShots[g_nextShot]) {
        // Shots a long hitch skipped over are not made up; the next one due is taken.
        while (g_nextShot + 1 < kShotCount && since >= kShots[g_nextShot + 1]) ++g_nextShot;
        char buf[32];
        snprintf(buf, sizeof buf, "%03ds.jpg", kShots[g_nextShot]);
        name = buf;
    } else if (g_nextShot >= kShotCount && since >= g_nextLong) {
        // The same for the long-session pictures: a game left behind another app for an hour
        // gets the one now, not six at once.
        while (since >= g_nextLong + kLongEvery) g_nextLong += kLongEvery;
        char buf[32];
        snprintf(buf, sizeof buf, "%03ds.jpg", g_nextLong);
        name = buf;
        isLong = true;
    } else if (since >= kShots[0] && now - g_lastAt >= kLastEvery) {
        name = "last.jpg";
    } else {
        return;
    }
    const Kind kind = kindOf(frame.pixelFormat);
    if (kind == Kind::other || frame.framebufferOnly || frame.textureType != MTLTextureType2D
        || cb.status != MTLCommandBufferStatusNotEnqueued) return;
    if (g_busy.exchange(true)) return;

    const size_t width = frame.width, height = frame.height;
    const size_t rowBytes = ((width * bytesPerPixel(kind)) + 255) & ~(size_t)255;
    // Owned here until the handlers below have it: blocks retain what they capture when copied.
    id<MTLBuffer> buffer = [cb.device newBufferWithLength:rowBytes * height options:MTLResourceStorageModeShared];
    if (!buffer) { g_busy = false; return; }
    @try {
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        if (!blit) { [buffer release]; g_busy = false; return; }
        [blit copyFromTexture:frame sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(width, height, 1) toBuffer:buffer destinationOffset:0
          destinationBytesPerRow:rowBytes destinationBytesPerImage:rowBytes * height];
        [blit endEncoding];
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            if (done.status != MTLCommandBufferStatusCompleted) { g_busy = false; return; }
            dispatch_async(writer(), ^{
                @autoreleasepool { writeJPEG(buffer, width, height, rowBytes, kind, name); }
                g_busy = false;
            });
        }];
    } @catch (NSException*) {
        [buffer release];
        g_busy = false;
        return;
    }
    [buffer release];
    if (name == "last.jpg") g_lastAt = now;
    else if (isLong) { g_nextLong += kLongEvery; g_lastAt = now; }
    else { ++g_nextShot; g_lastAt = now; }
}

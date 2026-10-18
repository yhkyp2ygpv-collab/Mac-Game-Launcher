// FSR to the display and frame generation, on the Mac's own GPU. Needs a GPU, so it runs
// outside Claude's sandbox: in a terminal, with nothing on screen.
//
//   clang -fobjc-arc -framework Metal -framework QuartzCore -framework Foundation \
//     Native/Tools/tests/fsr_bench.m -o $TMPDIR/fsr_bench
//
//   fsr_bench shaders <AnvilShaders.metal>
//     AMD's EASU against a bilinear stretch: no value outside its neighbours (no halos), no
//     NaN, flat areas unchanged, edges at least as sharp; and how long EASU and RCAS take at
//     1512x982 → 3024x1964.
//
//   DYLD_INSERT_LIBRARIES=libanvil.dylib ANVIL_OUTPUT=1 ANVIL_OUTPUT_ANY_CALLER=1 … \
//     fsr_bench pipeline <seconds> <fps>
//     Does what D3DMetal does — sets the layer's size, takes a drawable, copies its frame in,
//     presents — with Anvil's library in the process. Checks the game gets a drawable of its
//     own size, that what reaches the real drawable is the upscaled frame, and that nothing
//     stops: a watchdog fails the run if a frame takes more than 2 s. BENCH_NATIVE=1 has the
//     game draw at the display's own 3024x1964 (FSR 3 runs there; FSR 1 doesn't); with
//     ANVIL_FSR3=1 every frame must have gone through FSR 3.
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <simd/simd.h>
#include <dlfcn.h>
#include <math.h>
#include <signal.h>
#include <unistd.h>

static int failures = 0;
static void check(BOOL ok, NSString* what) {
    if (!ok) failures++;
    printf("%s: %s\n", ok ? "ok" : "FAIL", what.UTF8String);
}

static id<MTLTexture> makeTexture(id<MTLDevice> dev, NSUInteger w, NSUInteger h, MTLTextureUsage usage) {
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:w height:h mipmapped:NO];
    d.usage = usage;
    d.storageMode = MTLStorageModeShared;
    return [dev newTextureWithDescriptor:d];
}

/// A test card: flat areas, a hard diagonal edge, thin lines, a gradient. `shift` moves it.
static void fillCard(id<MTLTexture> t, int shift) {
    const NSUInteger w = t.width, h = t.height;
    NSMutableData* data = [NSMutableData dataWithLength:w * h * 4];
    uint8_t* p = data.mutableBytes;
    for (NSUInteger y = 0; y < h; ++y) for (NSUInteger x = 0; x < w; ++x) {
        uint8_t* px = p + (y * w + x) * 4;      // BGRA
        int X = (int)x + shift;
        uint8_t r, g, b;
        if (x < w / 4) { r = 200; g = 60; b = 40; }                          // flat
        else if (x < w / 2) { bool hi = (X + (int)y) % 97 < 48; r = g = b = hi ? 230 : 25; }   // hard diagonal edges
        else if (x < 3 * w / 4) { bool line = (X % 9) == 0 || (y % 13) == 0; r = g = b = line ? 255 : 70; }   // thin lines
        else { r = (uint8_t)(255 * (x - 3 * w / 4) / (w / 4)); g = (uint8_t)(255 * y / h); b = 128; }       // gradient
        px[0] = b; px[1] = g; px[2] = r; px[3] = 255;
    }
    [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:p bytesPerRow:w * 4];
}

static NSData* readBack(id<MTLTexture> t) {
    NSMutableData* data = [NSMutableData dataWithLength:t.width * t.height * 4];
    [t getBytes:data.mutableBytes bytesPerRow:t.width * 4 fromRegion:MTLRegionMake2D(0, 0, t.width, t.height) mipmapLevel:0];
    return data;
}

/// The layer format a run asks for: BENCH_FORMAT=bgra8 (default), srgb, rgba-srgb, rgb10a2,
/// bgr10a2, rgba16f, or rgba16f-hdr (16-bit float with extended range, which FSR leaves alone).
static MTLPixelFormat benchFormat(BOOL* hdr) {
    const char* f = getenv("BENCH_FORMAT");
    *hdr = NO;
    if (!f) return MTLPixelFormatBGRA8Unorm;
    if (!strcmp(f, "srgb")) return MTLPixelFormatBGRA8Unorm_sRGB;
    if (!strcmp(f, "rgba-srgb")) return MTLPixelFormatRGBA8Unorm_sRGB;
    if (!strcmp(f, "rgb10a2")) return MTLPixelFormatRGB10A2Unorm;
    if (!strcmp(f, "bgr10a2")) return MTLPixelFormatBGR10A2Unorm;
    if (!strcmp(f, "rgba16f")) return MTLPixelFormatRGBA16Float;
    if (!strcmp(f, "rgba16f-hdr")) { *hdr = YES; return MTLPixelFormatRGBA16Float; }
    return MTLPixelFormatBGRA8Unorm;
}

static MTLPixelFormat plainOf(MTLPixelFormat f) {
    if (f == MTLPixelFormatBGRA8Unorm_sRGB) return MTLPixelFormatBGRA8Unorm;
    if (f == MTLPixelFormatRGBA8Unorm_sRGB) return MTLPixelFormatRGBA8Unorm;
    return f;
}

/// Colour copied texel for texel between any two formats of one size, as encoded: an sRGB
/// texture through a plain view of it, so its bytes are what the game drew.
static void copyColour(id<MTLCommandQueue> q, id<MTLTexture> src, id<MTLTexture> dst) {
    static id<MTLComputePipelineState> pso;
    if (!pso) {
        NSString* code = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void copyc(texture2d<float, access::read> s [[texture(0)]], texture2d<float, access::write> d [[texture(1)]],"
            " uint2 g [[thread_position_in_grid]]) { if (g.x < d.get_width() && g.y < d.get_height()) d.write(s.read(g), g); }";
        NSError* err = nil;
        id<MTLLibrary> lib = [q.device newLibraryWithSource:code options:nil error:&err];
        pso = [q.device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"copyc"] error:&err];
    }
    id<MTLTexture> s = plainOf(src.pixelFormat) != src.pixelFormat ? [src newTextureViewWithPixelFormat:plainOf(src.pixelFormat)] : src;
    id<MTLTexture> d = plainOf(dst.pixelFormat) != dst.pixelFormat ? [dst newTextureViewWithPixelFormat:plainOf(dst.pixelFormat)] : dst;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:pso];
    [enc setTexture:s atIndex:0];
    [enc setTexture:d atIndex:1];
    [enc dispatchThreads:MTLSizeMake(d.width, d.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
}

static double run(id<MTLCommandQueue> q, id<MTLComputePipelineState> pso, id<MTLTexture> src, id<MTLTexture> dst, simd_float4* params) {
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:pso];
    [enc setTexture:src atIndex:0];
    [enc setTexture:dst atIndex:1];
    if (params) [enc setBytes:params length:sizeof(*params) atIndex:0];
    NSUInteger tw = pso.threadExecutionWidth, th = MAX(1u, pso.maxTotalThreadsPerThreadgroup / tw);
    [enc dispatchThreads:MTLSizeMake(dst.width, dst.height, 1) threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
}

/// The 10–90% width of the brightness step across one row's first hard edge, in output pixels.
static double edgeWidth(const uint8_t* p, NSUInteger w, NSUInteger y, NSUInteger x0, NSUInteger x1) {
    for (NSUInteger x = x0; x + 1 < x1; ++x) {
        int a = p[(y * w + x) * 4 + 1], b = p[(y * w + x + 1) * 4 + 1];
        if (a < 60 && b > 60) {
            // walk from low to high
            NSUInteger lo = x, hi = x + 1;
            while (lo > x0 && p[(y * w + lo) * 4 + 1] > 25 + 20) lo--;
            while (hi < x1 - 1 && p[(y * w + hi) * 4 + 1] < 230 - 20) hi++;
            return (double)(hi - lo);
        }
    }
    return -1;
}

static int shaders(NSString* sourcePath) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { printf("FAIL: no GPU\n"); return 1; }
    NSError* err = nil;
    NSString* src = [NSString stringWithContentsOfFile:sourcePath encoding:NSUTF8StringEncoding error:&err];
    MTLCompileOptions* opts = [MTLCompileOptions new];
    opts.mathMode = MTLMathModeFast;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:opts error:&err];
    check(lib != nil, [NSString stringWithFormat:@"Anvil's shaders compile on %@%@", dev.name, lib ? @"" : [@": " stringByAppendingString:err.localizedDescription]]);
    if (!lib) return 1;
    id<MTLComputePipelineState> easu = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"anvil_fsr_easu"] error:&err];
    id<MTLComputePipelineState> easu32 = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"anvil_fsr_easu_f32"] error:&err];
    id<MTLComputePipelineState> finish = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"anvil_finish"] error:&err];
    id<MTLComputePipelineState> up = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"anvil_upsample"] error:&err];
    check(easu && finish && up, @"EASU, RCAS (finish) and a bilinear stretch are there");
    if (!easu || !finish || !up) return 1;
    id<MTLCommandQueue> q = [dev newCommandQueue];

    const NSUInteger iw = 1512, ih = 982, ow = 3024, oh = 1964;
    id<MTLTexture> card = makeTexture(dev, iw, ih, MTLTextureUsageShaderRead);
    fillCard(card, 0);
    id<MTLTexture> outE = makeTexture(dev, ow, oh, MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead);
    id<MTLTexture> outB = makeTexture(dev, ow, oh, MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead);
    id<MTLTexture> outR = makeTexture(dev, ow, oh, MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead);
    run(q, easu, card, outE, NULL);
    run(q, up, card, outB, NULL);
    NSData* e = readBack(outE), *b = readBack(outB), *i = readBack(card);
    const uint8_t* E = e.bytes; const uint8_t* B = b.bytes; const uint8_t* Src = i.bytes;

    // Flat area: exactly its colour.
    BOOL flat = YES;
    for (NSUInteger y = 100; y < 1800 && flat; y += 37) for (NSUInteger x = 40; x < ow / 4 - 40; x += 41) {
        const uint8_t* px = E + (y * ow + x) * 4;
        if (abs(px[2] - 200) > 1 || abs(px[1] - 60) > 1 || abs(px[0] - 40) > 1) { flat = NO; break; }
    }
    check(flat, @"a flat area comes out its own colour");
    // No halos: every output pixel within the range of the 4x4 input around it.
    NSUInteger outside = 0, checked = 0;
    for (NSUInteger y = 4; y < oh - 4; y += 3) for (NSUInteger x = 4; x < ow - 4; x += 3) {
        const double sx = (x + 0.5) * iw / ow - 0.5, sy = (y + 0.5) * ih / oh - 0.5;
        const long fx = (long)floor(sx), fy = (long)floor(sy);
        for (int c = 0; c < 3; ++c) {
            int lo = 255, hi = 0;
            for (long yy = fy - 1; yy <= fy + 2; ++yy) for (long xx = fx - 1; xx <= fx + 2; ++xx) {
                long cx = MAX(0, MIN((long)iw - 1, xx)), cy = MAX(0, MIN((long)ih - 1, yy));
                int v = Src[(cy * iw + cx) * 4 + c];
                lo = MIN(lo, v); hi = MAX(hi, v);
            }
            int v = E[(y * ow + x) * 4 + c];
            if (v < lo - 1 || v > hi + 1) outside++;
        }
        checked++;
    }
    check(outside == 0, [NSString stringWithFormat:@"no halos: every pixel within its neighbours' range (%lu of %lu samples outside)", (unsigned long)outside, (unsigned long)checked * 3]);
    // Edge sharpness against the bilinear stretch, across the diagonal band.
    double we = 0, wb = 0; int n = 0;
    for (NSUInteger y = 200; y < 1800; y += 50) {
        double a = edgeWidth(E, ow, y, ow / 4 + 8, ow / 2 - 8), c = edgeWidth(B, ow, y, ow / 4 + 8, ow / 2 - 8);
        if (a > 0 && c > 0) { we += a; wb += c; n++; }
    }
    if (n > 0) { we /= n; wb /= n; }
    check(n > 0 && we <= wb, [NSString stringWithFormat:@"edges at least as sharp as the bilinear stretch (%.2f px against %.2f, %d edges)", we, wb, n]);

    // The 16-bit EASU against the 32-bit one: the same picture.
    if (easu32) {
        id<MTLTexture> out32 = makeTexture(dev, ow, oh, MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead);
        run(q, easu32, card, out32, NULL);
        NSData* f = readBack(out32); const uint8_t* F = f.bytes;
        int worst = 0; double sum = 0;
        for (NSUInteger k = 0; k < ow * oh * 4; k += 4) for (int c = 0; c < 3; ++c) {
            int dlt = abs((int)E[k + c] - (int)F[k + c]); worst = MAX(worst, dlt); sum += dlt;
        }
        check(worst <= 3, [NSString stringWithFormat:@"16-bit EASU matches 32-bit (worst %d of 255, mean %.3f)", worst, sum / (ow * oh * 3)]);
        double t32 = 0;
        for (int k = 0; k < 40; ++k) t32 += run(q, easu32, card, out32, NULL);
        printf("info: 32-bit EASU %.2f ms\n", t32 / 40);
    }
    // Time, averaged.
    double tE = 0, tR = 0;
    simd_float4 params = { 0.9f, 0, 3, -1 };
    for (int k = 0; k < 40; ++k) { tE += run(q, easu, card, outE, NULL); tR += run(q, finish, outE, outR, &params); }
    tE /= 40; tR /= 40;
    printf("info: at 1512x982 → 3024x1964 on %s: EASU %.2f ms, RCAS %.2f ms, %.2f ms a frame\n", dev.name.UTF8String, tE, tR, tE + tR);
    check(tE + tR < 2.5, @"FSR costs under 2.5 ms a frame at this size");
    // RCAS output never NaN / never outside 0–255 (bytes can't be), and differs from its input (it sharpened).
    NSData* r = readBack(outR); const uint8_t* R = r.bytes;
    NSUInteger changed = 0;
    for (NSUInteger k = 0; k < ow * oh * 4; k += 97) if (R[k] != E[k]) changed++;
    check(changed > 0, @"RCAS sharpens the upscaled frame");
    return failures ? 1 : 0;
}

static volatile sig_atomic_t g_lastFrameAt = 0;
static void watchdog(int sig) { (void)sig; printf("FAIL: a frame took more than 2 s — Anvil stopped the game\n"); _exit(3); }

static int pipeline(double seconds, double fps) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { printf("FAIL: no GPU\n"); return 1; }
    id<MTLCommandQueue> q = [dev newCommandQueue];
    CAMetalLayer* layer = [CAMetalLayer layer];
    layer.device = dev;
    BOOL hdr = NO;
    const MTLPixelFormat format = benchFormat(&hdr);
    const BOOL expectProxy = !(getenv("BENCH_EXPECT_PROXY") && getenv("BENCH_EXPECT_PROXY")[0] == '0');
    const BOOL resize = getenv("BENCH_RESIZE") && getenv("BENCH_RESIZE")[0] == '1';
    layer.pixelFormat = format;
    if (hdr) layer.wantsExtendedDynamicRangeContent = YES;
    printf("info: layer pixel format %lu%s\n", (unsigned long)format, hdr ? ", extended range" : "");
    const BOOL native = getenv("BENCH_NATIVE") && getenv("BENCH_NATIVE")[0] == '1';
    NSUInteger gameW = native ? 3024 : 1512, gameH = native ? 1964 : 982;
    layer.bounds = CGRectMake(0, 0, 1512, 982);       // a window of 1512x982 points
    layer.drawableSize = CGSizeMake(gameW, gameH);    // as D3DMetal sets it
    const CGSize after = layer.drawableSize;
    printf("info: layer drawable size after the game set %lux%lu: %.0fx%.0f\n", (unsigned long)gameW, (unsigned long)gameH, after.width, after.height);

    // The game's frame, as D3DMetal keeps it: its own texture, copied into each drawable.
    // Filled from an 8-bit test card, so every format holds the same picture as encoded.
    id<MTLTexture> card = makeTexture(dev, 1512, 982, MTLTextureUsageShaderRead);
    id<MTLTexture> (^gameTexture)(NSUInteger, NSUInteger) = ^id<MTLTexture>(NSUInteger w, NSUInteger h) {
        MTLTextureDescriptor* bd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
        bd.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;
        bd.storageMode = MTLStorageModePrivate;
        return [dev newTextureWithDescriptor:bd];
    };
    void (^paint)(id<MTLTexture>, int) = ^(id<MTLTexture> t, int shift) {
        id<MTLTexture> c = (card.width == t.width && card.height == t.height) ? card : makeTexture(dev, t.width, t.height, MTLTextureUsageShaderRead);
        fillCard(c, shift);
        copyColour(q, c, t);
    };
    id<MTLTexture> back = gameTexture(gameW, gameH);
    paint(back, 0);
    int resized = 0;

    signal(SIGALRM, watchdog);
    const int frames = (int)(seconds * fps);
    int ownSize = 0, proxies = 0;
    id<MTLTexture> sampledReal = nil;
    id<MTLCommandBuffer> sampledCb = nil;
    NSUInteger sampledGameW = 0, sampledGameH = 0;
    const double t0 = CACurrentMediaTime();
    for (int f = 0; f < frames; ++f) {
        @autoreleasepool {
            alarm(2);
            // The game resizes, as on a window change: its frame and the layer, as D3DMetal does.
            if (resize && (f == frames / 3 || f == 2 * frames / 3)) {
                gameW = (f == frames / 3) ? 1280 : 1512; gameH = (f == frames / 3) ? 800 : 982;
                back = gameTexture(gameW, gameH);
                paint(back, f);
                layer.drawableSize = CGSizeMake(gameW, gameH);
                resized++;
            }
            if (f % 30 == 0) paint(back, f);            // motion, now and then
            id<CAMetalDrawable> d = [layer nextDrawable];
            if (!d) { printf("FAIL: no drawable at frame %d\n", f); failures++; break; }
            if (d.texture.width == gameW && d.texture.height == gameH) ownSize++;
            else if (f < 3 || f % 500 == 0) printf("info: frame %d: drawable %lux%lu, game draws %lux%lu\n", f, (unsigned long)d.texture.width, (unsigned long)d.texture.height, (unsigned long)gameW, (unsigned long)gameH);
            Class cls = object_getClass(d);
            if (strcmp(class_getName(cls), "AnvilProxyDrawable") == 0) proxies++;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit copyFromTexture:back toTexture:d.texture];
            [blit endEncoding];
            __block int presented = 0;
            [d addPresentedHandler:^(id<MTLDrawable> x) { (void)x; presented = 1; }];
            [cb presentDrawable:d];
            [cb commit];
            if (f == frames / 2 && strcmp(class_getName(cls), "AnvilProxyDrawable") == 0) {
                Ivar iv = class_getInstanceVariable(cls, "_real");
                id real = iv ? object_getIvar((id)d, iv) : nil;
                sampledReal = [(id<CAMetalDrawable>)real texture];
                sampledCb = cb;
                sampledGameW = gameW; sampledGameH = gameH;
            }
            // The game's pace.
            const double due = t0 + (f + 1) / fps;
            const double wait = due - CACurrentMediaTime();
            if (wait > 0) usleep((useconds_t)(wait * 1e6));
        }
    }
    alarm(0);
    const double took = CACurrentMediaTime() - t0;
    printf("info: %d frames in %.1f s (%.0f fps asked, %.0f made)\n", frames, took, fps, frames / took);
    check(ownSize == frames, [NSString stringWithFormat:@"the game got a drawable of its own size every frame (%d of %d)", ownSize, frames]);
    if (resize) printf("info: the game resized %d times\n", resized);
    if (!expectProxy) {
        check(proxies == 0, [NSString stringWithFormat:@"no stand-ins where FSR mustn't run (%d)", proxies]);
        check(after.width == gameW && after.height == gameH, @"the layer kept the game's own size");
        return failures ? 1 : 0;
    }
    check(proxies == frames, [NSString stringWithFormat:@"every one was Anvil's stand-in (%d of %d)", proxies, frames]);
    check(after.width == 3024 && after.height == 1964, @"the layer was set to the display's 3024x1964");
    uint64_t (*generated)(void) = (uint64_t (*)(void))dlsym(RTLD_DEFAULT, "AnvilGeneratedFrames");
    uint64_t (*upscaled)(void) = (uint64_t (*)(void))dlsym(RTLD_DEFAULT, "AnvilUpscaledFrames");
    const uint64_t gen = generated ? generated() : 0, up = upscaled ? upscaled() : 0;
    printf("info: Anvil upscaled %llu frames and generated %llu\n", (unsigned long long)up, (unsigned long long)gen);
    check(up >= (uint64_t)frames, @"every frame of the game's went through FSR");
    if (getenv("ANVIL_FSR3") && getenv("ANVIL_FSR3")[0] == '1') {
        uint64_t (*fsr3)(void) = (uint64_t (*)(void))dlsym(RTLD_DEFAULT, "AnvilFSR3Frames");
        const uint64_t n3 = fsr3 ? fsr3() : 0;
        check(n3 >= (uint64_t)frames, [NSString stringWithFormat:@"every frame of the game's went through FSR 3 (%llu of %d)", (unsigned long long)n3, frames]);
    }
    if (getenv("ANVIL_FRAME_GEN") && getenv("ANVIL_FRAME_GEN")[0] == '1')
        check(gen > (uint64_t)(frames / 4), [NSString stringWithFormat:@"frame generation made frames (%llu)", (unsigned long long)gen]);
    if (sampledReal) {
        [sampledCb waitUntilCompleted];
        // The display's 3024x1964 — or, for a frame of another shape (the resize case's 1280x800,
        // 16:10), that shape whole inside it, with bars, not stretched (0.30): 3024x1890.
        double wantW = 3024, wantH = 1964;
        if (sampledGameW > 0 && sampledGameH > 0) {
            const double g = (double)sampledGameW / sampledGameH, b = wantW / wantH;
            if (fabs(g / b - 1.0) > 0.02) { if (g > b) wantH = round(wantW / g); else wantW = round(wantH * g); }
        }
        check(sampledReal.width == (NSUInteger)wantW && sampledReal.height == (NSUInteger)wantH,
              [NSString stringWithFormat:@"the real drawable is %.0fx%.0f (%lux%lu)", wantW, wantH,
               (unsigned long)sampledReal.width, (unsigned long)sampledReal.height]);
        // Read the shown frame back: a flat area holds the game's colour.
        id<MTLTexture> copy = makeTexture(dev, sampledReal.width, sampledReal.height, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
        copyColour(q, sampledReal, copy);
        NSData* data = readBack(copy);
        const uint8_t* p = data.bytes;
        const uint8_t* px = p + (1000 * 3024 + 300) * 4;
        check(abs(px[2] - 200) <= 2 && abs(px[1] - 60) <= 2 && abs(px[0] - 40) <= 2,
              [NSString stringWithFormat:@"the shown frame is the game's, upscaled (a flat area reads %d,%d,%d; drew 200,60,40)", px[2], px[1], px[0]]);
    } else {
        check(NO, @"a real drawable to read back");
    }
    return failures ? 1 : 0;
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        if (argc >= 3 && strcmp(argv[1], "shaders") == 0) {
            int r = shaders([NSString stringWithUTF8String:argv[2]]);
            printf(r == 0 ? "fsr shaders: all checks passed\n" : "fsr shaders: %d failure(s)\n", failures);
            return r;
        }
        if (argc >= 4 && strcmp(argv[1], "pipeline") == 0) {
            int r = pipeline(atof(argv[2]), atof(argv[3]));
            printf(r == 0 ? "fsr pipeline: all checks passed\n" : "fsr pipeline: %d failure(s)\n", failures);
            return r;
        }
        printf("usage: fsr_bench shaders <metal source> | pipeline <seconds> <fps>\n");
        return 2;
    }
}

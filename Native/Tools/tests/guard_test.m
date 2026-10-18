// Metal guard: the depth-stencil state that stopped LEGO Star Wars on 3 October, on the Mac's
// own GPU. Needs a GPU, so it runs outside Claude's sandbox.
//
//   clang -fobjc-arc -arch arm64 -arch x86_64 -framework Metal -framework Foundation \
//     Native/Tools/tests/guard_test.m -o $TMPDIR/guard_test
//
//   guard_test                                   Metal's own answer: a failed assertion, which
//                                                stops the process (the control).
//   DYLD_INSERT_LIBRARIES=libanvil.dylib guard_test
//                                                The state is put right and made, the frame that
//                                                uses it completes, and a valid one is untouched.
//   arch -x86_64 …                               The same under Rosetta, where games run.
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("FAIL: no GPU\n"); return 1; }
        int (*corrections)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "AnvilGuardCorrections");
        printf("info: %s, Anvil's library %s\n", dev.name.UTF8String, corrections ? "in" : "not in");

        MTLDepthStencilDescriptor* valid = [MTLDepthStencilDescriptor new];
        valid.depthCompareFunction = MTLCompareFunctionLess;
        valid.depthWriteEnabled = YES;
        id<MTLDepthStencilState> good = [dev newDepthStencilStateWithDescriptor:valid];
        printf("%s: a valid state is made\n", good ? "ok" : "FAIL");
        const int before = corrections ? corrections() : 0;
        printf("%s: and left as it was (%d corrections)\n", before == 0 ? "ok" : "FAIL", before);

        // What LEGO asked for: stencil operations and a compare function out of range on its
        // front face, one more operation on its back.
        MTLDepthStencilDescriptor* bad = [MTLDepthStencilDescriptor new];
        bad.depthCompareFunction = MTLCompareFunctionLessEqual;
        bad.depthWriteEnabled = YES;
        MTLStencilDescriptor* front = [MTLStencilDescriptor new];
        front.stencilFailureOperation = (MTLStencilOperation)0xFFFFFFFF;
        front.depthFailureOperation = (MTLStencilOperation)0xFFFFFFFF;
        front.depthStencilPassOperation = (MTLStencilOperation)0xFFFFFFFF;
        front.stencilCompareFunction = (MTLCompareFunction)0xFFFFFFFF;
        bad.frontFaceStencil = front;
        MTLStencilDescriptor* back = [MTLStencilDescriptor new];
        back.depthStencilPassOperation = (MTLStencilOperation)0xFFFFFFFF;
        bad.backFaceStencil = back;
        printf("info: asking for LEGO's state (without Anvil, Metal stops the process here)\n");
        id<MTLDepthStencilState> fixed = [dev newDepthStencilStateWithDescriptor:bad];
        printf("%s: the state is made\n", fixed ? "ok" : "FAIL");
        const int after = corrections ? corrections() : 0;
        printf("%s: put right once (%d)\n", after == 1 ? "ok" : "FAIL", after);

        // And used: a render pass with a depth-stencil target draws with it and completes.
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                                                                      width:64 height:64 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> depth = [dev newTextureWithDescriptor:td];
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.depthAttachment.texture = depth;
        rp.depthAttachment.loadAction = MTLLoadActionClear;
        rp.depthAttachment.storeAction = MTLStoreActionDontCare;
        rp.stencilAttachment.texture = depth;
        rp.stencilAttachment.loadAction = MTLLoadActionClear;
        rp.stencilAttachment.storeAction = MTLStoreActionDontCare;
        rp.renderTargetWidth = 64;
        rp.renderTargetHeight = 64;
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setDepthStencilState:fixed];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        printf("%s: a frame using it completes\n", cb.status == MTLCommandBufferStatusCompleted ? "ok" : "FAIL");
        const BOOL passed = good && before == 0 && fixed && after == 1 && cb.status == MTLCommandBufferStatusCompleted;
        printf(passed ? "metal guard: all checks passed\n" : "metal guard: FAILED\n");
        return passed ? 0 : 1;
    }
}

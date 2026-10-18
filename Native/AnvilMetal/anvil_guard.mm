// Metal state a game asks for, put right before Metal sees it.
//
// On 3 October LEGO Star Wars froze for good seven minutes into a session, as it loaded a
// new area. Through D3DMetal it had asked Metal for a depth-stencil state whose stencil
// operations and compare function were out of range. Metal's own message, in anvil.log:
// "operation is not a valid MTLStencilOperation" four times and "function is not a valid
// MTLCompareFunction" once. Metal answers that with a failed assertion, which aborts. Under
// Wine the abort became an exception the game never came back from, and it had to be force
// quit. It had not happened in 38 earlier sessions: a path in the game only that area takes.
//
// So every depth-stencil descriptor is looked at on its way to Metal, and a value out of
// range is put back to Direct3D's own default for it — keep for an operation, always for a
// comparison, which is a stencil that changes nothing. A valid state goes through untouched.
// One that isn't costs a copy of its descriptor, once: D3DMetal keeps the states it makes.
// Reading a descriptor changes nothing about it (checked: a fresh one still compares equal
// to another after its stencil faces are read), and a copy keeps the values as they are.
//
// The hook goes in on the device D3DMetal makes, the moment it makes it: Metal hands out its
// devices through MTLCreateSystemDefaultDevice and MTLCopyAllDevices, both interposed here.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <atomic>
#include <mutex>

namespace {

IMP g_originalNewDepthStencil = nullptr;
std::atomic<int> g_corrected{0};

bool validCompare(NSUInteger v) { return v <= MTLCompareFunctionAlways; }
bool validOperation(NSUInteger v) { return v <= MTLStencilOperationDecrementWrap; }

bool stencilValid(MTLStencilDescriptor* s) {
    return !s || (validCompare(s.stencilCompareFunction) && validOperation(s.stencilFailureOperation)
                  && validOperation(s.depthFailureOperation) && validOperation(s.depthStencilPassOperation));
}

/// The values out of range set to Direct3D's defaults; how many there were.
int correctStencil(MTLStencilDescriptor* s) {
    if (!s) return 0;
    int n = 0;
    if (!validCompare(s.stencilCompareFunction)) { s.stencilCompareFunction = MTLCompareFunctionAlways; n++; }
    if (!validOperation(s.stencilFailureOperation)) { s.stencilFailureOperation = MTLStencilOperationKeep; n++; }
    if (!validOperation(s.depthFailureOperation)) { s.depthFailureOperation = MTLStencilOperationKeep; n++; }
    if (!validOperation(s.depthStencilPassOperation)) { s.depthStencilPassOperation = MTLStencilOperationKeep; n++; }
    return n;
}

/// The first few corrections, in game.log.
void note(int values) {
    const int seen = g_corrected.fetch_add(1) + 1;
    if (seen > 3) return;
    const char* path = getenv("ANVIL_LOG");
    if (!path) return;
    if (FILE* f = fopen(path, "a")) {
        fprintf(f, "[anvil] metal guard: the game asked for a depth-stencil state with %d value%s out of range — "
                   "set to Direct3D's defaults (keep, always) instead of letting Metal stop the game%s\n",
                values, values == 1 ? "" : "s", seen == 3 ? " (further ones not listed)" : "");
        fclose(f);
    }
}

id hookedNewDepthStencilState(id self, SEL cmd, MTLDepthStencilDescriptor* desc) {
    auto original = (id (*)(id, SEL, MTLDepthStencilDescriptor*))g_originalNewDepthStencil;
    if (!desc || (validCompare(desc.depthCompareFunction) && stencilValid(desc.frontFaceStencil)
                  && stencilValid(desc.backFaceStencil)))
        return original(self, cmd, desc);
    MTLDepthStencilDescriptor* fixed = [desc copy];
    int values = 0;
    if (!validCompare(fixed.depthCompareFunction)) { fixed.depthCompareFunction = MTLCompareFunctionAlways; values++; }
    // The faces' getters hand back the descriptor's own stencil descriptors, so they are
    // corrected where they are; set back as well, for a Metal that returns copies.
    MTLStencilDescriptor* front = fixed.frontFaceStencil;
    MTLStencilDescriptor* back = fixed.backFaceStencil;
    values += correctStencil(front);
    values += correctStencil(back);
    fixed.frontFaceStencil = front;
    fixed.backFaceStencil = back;
    id state = original(self, cmd, fixed);
    [fixed release];
    note(values);
    return state;
}

void guardDevice(id<MTLDevice> device) {
    if (!device) return;
    static std::mutex lock;
    std::lock_guard<std::mutex> hold(lock);
    Class cls = object_getClass(device);
    SEL sel = @selector(newDepthStencilStateWithDescriptor:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m || method_getImplementation(m) == (IMP)hookedNewDepthStencilState) return;
    if (g_originalNewDepthStencil) {
        // Another class of device (a second GPU): its own method, hooked the same way only
        // if it is the same implementation — two different ones can't share one original.
        if (method_getImplementation(m) != g_originalNewDepthStencil) return;
    }
    // On the class itself, so a method it inherits is overridden there rather than changed
    // for every class above it.
    IMP original = method_getImplementation(m);
    if (!class_addMethod(cls, sel, (IMP)hookedNewDepthStencilState, method_getTypeEncoding(m)))
        method_setImplementation(m, (IMP)hookedNewDepthStencilState);
    g_originalNewDepthStencil = original;
}

} // namespace

// anvil_inject.mm: Anvil's shaders start compiling in the background when the game opens Metal.
extern "C" void AnvilWarmShaders(id<MTLDevice> device);
// anvil_gpuwork.mm: texture detail for FSR and the game's shader compiles, on the same device.
extern "C" void AnvilWatchDevice(id<MTLDevice> device);

extern "C" id<MTLDevice> anvil_MTLCreateSystemDefaultDevice(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    guardDevice(device);
    AnvilWatchDevice(device);
    AnvilWarmShaders(device);
    return device;
}

extern "C" NSArray<id<MTLDevice>>* anvil_MTLCopyAllDevices(void) {
    NSArray<id<MTLDevice>>* devices = MTLCopyAllDevices();
    for (id<MTLDevice> d in devices) { guardDevice(d); AnvilWatchDevice(d); }
    // The one a game draws with on a Mac with one GPU; on any other, its first frame checks.
    if (devices.count > 0) AnvilWarmShaders(devices.firstObject);
    return devices;
}

/// How many invalid states were put right this session, for tests.
extern "C" int AnvilGuardCorrections() { return g_corrected.load(); }

__attribute__((used, section("__DATA,__interpose")))
static struct { const void* replacement; const void* original; } anvil_guard_interposes[] = {
    { (const void*)&anvil_MTLCreateSystemDefaultDevice, (const void*)&MTLCreateSystemDefaultDevice },
    { (const void*)&anvil_MTLCopyAllDevices,            (const void*)&MTLCopyAllDevices },
};

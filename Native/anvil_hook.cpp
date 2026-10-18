// Anvil's own DXGI proxy.
//
// A game loads dxgi.dll by name. This library takes that name, forwards every
// export on to the real system dxgi so nothing breaks, and uses the fact that it
// is now inside the process to wrap the swapchain's Present. That wrap is the seam
// where an upscaling or interpolation pass runs.
//
// This exists so Anvil needs no third-party mod: the only binary involved is one
// built on the user's own machine from this file plus AMD's published source.

#include <windows.h>
#include <dxgi1_6.h>
#include <d3d12.h>
#include <cstdio>
#include <cstdint>

namespace {

HMODULE g_realDxgi = nullptr;

// ---- Forwarding -------------------------------------------------------------
// Every export the game might call has to reach the real dxgi, or the process
// dies at load time rather than running slower.

FARPROC realProc(const char* name) {
    if (!g_realDxgi) {
        char path[MAX_PATH];
        GetSystemDirectoryA(path, MAX_PATH);
        strcat_s(path, "\\dxgi.dll");
        g_realDxgi = LoadLibraryA(path);
    }
    return g_realDxgi ? GetProcAddress(g_realDxgi, name) : nullptr;
}

// ---- Present interception ---------------------------------------------------

using PresentFn = HRESULT (STDMETHODCALLTYPE*)(IDXGISwapChain*, UINT, UINT);
using Present1Fn = HRESULT (STDMETHODCALLTYPE*)(IDXGISwapChain1*, UINT, UINT,
                                                const DXGI_PRESENT_PARAMETERS*);

PresentFn  g_originalPresent  = nullptr;
Present1Fn g_originalPresent1 = nullptr;

uint64_t g_frameCount = 0;

// Anvil sets these from the launch environment so the DLL needs no config file.
bool     g_enabled       = true;
bool     g_logFrames     = false;

void readEnvironment() {
    char buf[64];
    if (GetEnvironmentVariableA("ANVIL_HOOK_ENABLED", buf, sizeof(buf)) > 0)
        g_enabled = (buf[0] == '1');
    if (GetEnvironmentVariableA("ANVIL_HOOK_LOG", buf, sizeof(buf)) > 0)
        g_logFrames = (buf[0] == '1');
}

// The per-frame seam.
//
// What is implemented: the interception itself — Anvil is on the frame boundary
// with the swapchain in hand, which is the hard part to get right and the part a
// game cannot refuse.
//
// What is NOT implemented here: the upscale/interpolation dispatch. That needs the
// FSR library built from AMD's source, and — for anything temporal — motion vectors
// the swapchain does not carry. Leaving this honest and empty is deliberate: a stub
// that pretended to interpolate would be worse than no stub.
void onPresent(IDXGISwapChain* swapChain) {
    ++g_frameCount;
    if (!g_enabled) return;

    ID3D12Device* device = nullptr;
    if (SUCCEEDED(swapChain->GetDevice(__uuidof(ID3D12Device), (void**)&device))) {
        // Backbuffer is reachable here; this is where an FSR1 spatial pass would be
        // dispatched, since it needs only the finished colour target.
        device->Release();
    }

    if (g_logFrames && (g_frameCount % 600 == 0)) {
        char msg[128];
        sprintf_s(msg, "[anvil] %llu frames presented\n", (unsigned long long)g_frameCount);
        OutputDebugStringA(msg);
    }
}

HRESULT STDMETHODCALLTYPE hookedPresent(IDXGISwapChain* self, UINT interval, UINT flags) {
    onPresent(self);
    return g_originalPresent(self, interval, flags);
}

HRESULT STDMETHODCALLTYPE hookedPresent1(IDXGISwapChain1* self, UINT interval, UINT flags,
                                         const DXGI_PRESENT_PARAMETERS* params) {
    onPresent(self);
    return g_originalPresent1(self, interval, flags, params);
}

// Swap a vtable entry. The swapchain vtable is shared process-wide, so this only
// has to happen once, on the first swapchain the game creates.
void installVTableHook(IDXGISwapChain* swapChain) {
    if (!swapChain || g_originalPresent) return;

    void** vtable = *reinterpret_cast<void***>(swapChain);
    DWORD oldProtect = 0;

    // Present is slot 8, Present1 is slot 22 in IDXGISwapChain1.
    if (VirtualProtect(&vtable[8], sizeof(void*), PAGE_EXECUTE_READWRITE, &oldProtect)) {
        g_originalPresent = reinterpret_cast<PresentFn>(vtable[8]);
        vtable[8] = reinterpret_cast<void*>(&hookedPresent);
        VirtualProtect(&vtable[8], sizeof(void*), oldProtect, &oldProtect);
    }

    IDXGISwapChain1* sc1 = nullptr;
    if (SUCCEEDED(swapChain->QueryInterface(__uuidof(IDXGISwapChain1), (void**)&sc1))) {
        void** vt1 = *reinterpret_cast<void***>(sc1);
        if (VirtualProtect(&vt1[22], sizeof(void*), PAGE_EXECUTE_READWRITE, &oldProtect)) {
            g_originalPresent1 = reinterpret_cast<Present1Fn>(vt1[22]);
            vt1[22] = reinterpret_cast<void*>(&hookedPresent1);
            VirtualProtect(&vt1[22], sizeof(void*), oldProtect, &oldProtect);
        }
        sc1->Release();
    }
}

} // namespace

// ---- Exports ----------------------------------------------------------------

extern "C" {

__declspec(dllexport) HRESULT WINAPI CreateDXGIFactory(REFIID riid, void** out) {
    using Fn = HRESULT(WINAPI*)(REFIID, void**);
    auto fn = reinterpret_cast<Fn>(realProc("CreateDXGIFactory"));
    return fn ? fn(riid, out) : E_FAIL;
}

__declspec(dllexport) HRESULT WINAPI CreateDXGIFactory1(REFIID riid, void** out) {
    using Fn = HRESULT(WINAPI*)(REFIID, void**);
    auto fn = reinterpret_cast<Fn>(realProc("CreateDXGIFactory1"));
    return fn ? fn(riid, out) : E_FAIL;
}

__declspec(dllexport) HRESULT WINAPI CreateDXGIFactory2(UINT flags, REFIID riid, void** out) {
    using Fn = HRESULT(WINAPI*)(UINT, REFIID, void**);
    auto fn = reinterpret_cast<Fn>(realProc("CreateDXGIFactory2"));
    return fn ? fn(flags, riid, out) : E_FAIL;
}

__declspec(dllexport) HRESULT WINAPI DXGIGetDebugInterface1(UINT flags, REFIID riid, void** out) {
    using Fn = HRESULT(WINAPI*)(UINT, REFIID, void**);
    auto fn = reinterpret_cast<Fn>(realProc("DXGIGetDebugInterface1"));
    return fn ? fn(flags, riid, out) : E_FAIL;
}

__declspec(dllexport) HRESULT WINAPI DXGIDeclareAdapterRemovalSupport() {
    using Fn = HRESULT(WINAPI*)();
    auto fn = reinterpret_cast<Fn>(realProc("DXGIDeclareAdapterRemovalSupport"));
    return fn ? fn() : E_FAIL;
}

/// Anvil calls this from its own code path once a swapchain exists.
__declspec(dllexport) void WINAPI AnvilInstallHook(IDXGISwapChain* swapChain) {
    installVTableHook(swapChain);
}

__declspec(dllexport) uint64_t WINAPI AnvilFrameCount() { return g_frameCount; }

} // extern "C"

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        readEnvironment();
    }
    return TRUE;
}

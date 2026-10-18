// anvil-sdl-probe — asks the engine's own libSDL2 what a game will see.
//
// Wine reads controllers through SDL, so "Anvil can see my pad" and "the game can see
// my pad" are different questions. This loads the exact libSDL2 inside the selected
// engine, with the exact SDL settings a launch would use (taken from the environment),
// and reports each controller: whether SDL enumerates it, whether it is a gamepad,
// the mapping it uses — and, with PROBE_SECONDS set, every input it reads.
//
// It found the macOS 27 regression: with SDL's GameController hand-off on, SDL saw
// zero controllers; with SDL_JOYSTICK_MFI=0 it saw the pad and read 163 inputs.
//
// Built x86_64 because the engine's libSDL2 is x86_64; it runs through Rosetta.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
typedef struct { unsigned char data[16]; } GUID;
#define LOAD(name) name##_t name = (name##_t)dlsym(h, #name); if (!name) { printf("missing %s\n", #name); return 2; }
typedef int (*SDL_Init_t)(unsigned);
typedef int (*SDL_NumJoysticks_t)(void);
typedef const char* (*SDL_JoystickNameForIndex_t)(int);
typedef GUID (*SDL_JoystickGetDeviceGUID_t)(int);
typedef void (*SDL_JoystickGetGUIDString_t)(GUID, char*, int);
typedef int (*SDL_IsGameController_t)(int);
typedef char* (*SDL_GameControllerMappingForDeviceIndex_t)(int);
typedef int (*SDL_GameControllerTypeForIndex_t)(int);
typedef const char* (*SDL_JoystickPathForIndex_t)(int);
typedef void (*SDL_JoystickUpdate_t)(void);
typedef void (*SDL_PumpEvents_t)(void);
typedef const char* (*SDL_GetError_t)(void);
typedef void (*SDL_GetVersion_t)(unsigned char*);
typedef void* (*SDL_GameControllerOpen_t)(int);
typedef unsigned char (*SDL_GameControllerGetButton_t)(void*, int);
typedef short (*SDL_GameControllerGetAxis_t)(void*, int);
typedef void (*SDL_GameControllerUpdate_t)(void);
static const char* type_name(int t) {
    static const char* n[] = {"unknown","Xbox 360","Xbox One","PS3","PS4","Switch Pro","virtual","PS5","Amazon Luna","Stadia","NVIDIA Shield","Joy-Con L","Joy-Con R","Joy-Con pair"};
    return (t >= 0 && t < 14) ? n[t] : "?";
}
int main(int argc, char** argv) {
    void* h = dlopen(argv[1], RTLD_NOW);
    if (!h) { printf("dlopen failed: %s\n", dlerror()); return 1; }
    LOAD(SDL_Init) LOAD(SDL_NumJoysticks) LOAD(SDL_JoystickNameForIndex) LOAD(SDL_JoystickGetDeviceGUID)
    LOAD(SDL_JoystickGetGUIDString) LOAD(SDL_IsGameController) LOAD(SDL_GameControllerMappingForDeviceIndex)
    LOAD(SDL_GameControllerTypeForIndex) LOAD(SDL_JoystickUpdate) LOAD(SDL_PumpEvents) LOAD(SDL_GetError) LOAD(SDL_GetVersion)
    SDL_JoystickPathForIndex_t SDL_JoystickPathForIndex = (SDL_JoystickPathForIndex_t)dlsym(h, "SDL_JoystickPathForIndex");
    unsigned char v[3]; SDL_GetVersion(v);
    if (SDL_Init(0x2000 | 0x200) != 0) { printf("SDL_Init failed: %s\n", SDL_GetError()); return 1; }
    for (int i = 0; i < 30; ++i) { SDL_PumpEvents(); SDL_JoystickUpdate(); usleep(50000); }
    int n = SDL_NumJoysticks();
    printf("SDL %d.%d.%d  HIDAPI=%s  joysticks=%d\n", v[0], v[1], v[2], getenv("SDL_JOYSTICK_HIDAPI") ?: "(default)", n);
    for (int i = 0; i < n; ++i) {
        char g[64]; SDL_JoystickGetGUIDString(SDL_JoystickGetDeviceGUID(i), g, sizeof g);
        char* m = SDL_GameControllerMappingForDeviceIndex(i);
        printf("  [%d] %s\n      guid=%s gamepad=%d type=%s path=%s\n      mapping=%s\n", i,
               SDL_JoystickNameForIndex(i), g, SDL_IsGameController(i),
               type_name(SDL_GameControllerTypeForIndex(i)),
               SDL_JoystickPathForIndex ? (SDL_JoystickPathForIndex(i) ?: "-") : "-",
               m ? m : "(none)");
    }
    // Live input: press buttons on the pad and watch them arrive.
    if (getenv("PROBE_SECONDS") && n > 0) {
        LOAD(SDL_GameControllerOpen) LOAD(SDL_GameControllerGetButton) LOAD(SDL_GameControllerGetAxis) LOAD(SDL_GameControllerUpdate)
        int idx = -1; for (int i = 0; i < n; ++i) if (SDL_IsGameController(i)) { idx = i; break; }
        if (idx < 0) { printf("  no gamepad to read input from\n"); return 0; }
        void* pad = SDL_GameControllerOpen(idx);
        if (!pad) { printf("  could not open the pad: %s\n", SDL_GetError()); return 0; }
        static const char* names[] = {"A (bottom)","B (right)","X (left)","Y (top)","Back/-","Guide/Home","Start/+","L-stick click","R-stick click","L shoulder","R shoulder","D-pad up","D-pad down","D-pad left","D-pad right"};
        int secs = atoi(getenv("PROBE_SECONDS")); unsigned char was[15] = {0}; int events = 0;
        printf("  >>> PRESS BUTTONS AND MOVE THE STICKS NOW (%d seconds) <<<\n", secs); fflush(stdout);
        for (int t = 0; t < secs * 200; ++t) {
            SDL_PumpEvents(); SDL_GameControllerUpdate();
            for (int b = 0; b < 15; ++b) { unsigned char v = SDL_GameControllerGetButton(pad, b);
                if (v != was[b]) { if (v) { printf("    pressed %s\n", names[b]); events++; } was[b] = v; fflush(stdout); } }
            if (t % 100 == 0) { short lx = SDL_GameControllerGetAxis(pad, 0), ly = SDL_GameControllerGetAxis(pad, 1), rx = SDL_GameControllerGetAxis(pad, 2), ry = SDL_GameControllerGetAxis(pad, 3), lt = SDL_GameControllerGetAxis(pad, 4), rt = SDL_GameControllerGetAxis(pad, 5);
                if (abs(lx) > 8000 || abs(ly) > 8000 || abs(rx) > 8000 || abs(ry) > 8000 || lt > 8000 || rt > 8000) { printf("    sticks L(%d,%d) R(%d,%d) triggers %d %d\n", lx, ly, rx, ry, lt, rt); events++; fflush(stdout); } }
            usleep(5000);
        }
        printf("  input events seen: %d\n", events);
    }
    // Event rate: the number Wine turns into HID reports. Read through
    // SDL_WaitEventTimeout exactly as Wine's winebus does, so when Anvil's injector is
    // loaded its filter sits in the same place it does in a game.
    if (getenv("PROBE_EVENTS") && n > 0) {
        typedef int (*Wait_t)(void*, int);
        Wait_t wait = (Wait_t)dlsym(h, "SDL_WaitEventTimeout");
        typedef void* (*Open_t)(int); Open_t open = (Open_t)dlsym(h, "SDL_GameControllerOpen");
        int idx = -1; for (int i = 0; i < n; ++i) if (SDL_IsGameController(i)) { idx = i; break; }
        if (idx < 0 || !wait || !open || !open(idx)) { printf("  cannot read events\n"); return 0; }
        int secs = atoi(getenv("PROBE_EVENTS"));
        printf("  >>> HOLD THE STICKS STILL for %d s, then MOVE THEM for %d s <<<\n", secs / 2, secs - secs / 2); fflush(stdout);
        unsigned char ev[64]; int axis = 0, button = 0, other = 0;
        int total_axis = 0, total_button = 0;
        for (int t = 1; t <= secs; ++t) {
            axis = button = other = 0;
            for (int ms = 0; ms < 1000; ) {
                int got = wait(ev, 1);
                if (got == 1) {
                    unsigned type = ev[0] | ev[1] << 8 | ev[2] << 16 | ev[3] << 24;
                    if (type == 0x650) axis++; else if (type == 0x651 || type == 0x652) button++; else other++;
                } else { usleep(1000); ms++; }
            }
            total_axis += axis; total_button += button;
            printf("    %2ds %s: %4d stick/trigger events, %3d button events\n", t, t <= secs / 2 ? "(still) " : "(moving)", axis, button); fflush(stdout);
        }
        printf("  total: %d stick/trigger, %d button events\n", total_axis, total_button);
    }
    return 0;
}

#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
int main(int argc, char** argv) {
    void* h = dlopen(argv[1], RTLD_NOW);
    int (*wait)(void*, int) = dlsym(h, "SDL_WaitEventTimeout");   // through Anvil's dlsym when injected
    unsigned char ev[56]; int delivered = 0, last[8] = {0}; double lastAt[8] = {0}, minGap = 1;
    int16_t finalX = 12345; double t0 = now();
    while (now() - t0 < 0.6) {
        if (wait(ev, 10) == 1) {
            uint32_t type; memcpy(&type, ev, 4); if (type != 0x650) continue;
            int axis = ev[12]; int16_t v; memcpy(&v, ev + 16, 2);
            double t = now();
            if (lastAt[axis] > 0 && t - lastAt[axis] < minGap) minGap = t - lastAt[axis];
            lastAt[axis] = t; last[axis] = v; delivered++;
            if (axis == 0) finalX = v;
        }
    }
    printf("  events reaching Wine: %d (301 generated)\n", delivered);
    printf("  closest two updates of one axis: %.1f ms\n", minGap * 1000);
    printf("  final left-stick X after release: %d  %s\n", finalX, finalX == 0 ? "(back at centre — not stuck)" : "(STUCK)");
    return finalX == 0 ? 0 : 1;
}

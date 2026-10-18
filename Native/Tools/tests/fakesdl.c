// Stands in for libSDL2: plays a scripted stick movement through SDL_WaitEventTimeout,
// one axis event per millisecond, the way a pad at full tilt feeds Wine.
#include <string.h>
#include <unistd.h>
#include <stdint.h>
static int step = 0;
int SDL_WaitEventTimeout(void* ev, int timeout) {
    if (step > 300) { usleep(timeout * 1000); return 0; }
    usleep(1000);
    unsigned char* e = ev; memset(e, 0, 56);
    uint32_t type = 0x650; memcpy(e, &type, 4);
    int32_t which = 0; memcpy(e + 8, &which, 4);
    int16_t v;
    if (step < 150)      { e[12] = 0; v = (int16_t)(step * 200); }          // left X sweeps right
    else if (step < 300) { e[12] = step % 2 ? 0 : 1; v = (int16_t)(30000 - (step - 150) * 200); } // both axes, interleaved
    else                 { e[12] = 0; v = 0; }                              // released: back to centre
    memcpy(e + 16, &v, 2);
    step++;
    return 1;
}

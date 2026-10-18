// The game's file reads, inside its process: timed, so a stutter can be put down to reading the game's
// data when that's what it was (Guardian's stutter reports), and where in its large data files they land,
// so the parts played most can be read into memory before the next start (Core/MemoryWarmup.swift).
#pragma once
#include <cstddef>
#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

/// Everything read from files so far this session: calls, bytes, and the time spent in them.
typedef struct AnvilReadTotals {
    uint64_t calls;
    uint64_t bytes;
    uint64_t ns;
    uint64_t slow;      // reads that took 20 ms or more
} AnvilReadTotals;

void AnvilReadTotalsGet(AnvilReadTotals* out);

/// Where the game's large files were read, merged with what earlier sessions saw, written to
/// ANVIL_WARM_STATE (nothing without it). Called now and then while the game runs; cheap when nothing
/// new was read. Returns the files written, -1 when it couldn't be.
int AnvilReadHeatSave(void);

#ifdef __cplusplus
}
#endif

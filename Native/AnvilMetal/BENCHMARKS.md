# Measured pass costs

Apple M4, 2560×1440 internal → 3840×2160 output, `rgba16Float`, 60 iterations
after warm-up, measured with `MTLCommandBuffer.waitUntilCompleted`.

| Pass | Cost |
|---|---|
| EASU upscale | 1.56 ms |
| RCAS sharpen | 1.68 ms |
| **FSR1 total** | **3.24 ms** |
| Luma pyramid (per frame) | 0.81 ms |
| Optical flow, 3-step | 0.84 ms |
| Frame interpolation | 2.25 ms |
| **Frame generation total** | **3.90 ms** |

Budget at 60 fps is 16.67 ms, at 120 fps 8.33 ms. Both pipelines fit at 4K.

## What the optimisation was

The first optical-flow kernel did an exhaustive ±8 search with a 7×7 block over the
full-resolution colour frame: 289 candidates × 49 taps = 14,161 texture reads per
flow pixel. It measured **192.33 ms** — twelve times the entire frame budget.

Three changes, together a 230× improvement on that pass:

1. **Search a quarter-resolution single-channel luma plane.** Motion doesn't need
   chroma, and the working set then fits in cache.
2. **Three-step logarithmic search** — probe 8 neighbours at radius 4, recentre,
   halve, repeat. Same ±7 range in 25 candidates instead of 289.
3. **5×5 blocks instead of 7×7** — 25 taps rather than 49.

The block-matching surface is smooth enough at quarter resolution that the coarse
first step reliably lands in the right basin, so the accuracy cost is small.

## Frame generation, verified end to end

Injected into a Metal host that submits 30 frames of panning content:

```
frame gen OFF:  submitted=30  presented=30  generated=0
frame gen ON:   submitted=30  presented=58  generated=28   (1.93x)
```

28 rather than 30 because the first two real frames establish history.

### Correctness

Counting frames proves nothing about whether they look right. Two frames of 32px
bars shifted by a known 16px:

```
edge in frame A = 32    edge in frame B = 48    true midpoint = 40
interpolated frame edge = 40      PASS (0px error)
```

Pixel-exact motion compensation, not a cross-fade.

### Two bugs this testing caught

**Deadlock.** Requesting the extra drawable inside `presentDrawable:` hangs forever:
the game still holds its own drawable there, and `CAMetalLayer`'s pool has nothing
left to give. The synthesised frame is now emitted from the `nextDrawable` hook,
in the window where the game holds none.

**Stack overflow.** Sending `-nextDrawable` to the layer from inside the
`nextDrawable` hook re-enters the swizzle and recurses until the process dies. The
original implementation has to be called directly, behind a re-entrancy guard.


## After porting AMD's optical flow structure (FidelityFX SDK v1.1.4)

| Pass | 3-step (mine) | Exhaustive (AMD structure) |
|---|---|---|
| Optical flow | 0.84 ms | 2.98 ms |
| Candidates searched | 25 | 289 |
| Block size | 5x5 | 8x8, overlapping every 4px |
| Midpoint error | 0px | 0px |

Frame generation totals 6.0 ms per frame (one luma pyramid, not the two the
benchmark builds). Still inside the 8.33 ms budget for 120 fps.

The cost is worth paying: an exhaustive search cannot land in a local minimum, which
is the failure mode that produces wrong vectors and visible warping on real content.
Emitting a vector every 4 pixels while matching over 8x8 blocks keeps field
resolution without shrinking the match window — a one-texel-per-8x8-block field
measured 2px of midpoint error, because sampling a coarser field smears motion
across edges.

## Latency

Frame generation was interpolating between two real frames. That has two problems.

**Ordering.** The synthesised frame was emitted after the newer real frame it was
built from, so the displayed sequence ran `A, B, interp(A,B), C` — forward, back,
forward.

**Latency.** Fixing the order the conventional way means holding the newer real frame
back until its midpoint has been shown: one full frame of added latency, ~16.7 ms at
60 fps.

Extrapolating forward from the two most recent frames fixes both. Nothing is held
back, so latency matches frame generation being off, and a projected frame belongs
after the newest real frame, which is where it was already being emitted.

| | Interpolate | Extrapolate |
|---|---|---|
| Added latency | 1 frame (~16.7 ms @ 60fps) | **0** |
| Pass cost | 2.44 ms | **1.70 ms** |
| Positional accuracy | 0px | 0px |
| Fails on | disocclusion | direction changes |

Per-frame total: luma 0.82 + flow 3.04 + extrapolate 1.70 = **5.56 ms**.

Sharpening at zero strength now returns immediately rather than performing a
full-resolution blit and a dispatch that changes nothing — about half a millisecond
at 4K.

### AMD Anti-Lag 2

`sdk/libs/antilag2/ffx_antilag2_dx12.h` resolves `AmdExtD3DCreateInterface` from AMD's
D3D12 driver DLL. It is a shim over an AMD GPU driver and has nothing behind it on
Apple silicon. Not portable, and not ported.

## Presentation-queue latency

GPU cost is not where the latency is. `CAMetalLayer` defaults to three drawables, so
a finished frame can sit unshown for up to two frame intervals — about 33 ms at
60 fps. That dwarfs the 5.6 ms the whole frame-generation pipeline costs.

Controls added: `maximumDrawableCount` (2 or 3), `displaySyncEnabled`, and
`presentsWithTransaction = NO`, which otherwise serialises the present with the
window server and adds a frame.

Verified: frame generation still produces 28 frames from 30 submitted with the pool
reduced to 2. The extra drawable the generated frame needs does not starve a 2-deep
pool, which was the risk.

### Not measured

`addPresentedHandler` never fires in the offscreen test host — the hook sees every
frame, but nothing composites to a display, so there are no presentation timestamps.
The instrumentation (`AnvilMeanLatencyMs`, `AnvilMaxLatencyMs`) is in place and will
report real figures under a real game, but **the size of the reduction from three
drawables to two is unverified here**. It rests on the documented behaviour of the
queue, not on a measurement taken in this repository.

## Frame pacing

A synthesised frame presented the moment it is ready lands right next to the real
frame it follows: two frames close together, then a long gap. The counter doubles
while the motion judders.

`presentDrawable:atTime:` schedules it for the midpoint of the measured real-frame
interval instead, handing the schedule to the compositor rather than stalling the
CPU — so pacing costs no latency. The interval is smoothed (0.9/0.1) so one long
frame does not swing where the next synthesised frame is placed.

Note that paced frames go out via `presentDrawable:atTime:`, which is a different
selector from the hooked `presentDrawable:`, so the hook's own counter sees only the
real frames. 30 real + 28 generated is still 58 presented.

## Memory budget

macOS grants no kernel-enforced per-process memory cap. Measured on macOS 26:

| Limit | Result |
|---|---|
| `RLIMIT_AS` | `EINVAL` |
| `RLIMIT_DATA` | `EINVAL` |
| `RLIMIT_RSS` | `EINVAL` |
| `RLIMIT_STACK` | works |
| `ulimit -v` | rejected by the shell |

`task_info(TASK_VM_INFO)` does give an exact `phys_footprint`, verified tracking a
300 MB allocation as 1.5 MB → 302.9 MB.

So a budget is honoured three ways rather than enforced:

1. **Reported downward**, so the game sizes its own pools to it. This is the only
   lever that shapes a game's appetite — being told a smaller number is what makes
   it ask for less.
2. **Anvil stays inside the remainder**, marking its frame history volatile when the
   footprint exceeds the budget so the kernel reclaims Anvil's memory rather than
   failing the game's.
3. **Measured continuously**, so an overrun is reported instead of silent.

A game that ignores what it is told will still exceed the figure. Anvil reports that
rather than pretending otherwise.

## Render scaling — where the frame rate actually comes from

I had assumed a present hook could not reduce a game's render resolution, because
the game chooses it. That was wrong. A game renders into whatever drawable the layer
hands it, so setting `CAMetalLayer.drawableSize` before `nextDrawable` makes it
render fewer pixels, with no support from the engine:

| Scale | Drawable | Pixels rendered |
|---|---|---|
| 1.0 | 256x256 | 100% |
| 0.667 | 170x170 | 44% |
| 0.5 | 128x128 | 25% |

Verified through the shipped bundle, and it composes with frame generation:
`rendered=170x170  presented=58  generated=28`.

### Why the final upscale is the compositor's and not EASU's

The better image would be EASU into a full-size drawable. That needs a second
drawable taken during `presentDrawable:`, and resizing the layer while the game
still holds its own drawable deadlocks — verified at both 2 and 3 drawables, so it
is not pool depth. CAMetalLayer performs the scale instead, and RCAS runs at the
reduced resolution beforehand to counter the softening, where it is also cheaper.

The frame-rate gain is unaffected: it comes entirely from the game rendering fewer
pixels, which has already happened by the time anything is presented.

## RCAS is now AMD's

`anvil_rcas` is a direct port of `FsrRcasF` from the FidelityFX SDK v1.1.4. The
hand-written version it replaces had no noise-detection term and cruder limiters, so
it over-sharpened grain and haloed on high-contrast edges. Same cost, 1.60 ms at 4K.

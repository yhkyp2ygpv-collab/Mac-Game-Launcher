# Third-party attribution

## AMD FidelityFX SDK

`anvil_optical_flow` in `Native/AnvilMetal/AnvilShaders.metal` is a Metal port of the
block-matching structure used by AMD's FidelityFX optical flow (v5), specifically its
use of a threadgroup-resident search window so that an exhaustive candidate search is
affordable. Ported from:

    sdk/include/FidelityFX/gpu/opticalflow/ffx_opticalflow_compute_optical_flow_v5.h
    FidelityFX SDK v1.1.4

`anvil_fsr_easu` and `anvil_fsr_easu_f32` are Metal ports of FSR 1's edge-adaptive spatial
upsampling (FsrEasuCon, FsrEasuSetF, FsrEasuTapF, FsrEasuF, and the same in 16-bit floats),
and `anvil_rcas` and the sharpening in `anvil_finish` of FSR 1's RCAS (FsrRcasF), from:

    sdk/include/FidelityFX/gpu/fsr1/ffx_fsr1.h
    FidelityFX SDK v1.1.4

Copyright (C) 2024 Advanced Micro Devices, Inc. Licensed under the MIT licence:

> Permission is hereby granted, free of charge, to any person obtaining a copy of this
> software and associated documentation files (the "Software"), to deal in the Software
> without restriction, including without limitation the rights to use, copy, modify,
> merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
> permit persons to whom the Software is furnished to do so, subject to the following
> conditions:
>
> The above copyright notice and this permission notice shall be included in all copies
> or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
> INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
> PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
> HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
> CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
> OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Anvil ships no AMD binaries. The port is source-level and the shaders are compiled
from Anvil's own `.metal` file.

### Not yet ported

`ffx_frameinterpolation_disocclusion_mask.h` and `ffx_frameinterpolation_inpainting.h`
address the case where motion reveals previously hidden geometry. Anvil currently falls
back to a cross-fade there. This is the largest remaining quality gap.

## Mythic

Mythic is licensed **GPL-3.0**. That matters here: copying Mythic source into Anvil
would make Anvil a derivative work and require Anvil to be released under GPL-3.0 as
well. So no Mythic code was copied, and Anvil is not a derivative work of it.

What Anvil took from reading Mythic is *facts* — where things live and which
mechanism a setting actually uses — none of which are copyrightable:

- Mythic keeps its engine at `~/Library/Application Support/Mythic/Engine`, with
  `wine/` and `DXVK/` inside it. Anvil had been looking under Mythic's bundle
  identifier, a path that does not exist, and so never found the engine at all.
- Retina mode and display scaling are registry values inside the prefix —
  `HKCU\Software\Wine\Mac Driver\RetinaMode` and
  `HKCU\Control Panel\Desktop\LogPixels` — not environment variables.
- D3DMetal's compiled-shader cache is at `$(getconf DARWIN_USER_CACHE_DIR)/d3dm`,
  one directory per executable. Mythic offers to purge it; Anvil preserves it
  instead, because macOS purging it on its own is what makes shader stutter return.
- The engine update catalogue is published at
  `https://dl.getmythic.app/engine/EngineUpdateStream.plist`.

Anvil reads that catalogue and installs into its own store. It never writes to a
Mythic installation: a Mythic install on the same Mac keeps the engine it has and
keeps updating it on its own schedule, and adopting a toolchain clones it rather
than moving it.

The engine itself is a Wine build (LGPL-2.1) packaged with Apple's D3DMetal from the
Game Porting Toolkit. Anvil runs it as a separate process and ships no copy of it.

## Verification of environment variables

Every `D3DM_*` variable Anvil sets was read out of the D3DMetal binary in the
selected runtime with `strings`, and every `WINE*` variable out of the Wine tree.
Nine variables that earlier builds set — `WINE_HEAP_LIMIT_MB`,
`WINE_REPORTED_MEMORY_MB`, `D3DM_VRAM_MB`, `WINE_VK_VRAM_MB`, `WINE_CPU_TOPOLOGY`,
`WINE_PRESENT_MODE`, `D3DM_TRIPLE_BUFFER`, `D3DM_SHADER_CACHE_SIZE_MB` and
`DXMT_METALFX_SPATIAL` — appear in neither, and have been removed along with the UI
controls that set them.

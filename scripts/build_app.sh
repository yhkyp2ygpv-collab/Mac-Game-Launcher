#!/bin/bash
# Assemble Anvil.app from the SwiftPM build product.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
if [ -n "${ANVIL_PREBUILT_BINARY:-}" ]; then
  # A binary compiled some other way — swiftc directly, where SwiftPM cannot run (it
  # saves its build files through the system temp folder, which a sandbox may forbid).
  BIN="$ANVIL_PREBUILT_BINARY"
else
  swift build -c "$CONFIG" --arch arm64
  BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/Anvil"
fi

# ANVIL_EDITION: "private" (the default — Jay's own copy) or "public" (the one in the
# .dmg: stripped, no source inside, signed strictly). scripts/build_editions.sh sets both
# of these; on its own this script builds the private edition where it always has.
EDITION="${ANVIL_EDITION:-private}"
APP="${ANVIL_APP_PATH:-build/Anvil.app}"
rm -rf "$APP"
mkdir -p "$(dirname "$APP")"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Anvil"

# Anvil's own Metal pipeline: shaders and the injectable interceptor.
#
# Xcode 27 stopped shipping the Metal toolchain; it is a separate download now. This
# script runs under `set -e`, so a missing `metal` compiler used to abort the whole
# build — not just the shaders — and no app was produced at all. Now:
#   1. with the toolchain, the shaders are precompiled as before;
#   2. without it, a library precompiled earlier from byte-identical source is reused;
#   3. and the source always ships too, because the interceptor can compile it at
#      runtime — so the frame pipeline works even when neither of the above does.
SHADER_SRC=Native/AnvilMetal/AnvilShaders.metal
SHADER_HASH="$(shasum -a 256 "$SHADER_SRC" | cut -c1-16)"
SHADER_CACHE="build/.shader-cache/$SHADER_HASH.metallib"
cp "$SHADER_SRC" "$APP/Contents/Resources/AnvilShaders.metal"

echo "Compiling Metal shaders..."
if xcrun -sdk macosx metal -O3 -c "$SHADER_SRC" -o "$APP/Contents/Resources/AnvilShaders.air" 2>/dev/null \
   && xcrun -sdk macosx metallib "$APP/Contents/Resources/AnvilShaders.air" \
        -o "$APP/Contents/Resources/AnvilShaders.metallib" 2>/dev/null; then
  mkdir -p build/.shader-cache
  cp "$APP/Contents/Resources/AnvilShaders.metallib" "$SHADER_CACHE"
elif [ -f "$SHADER_CACHE" ]; then
  echo "  Metal toolchain not installed — reusing the library built from this exact source."
  cp "$SHADER_CACHE" "$APP/Contents/Resources/AnvilShaders.metallib"
else
  echo "  Metal toolchain not installed and no cached library for this source."
  echo "  Shipping source only; it compiles at first launch (~a fraction of a second)."
  echo "  To precompile again:  xcodebuild -downloadComponent MetalToolchain"
fi
rm -f "$APP/Contents/Resources/AnvilShaders.air"
# The public edition ships no readable source: the compiled library when there is one,
# else the source packed (compressed and scrambled), which the interceptor unpacks and
# compiles at the game's first frame.
if [ "$EDITION" = public ]; then
  if [ ! -f "$APP/Contents/Resources/AnvilShaders.metallib" ]; then
    PACKER="${TMPDIR:-/tmp}/anvil-shader-pack"
    clang -O2 -o "$PACKER" Native/Tools/shader_pack.c -lcompression
    "$PACKER" "$SHADER_SRC" "$APP/Contents/Resources/AnvilShaders.pack"
    echo "  Shaders packed for the public edition (no readable source inside)."
  fi
  rm -f "$APP/Contents/Resources/AnvilShaders.metal"
fi

echo "Compiling frame interceptor..."
# Universal. wine64 is an x86_64 binary running under Rosetta, so an arm64-only
# dylib cannot be inserted into it — and dyld does not skip a dylib it cannot load,
# it terminates the process. An arm64-only build killed every game at launch.
clang++ -std=c++17 -ObjC++ -dynamiclib -O2 -arch arm64 -arch x86_64 \
  -framework Foundation -framework QuartzCore -framework Metal -framework MetalFX -framework CoreGraphics -framework IOKit -framework IOSurface \
  -framework AudioToolbox -framework CoreAudio -framework ImageIO -framework Accelerate -lcompression \
  -o "$APP/Contents/Resources/libanvil.dylib" \
  Native/AnvilMetal/anvil_inject.mm Native/AnvilMetal/anvil_input.mm \
  Native/AnvilMetal/anvil_wineserver.mm Native/AnvilMetal/anvil_stall.mm \
  Native/AnvilMetal/anvil_display.mm Native/AnvilMetal/anvil_switchpro.mm \
  Native/AnvilMetal/anvil_audio.mm Native/AnvilMetal/anvil_window.mm Native/AnvilMetal/anvil_net.mm Native/AnvilMetal/anvil_guard.mm Native/AnvilMetal/anvil_gpuwork.mm Native/AnvilMetal/anvil_shaderset.mm Native/AnvilMetal/anvil_pack.cpp \
  Native/AnvilMetal/anvil_screens.mm Native/AnvilMetal/anvil_guardian.mm Native/AnvilMetal/anvil_io.mm

# Graphics Prep's helper: compiles Anvil's shaders into an archive for the Mac's GPU and tests
# FSR and FSR 3 on it, in a process of its own (see GraphicsPrep). Universal: the archive is
# checked under Rosetta, as the game runs, as well as natively. Shares the shader code with
# libanvil. ImageIO only writes the test's pictures when asked (ANVIL_PREP_DUMP).
clang++ -std=c++17 -ObjC++ -O2 -arch arm64 -arch x86_64 \
  -framework Foundation -framework Metal -framework QuartzCore -framework ImageIO -framework CoreGraphics -lcompression \
  -o "$APP/Contents/Resources/anvil-prep" \
  Native/Tools/anvil_prep.mm Native/AnvilMetal/anvil_shaderset.mm Native/AnvilMetal/anvil_pack.cpp

# The sound check: runs libanvil's own game audio (anvil_audio.mm, Anvil Surround) against an
# output — a silent scan of what it can do for surround, or a test played through it. Driven
# from the 3D Surround Sound panel (Core/SoundCheck).
clang++ -std=c++17 -ObjC++ -O2 -arch arm64 -DANVIL_AUDIO_TEST \
  -framework Foundation -framework AudioToolbox -framework CoreAudio -framework Accelerate \
  -o "$APP/Contents/Resources/anvil-soundcheck" \
  Native/Tools/anvil_soundcheck.mm

# The controller tester: loads the engine's own libSDL2 (x86_64, so this is too) and
# reports what a game will see. Driven from the Controllers screen.
clang -arch x86_64 -O1 -o "$APP/Contents/Resources/anvil-sdl-probe" Native/Tools/sdl_probe.c

# SDL_GameControllerDB (zlib licence, kept beside it): button mappings for pads the
# engine's SDL predates. Read by SDLControllerDB.communityMapping.
cp Resources/gamecontrollerdb.txt Resources/gamecontrollerdb-LICENSE.txt "$APP/Contents/Resources/"

# Minecraft's PC version in a Windows virtual machine (MinecraftPC): the setup that runs inside
# Windows, put in the folder shared with it. Plain text: Windows reads it as it is.
mkdir -p "$APP/Contents/Resources/MinecraftPC"
cp Resources/MinecraftPC/"Set up Minecraft.cmd" Resources/MinecraftPC/anvil-minecraft-setup.ps1 \
   Resources/MinecraftPC/"Read me.txt" "$APP/Contents/Resources/MinecraftPC/"

# App icon: .icns for Finder, plus both PNGs so the Dock icon can follow the theme.
# Regenerate with: swift Resources/GenerateIcons.swift <output-dir>
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/AnvilIconLight.png Resources/AnvilIconDark.png "$APP/Contents/Resources/"

# Who made Anvil. Checked against a digest compiled into Anvil at every start: a copy
# without it, or with it changed, doesn't start (see AppProtection).
cp Resources/Ownership.txt "$APP/Contents/Resources/Ownership.txt"

# Licences: Anvil's own, and the third-party notices its code and data require.
mkdir -p "$APP/Contents/Resources/Legal"
cp LICENSE.txt "$APP/Contents/Resources/Legal/License.txt"
cp THIRD-PARTY.md "$APP/Contents/Resources/Legal/Third-Party Notices.md"
cp Resources/gamecontrollerdb-LICENSE.txt "$APP/Contents/Resources/Legal/"

VERSION="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/Anvil/Core/Version.swift | head -1)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Anvil</string>
  <key>CFBundleDisplayName</key><string>Anvil</string>
  <key>CFBundleIdentifier</key><string>dev.anvil.launcher</string>
  <key>CFBundleExecutable</key><string>Anvil</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Jay Chirag Patel, Santa Clara, California. Anvil Source License.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <!-- anvil://play/<game id>: what the shortcut apps in Applications › Anvil Games open. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>dev.anvil.launcher</string>
      <key>CFBundleURLSchemes</key><array><string>anvil</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

if [ "$EDITION" = public ]; then
  # Symbols out: smaller, and nothing of the source's names left to read. Local symbols
  # only for the libraries — their exported names are how they hook into Wine.
  strip -S -x "$APP/Contents/MacOS/Anvil"
  strip -S -x "$APP/Contents/Resources/libanvil.dylib"
  strip -S -x "$APP/Contents/Resources/anvil-sdl-probe"
  strip -S -x "$APP/Contents/Resources/anvil-prep"
  strip -S -x "$APP/Contents/Resources/anvil-soundcheck"
  # Signed strictly, with the hardened runtime and Anvil's entitlements, so the copy is
  # closed while it runs as well as on disk: no debugger can attach to it, and no library
  # it wasn't built with can be loaded into it (see Resources/Anvil.entitlements). The
  # public edition checks this same signature at every start, so an unsigned or changed
  # copy refuses to run. ANVIL_SIGN_IDENTITY is a Developer ID ("Developer ID Application:
  # Name (TEAMID)"); without one the signature is ad hoc — the hardened runtime is enforced
  # by the kernel just the same, the Developer ID only also lets other Macs verify the maker.
  ENTITLEMENTS="Resources/Anvil.entitlements"
  if [ -n "${ANVIL_SIGN_IDENTITY:-}" ]; then
    codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$ANVIL_SIGN_IDENTITY" "$APP"
  else
    codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP"
  fi
  codesign --verify --deep --strict "$APP"
else
  # Ad-hoc signature: enough for local use, and keeps the JIT/allow-unsigned
  # entitlements story simple while the project is unsigned.
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "Built $APP ($EDITION edition)"

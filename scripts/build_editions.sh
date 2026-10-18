#!/bin/bash
# Anvil's two editions, from the same source:
#
#   private — build/Anvil.app
#             Jay's own copy. Debug symbols kept, no self-check, rebuild and change freely.
#   public  — build/public/Anvil.app, packed into build/Anvil-<version>.dmg to send to people.
#             Optimised, symbols stripped, no source inside, and signed with the hardened
#             runtime and Anvil's entitlements, so it is closed while it runs as well as on
#             disk: no debugger can attach to it and no foreign library can be loaded into
#             it (Resources/Anvil.entitlements). It also checks its own signature at every
#             start: if any file inside it was changed, removed or added, it says so and
#             doesn't start. Nothing is ever deleted by that check.
#
# Usage:  scripts/build_editions.sh [private|public|both]     (default: both)
#
# Optional, for the public edition:
#   ANVIL_SIGN_IDENTITY="Developer ID Application: Jay Chirag Patel (TEAMID)"
#       Signs with an Apple Developer ID (Apple Developer Program). The self-check is then
#       pinned to that team, so a copy re-signed by anyone else refuses to start too.
#   ANVIL_NOTARY_PROFILE=<profile saved with `xcrun notarytool store-credentials`>
#       Also notarizes and staples the .dmg, so it opens on other Macs without a warning.
set -euo pipefail
cd "$(dirname "$0")/.."

WHICH="${1:-both}"
SDK="$(xcrun --show-sdk-path)"
VERSION="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/Anvil/Core/Version.swift | head -1)"
WORK="${TMPDIR:-/tmp}/anvil-editions"
mkdir -p "$WORK/mc"

TEAM=""
if [ -n "${ANVIL_SIGN_IDENTITY:-}" ]; then
  TEAM="$(sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p' <<<"$ANVIL_SIGN_IDENTITY")"
fi

# Put a freshly built app in place in one step. Building straight into build/Anvil.app
# left it without its libraries for the 15 seconds the interceptor takes to compile —
# and the running copy of Anvil starts games from that bundle.
swap_in() {
  local built="$1" dest="$2"
  rm -rf "$dest.old"
  if [ -e "$dest" ]; then mv "$dest" "$dest.old"; fi
  mv "$built" "$dest"
  rm -rf "$dest.old"
}

# Compile one edition. BuildInfo.swift is swapped for a generated copy saying which.
compile() {
  local edition="$1" out="$2" debug="$3"
  local gen="$WORK/$edition"
  mkdir -p "$gen"
  local team="nil"
  if [ "$edition" = public ] && [ -n "$TEAM" ]; then team="\"$TEAM\""; fi
  cat > "$gen/BuildInfo.swift" <<SWIFT
enum BuildInfo {
    static let edition = "$edition"
    static let signingTeam: String? = $team
}
SWIFT
  local sources=()
  while IFS= read -r f; do sources+=("$PWD/$f"); done < <(find Sources/Anvil -name '*.swift' ! -name BuildInfo.swift | sort)
  echo "Compiling the $edition edition…"
  # From the edition's own work folder, so the module files a debug build writes beside
  # it stay out of the source tree.
  (cd "$gen" && swiftc -O -wmo $debug -parse-as-library -disable-sandbox \
    -sdk "$SDK" -target arm64-apple-macosx14.0 -module-cache-path "$WORK/mc" -module-name Anvil \
    -o "$out" "${sources[@]}" "$gen/BuildInfo.swift")
}

if [ "$WHICH" = private ] || [ "$WHICH" = both ]; then
  compile private "$WORK/Anvil-private" "-g"
  ANVIL_EDITION=private ANVIL_APP_PATH=build/.building-private/Anvil.app ANVIL_PREBUILT_BINARY="$WORK/Anvil-private" \
    CLANG_MODULE_CACHE_PATH="$WORK/mc" bash scripts/build_app.sh
  swap_in build/.building-private/Anvil.app build/Anvil.app
  rm -rf build/.building-private
fi

if [ "$WHICH" = public ] || [ "$WHICH" = both ]; then
  compile public "$WORK/Anvil-public" ""
  if [ ! -f "build/.shader-cache/$(shasum -a 256 Native/AnvilMetal/AnvilShaders.metal | cut -c1-16).metallib" ] \
     && ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    echo "Note: the Metal toolchain isn't installed, so the public edition's shaders are packed rather than"
    echo "      precompiled — they compile in a fraction of a second at a game's first frame. To precompile:"
    echo "      xcodebuild -downloadComponent MetalToolchain   — then build again."
  fi
  mkdir -p build/public
  ANVIL_EDITION=public ANVIL_APP_PATH=build/.building-public/Anvil.app ANVIL_PREBUILT_BINARY="$WORK/Anvil-public" \
    CLANG_MODULE_CACHE_PATH="$WORK/mc" bash scripts/build_app.sh
  swap_in build/.building-public/Anvil.app build/public/Anvil.app
  rm -rf build/.building-public

  # The .dmg: Anvil, a link to Applications to drag it onto, the licence and a read-me.
  STAGE="$WORK/dmg"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  ditto build/public/Anvil.app "$STAGE/Anvil.app"
  ln -s /Applications "$STAGE/Applications"
  cp LICENSE.txt "$STAGE/License.txt"
  cp "Resources/Read Me First.txt" "$STAGE/Read Me First.txt"
  DMG="build/Anvil-$VERSION.dmg"
  rm -f "$DMG"
  if ! hdiutil create -volname "Anvil $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null 2>&1; then
    # Where disk images can't be attached (a sandbox, some CI): built without attaching.
    rm -f "$WORK/hybrid.dmg" "$DMG"
    hdiutil makehybrid -hfs -hfs-volume-name "Anvil $VERSION" -o "$WORK/hybrid.dmg" "$STAGE" >/dev/null
    hdiutil convert "$WORK/hybrid.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null 2>&1
    rm -f "$WORK/hybrid.dmg"
  fi
  hdiutil verify "$DMG" >/dev/null 2>&1 && echo "Disk image checksum verified."
  # The staging copy goes: a second Anvil.app left in a temporary folder is one macOS can
  # pick to open anvil:// links with (9 October).
  rm -rf "$STAGE"
  if [ -n "${ANVIL_SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$ANVIL_SIGN_IDENTITY" "$DMG"
    if [ -n "${ANVIL_NOTARY_PROFILE:-}" ]; then
      xcrun notarytool submit "$DMG" --keychain-profile "$ANVIL_NOTARY_PROFILE" --wait
      xcrun stapler staple "$DMG"
    fi
  fi
  shasum -a 256 "$DMG" | tee "$DMG.sha256"
  echo "Built $DMG"
fi

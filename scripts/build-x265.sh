#!/usr/bin/env bash
#
# Cross-compile libx265 (default v4.2 — the release with the improved NEON/SVE
# kernels) as a static library for iOS, and package it as an XCFramework.
#
# Produces: Frameworks/x265.xcframework  (iphoneos arm64 + iphonesimulator arm64)
#
set -euo pipefail

X265_TAG="${X265_TAG:-4.2}"
X265_REPO="${X265_REPO:-https://bitbucket.org/multicoreware/x265_git.git}"
DEPLOY="${IOS_DEPLOY_TARGET:-16.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD="$ROOT/build"
SRC="$BUILD/x265-src"
DIST="$BUILD/x265-dist"
OUT="$ROOT/Frameworks/x265.xcframework"

mkdir -p "$BUILD"

# --- fetch source -----------------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
  echo ">>> Cloning x265 $X265_TAG"
  git clone --depth 1 --branch "$X265_TAG" "$X265_REPO" "$SRC"
else
  echo ">>> Reusing x265 source at $SRC"
fi

# --- build one platform slice ----------------------------------------------
# $1 = sdk (iphoneos|iphonesimulator)
#
# Multilib build: x265 supports only one internal bit depth per library, so to
# encode both 8-bit (SDR) and 10-bit (HDR, e.g. HLG/PQ) we build three static
# libs — 8/10/12-bit — and merge them into one libx265.a. The 10/12-bit libs are
# built with EXPORT_C_API=OFF (their API symbols are namespaced), and the 8-bit
# "main" lib is linked against them with LINKED_10BIT/LINKED_12BIT so a single
# x265_api_get(depth) dispatches to the right encoder. This is x265's own
# multilib recipe, adapted to the iOS cross-compile flags below.
build_slice() {
  local sdk="$1"
  local sysroot
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

  local d8="$BUILD/x265-$sdk-8bit"
  local d10="$BUILD/x265-$sdk-10bit"
  local d12="$BUILD/x265-$sdk-12bit"

  # Flags shared by all three depth builds.
  # CMAKE_POLICY_VERSION_MINIMUM keeps x265's old cmake_minimum_required happy
  # under CMake >= 4. SVE/SVE2 are disabled: Apple cores don't implement SVE and
  # some toolchains choke assembling those kernels; NEON (the point of 4.2) stays on.
  #
  # ASM_FLAGS injection: x265's ARM64 hand-written .S build rule invokes the C++
  # compiler WITHOUT -arch/-isysroot (only its 32-bit ARM path adds them), so the
  # assembler defaults to the host (x86-64) target and rejects -march=armv8-a.
  # ASM_FLAGS is one of the few vars those custom commands pass through, and it's
  # list(APPEND)-ed rather than overwritten, so seeding it here fixes the target.
  local common=(
    -DCMAKE_SYSTEM_NAME=iOS
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_SYSROOT="$sysroot"
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY"
    -DCMAKE_SYSTEM_PROCESSOR=aarch64
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    "-DASM_FLAGS=-arch;arm64;-isysroot;$sysroot"
    -DENABLE_SHARED=OFF
    -DENABLE_CLI=OFF
    -DENABLE_ASSEMBLY=ON
    -DENABLE_PIC=ON
    -DENABLE_SVE=OFF
    -DENABLE_SVE2=OFF
    -DCMAKE_BUILD_TYPE=Release
  )
  local jobs; jobs="$(sysctl -n hw.ncpu)"

  echo ">>> [$sdk] Building x265 12-bit"
  cmake -S "$SRC/source" -B "$d12" "${common[@]}" \
    -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DENABLE_HDR10_PLUS=ON -DMAIN12=ON
  cmake --build "$d12" --target x265-static -j"$jobs"

  echo ">>> [$sdk] Building x265 10-bit"
  cmake -S "$SRC/source" -B "$d10" "${common[@]}" \
    -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DENABLE_HDR10_PLUS=ON
  cmake --build "$d10" --target x265-static -j"$jobs"

  echo ">>> [$sdk] Building x265 8-bit (main, linked against 10/12-bit)"
  cmake -S "$SRC/source" -B "$d8" "${common[@]}" \
    -DHIGH_BIT_DEPTH=OFF -DENABLE_HDR10_PLUS=ON \
    -DLINKED_10BIT=ON -DLINKED_12BIT=ON \
    "-DEXTRA_LIB=$d10/libx265.a;$d12/libx265.a" \
    "-DEXTRA_LINK_FLAGS=-L$d10;-L$d12"
  cmake --build "$d8" --target x265-static -j"$jobs"

  # Merge the three archives into one libx265.a (symbols are namespaced per
  # depth, so there's no clash — same recipe as x265's multilib.sh on macOS).
  echo ">>> [$sdk] Merging 8/10/12-bit into one libx265.a"
  mv "$d8/libx265.a" "$d8/libx265_main.a"
  libtool -static -o "$d8/libx265.a" \
    "$d8/libx265_main.a" "$d10/libx265.a" "$d12/libx265.a"

  mkdir -p "$DIST/$sdk/lib" "$DIST/$sdk/include"
  cp "$d8/libx265.a" "$DIST/$sdk/lib/libx265.a"
  cp "$SRC/source/x265.h" "$DIST/$sdk/include/x265.h"
  cp "$d8/x265_config.h" "$DIST/$sdk/include/x265_config.h"
}

build_slice iphoneos
build_slice iphonesimulator

# --- assemble xcframework ---------------------------------------------------
echo ">>> Creating $OUT"
rm -rf "$OUT"
mkdir -p "$ROOT/Frameworks"
xcodebuild -create-xcframework \
  -library "$DIST/iphoneos/lib/libx265.a"        -headers "$DIST/iphoneos/include" \
  -library "$DIST/iphonesimulator/lib/libx265.a" -headers "$DIST/iphonesimulator/include" \
  -output "$OUT"

echo ">>> Done: $OUT"
strings "$DIST/iphoneos/lib/libx265.a" | grep -m1 "x265 [0-9]" || true

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
build_slice() {
  local sdk="$1"
  local bdir="$BUILD/x265-$sdk"
  local sysroot
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

  echo ">>> Configuring x265 for $sdk (sysroot=$sysroot)"
  # CMAKE_POLICY_VERSION_MINIMUM keeps x265's old cmake_minimum_required happy
  # under CMake >= 4. SVE/SVE2 are disabled: Apple cores don't implement SVE and
  # some toolchains choke assembling those kernels; NEON (the point of 4.2) stays on.
  #
  # ASM_FLAGS injection: x265's ARM64 hand-written .S build rule invokes the C++
  # compiler WITHOUT -arch/-isysroot (only its 32-bit ARM path adds them), so the
  # assembler defaults to the host (x86-64) target and rejects -march=armv8-a.
  # ASM_FLAGS is one of the few vars those custom commands pass through, and it's
  # list(APPEND)-ed rather than overwritten, so seeding it here fixes the target.
  cmake -S "$SRC/source" -B "$bdir" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY" \
    -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    "-DASM_FLAGS=-arch;arm64;-isysroot;$sysroot" \
    -DENABLE_SHARED=OFF \
    -DENABLE_CLI=OFF \
    -DENABLE_ASSEMBLY=ON \
    -DENABLE_PIC=ON \
    -DENABLE_SVE=OFF \
    -DENABLE_SVE2=OFF \
    -DHIGH_BIT_DEPTH=OFF \
    -DCMAKE_BUILD_TYPE=Release

  echo ">>> Building x265 for $sdk"
  cmake --build "$bdir" --target x265-static -j"$(sysctl -n hw.ncpu)"

  mkdir -p "$DIST/$sdk/lib" "$DIST/$sdk/include"
  cp "$bdir/libx265.a" "$DIST/$sdk/lib/libx265.a"
  cp "$SRC/source/x265.h" "$DIST/$sdk/include/x265.h"
  cp "$bdir/x265_config.h" "$DIST/$sdk/include/x265_config.h"
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

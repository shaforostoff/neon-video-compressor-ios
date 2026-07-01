#!/usr/bin/env bash
#
# Cross-compile a *minimal* FFmpeg (static) for iOS, linked against the libx265
# built by build-x265.sh, with Apple AudioToolbox (aac_at / HE-AAC) enabled.
#
# Produces: Frameworks/FFmpeg.xcframework
#   (merged libavformat/avcodec/avutil/swscale/swresample, iphoneos + simulator)
#
# Run build-x265.sh first.
#
set -euo pipefail

FFMPEG_TAG="${FFMPEG_TAG:-n7.1}"
FFMPEG_REPO="${FFMPEG_REPO:-https://github.com/FFmpeg/FFmpeg.git}"
DEPLOY="${IOS_DEPLOY_TARGET:-16.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD="$ROOT/build"
SRC="$BUILD/ffmpeg-src"
DIST="$BUILD/ffmpeg-dist"
X265_DIST="$BUILD/x265-dist"
OUT="$ROOT/Frameworks/FFmpeg.xcframework"

mkdir -p "$BUILD"

if [ ! -d "$X265_DIST/iphoneos/lib/libx265.a" ] && [ ! -f "$X265_DIST/iphoneos/lib/libx265.a" ]; then
  echo "!!! x265 not built yet — run scripts/build-x265.sh first" >&2
  exit 1
fi

if [ ! -d "$SRC/.git" ]; then
  echo ">>> Cloning FFmpeg $FFMPEG_TAG"
  git clone --depth 1 --branch "$FFMPEG_TAG" "$FFMPEG_REPO" "$SRC"
else
  echo ">>> Reusing FFmpeg source at $SRC"
fi

# Apply patches idempotently (reverse-check detects an already-applied patch, so
# re-runs against a reused checkout stay safe).
apply_patch() {
  local dir="$1" patch="$2"
  if git -C "$dir" apply --reverse --check "$patch" 2>/dev/null; then
    echo ">>> Patch already applied: $(basename "$patch")"
  elif git -C "$dir" apply --check "$patch" 2>/dev/null; then
    git -C "$dir" apply "$patch"
    echo ">>> Applied patch: $(basename "$patch")"
  else
    echo "!!! Patch does not apply cleanly: $(basename "$patch")" >&2
    exit 1
  fi
}

# For X265_BUILD >= 210, libx265.c uses x265's scalable multi-layer output API,
# whose per-layer picture pointers x265 4.2 (build 216) does not populate in this
# build — the returned NAL comes back with a null payload and libx265_encode_frame
# memcpy's from it, crashing on the first emitted frame (~after the lookahead
# fills). This patch forces the legacy single-picture output path.
apply_patch "$SRC" "$SCRIPT_DIR/patches/ffmpeg-n7.1-libx265-single-picture.patch"

# Components — just enough to demux/decode phone recordings (mov/mp4, h264/hevc,
# aac/ac3/mp3/pcm) and mux HEVC + AAC back into mp4.
ENABLES=(
  --enable-demuxer=mov
  --enable-muxer=mov,mp4
  --enable-protocol=file
  --enable-decoder=hevc,h264,aac,ac3,eac3,mp3,pcm_s16le,pcm_s16be,pcm_u8,pcm_f32le
  --enable-encoder=libx265,aac,aac_at
  --enable-parser=hevc,h264,aac,ac3
  --enable-bsf=hevc_mp4toannexb,h264_mp4toannexb,aac_adtstoasc,extract_extradata
)

build_slice() {
  local sdk="$1" sim_suffix="$2"
  local bdir="$BUILD/ffmpeg-$sdk"
  local prefix="$DIST/$sdk"
  local sysroot
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

  local x265inc="$X265_DIST/$sdk/include"
  local x265lib="$X265_DIST/$sdk/lib"

  local tflags="-target arm64-apple-ios${DEPLOY}${sim_suffix} -isysroot $sysroot -arch arm64"

  echo ">>> Configuring FFmpeg for $sdk"
  rm -rf "$bdir" "$prefix"; mkdir -p "$bdir" "$prefix"

  # x265 ships no .pc when built in-tree without install; synthesize one so
  # FFmpeg's require_pkg_config(libx265) check passes. --static pulls -lc++.
  # (Created AFTER the rm above, or it would be wiped before configure runs.)
  local pcdir="$bdir/pkgconfig"
  mkdir -p "$pcdir"
  cat > "$pcdir/x265.pc" <<EOF
prefix=$X265_DIST/$sdk
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: x265
Description: H.265/HEVC encoder
Version: ${X265_TAG:-4.2}
Libs: -L\${libdir} -lx265
Libs.private: -lc++
Cflags: -I\${includedir}
EOF
  (
    cd "$bdir"
    PKG_CONFIG_PATH="$pcdir" PKG_CONFIG_LIBDIR="$pcdir" \
    "$SRC/configure" \
      --prefix="$prefix" \
      --enable-cross-compile --target-os=darwin --arch=aarch64 \
      --cc=clang --cxx=clang++ --ar=ar --ranlib=ranlib --strip=strip \
      --sysroot="$sysroot" \
      --extra-cflags="$tflags -fno-stack-check -I$x265inc" \
      --extra-ldflags="$tflags -L$x265lib" \
      --extra-cxxflags="$tflags" \
      --extra-libs="-lc++" \
      --pkg-config=pkg-config --pkg-config-flags=--static \
      --enable-pic --disable-shared --enable-static \
      --disable-autodetect \
      --disable-programs --disable-doc --disable-debug \
      --disable-avdevice --disable-avfilter --disable-postproc \
      --disable-everything \
      --enable-gpl --enable-version3 \
      --enable-libx265 --enable-audiotoolbox --enable-videotoolbox \
      "${ENABLES[@]}"
  )

  echo ">>> Building FFmpeg for $sdk"
  make -C "$bdir" -j"$(sysctl -n hw.ncpu)"
  make -C "$bdir" install

  echo ">>> Merging static libs for $sdk"
  libtool -static -o "$prefix/libffmpeg.a" \
    "$prefix"/lib/libavformat.a \
    "$prefix"/lib/libavcodec.a \
    "$prefix"/lib/libavutil.a \
    "$prefix"/lib/libswscale.a \
    "$prefix"/lib/libswresample.a
}

build_slice iphoneos ""
build_slice iphonesimulator "-simulator"

echo ">>> Creating $OUT"
rm -rf "$OUT"
mkdir -p "$ROOT/Frameworks"
xcodebuild -create-xcframework \
  -library "$DIST/iphoneos/libffmpeg.a"        -headers "$DIST/iphoneos/include" \
  -library "$DIST/iphonesimulator/libffmpeg.a" -headers "$DIST/iphonesimulator/include" \
  -output "$OUT"

echo ">>> Done: $OUT"

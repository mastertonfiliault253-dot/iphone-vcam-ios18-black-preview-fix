#!/usr/bin/env bash
set -euo pipefail

FFMPEG_VERSION="7.1.1"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_ROOT="$PROJECT_ROOT/vendor/ffmpeg"
WORK_ROOT="${RUNNER_TEMP:-/tmp}/vcam-ffmpeg-$FFMPEG_VERSION"

if [[ -f "$OUTPUT_ROOT/lib/libavformat.a" && -f "$OUTPUT_ROOT/include/libavformat/avformat.h" ]]; then
  echo "Using cached iOS FFmpeg $FFMPEG_VERSION"
  exit 0
fi

rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT" "$OUTPUT_ROOT/lib" "$OUTPUT_ROOT/include"
curl -L --fail \
  --retry 8 \
  --retry-delay 3 \
  --retry-all-errors \
  --connect-timeout 20 \
  --max-time 600 \
  "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
  -o "$WORK_ROOT/ffmpeg.tar.xz"
tar -xf "$WORK_ROOT/ffmpeg.tar.xz" -C "$WORK_ROOT"
SOURCE_ROOT="$WORK_ROOT/ffmpeg-${FFMPEG_VERSION}"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"

build_slice() {
  local architecture="$1"
  local target="$2"
  local build_root="$WORK_ROOT/build-$architecture"
  local prefix="$WORK_ROOT/install-$architecture"
  mkdir -p "$build_root"
  pushd "$build_root" >/dev/null
  "$SOURCE_ROOT/configure" \
    --prefix="$prefix" \
    --target-os=darwin \
    --arch=arm64 \
    --enable-cross-compile \
    --cc="xcrun --sdk iphoneos clang" \
    --cxx="xcrun --sdk iphoneos clang++" \
    --ar="xcrun --sdk iphoneos ar" \
    --ranlib="xcrun --sdk iphoneos ranlib" \
    --sysroot="$SDK_PATH" \
    --extra-cflags="-target $target -fembed-bitcode -O3" \
    --extra-ldflags="-target $target" \
    --disable-shared \
    --enable-static \
    --disable-programs \
    --disable-doc \
    --disable-debug \
    --disable-avdevice \
    --disable-avfilter \
    --disable-postproc \
    --disable-swresample \
    --disable-swscale \
    --disable-everything \
    --enable-avformat \
    --enable-avcodec \
    --enable-avutil \
    --enable-network \
    --enable-protocol=file,tcp,udp \
    --enable-demuxer=mov,rtsp,rtp,sdp \
    --enable-decoder=h264,hevc \
    --enable-parser=h264,hevc \
    --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox \
    --enable-videotoolbox \
    --disable-bzlib \
    --disable-iconv \
    --disable-lzma \
    --disable-zlib
  make -j"$(sysctl -n hw.logicalcpu)"
  make install
  popd >/dev/null
}

build_slice arm64 arm64-apple-ios15.0

cp -R "$WORK_ROOT/install-arm64/include/." "$OUTPUT_ROOT/include/"
for library in avformat avcodec avutil; do
  cp "$WORK_ROOT/install-arm64/lib/lib${library}.a" \
    "$OUTPUT_ROOT/lib/lib${library}.a"
done
cp "$SOURCE_ROOT/COPYING.LGPLv2.1" "$OUTPUT_ROOT/COPYING.LGPLv2.1"
echo "Built arm64 FFmpeg $FFMPEG_VERSION for the arm64-only vcamd worker"

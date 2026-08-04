#!/usr/bin/env bash
set -euo pipefail

FFMPEG_VERSION="7.1.1"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_ROOT="$PROJECT_ROOT/vendor/ffmpeg"
WORK_ROOT="${RUNNER_TEMP:-/tmp}/vcam-ffmpeg-linux-$FFMPEG_VERSION"
THEOS_ROOT="${THEOS:-/opt/theos}"
SDK_PATH="${VCAM_IOS_SDK:-$THEOS_ROOT/sdks/iPhoneOS16.5.sdk}"
TOOLCHAIN_BIN="${VCAM_IOS_TOOLCHAIN_BIN:-$THEOS_ROOT/toolchain/linux/iphone/bin}"

if [[ -f "$OUTPUT_ROOT/lib/libavformat.a" && -f "$OUTPUT_ROOT/include/libavformat/avformat.h" ]]; then
  echo "Using cached iOS FFmpeg $FFMPEG_VERSION"
  exit 0
fi

for required in clang clang++ ar ranlib lipo; do
  if [[ ! -x "$TOOLCHAIN_BIN/$required" ]]; then
    echo "Missing iOS toolchain executable: $TOOLCHAIN_BIN/$required" >&2
    exit 1
  fi
done
if [[ ! -d "$SDK_PATH/System/Library/Frameworks" ]]; then
  echo "Invalid iOS SDK path: $SDK_PATH" >&2
  exit 1
fi

case "$WORK_ROOT" in
  /tmp/vcam-ffmpeg-linux-*|*/vcam-ffmpeg-linux-*) ;;
  *)
    echo "Refusing to clean unexpected work directory: $WORK_ROOT" >&2
    exit 1
    ;;
esac

rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT" "$OUTPUT_ROOT/lib" "$OUTPUT_ROOT/include"
curl -L --fail --retry 5 --retry-all-errors --connect-timeout 20 \
  "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
  -o "$WORK_ROOT/ffmpeg.tar.xz"
tar -xf "$WORK_ROOT/ffmpeg.tar.xz" -C "$WORK_ROOT"
SOURCE_ROOT="$WORK_ROOT/ffmpeg-${FFMPEG_VERSION}"

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
    --cc="$TOOLCHAIN_BIN/clang" \
    --cxx="$TOOLCHAIN_BIN/clang++" \
    --ar="$TOOLCHAIN_BIN/ar" \
    --ranlib="$TOOLCHAIN_BIN/ranlib" \
    --nm="$TOOLCHAIN_BIN/nm" \
    --strip="$TOOLCHAIN_BIN/strip" \
    --sysroot="$SDK_PATH" \
    --extra-cflags="-target $target -isysroot $SDK_PATH -fembed-bitcode -O3" \
    --extra-ldflags="-target $target -isysroot $SDK_PATH" \
    --disable-shared \
    --enable-static \
    --enable-pic \
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
    --enable-protocol=tcp,udp \
    --enable-demuxer=rtsp,rtp,sdp \
    --enable-decoder=h264,hevc \
    --enable-parser=h264,hevc \
    --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox \
    --enable-videotoolbox \
    --disable-bzlib \
    --disable-iconv \
    --disable-lzma \
    --disable-zlib
  make -j"$(nproc)"
  make install
  popd >/dev/null
}

build_slice arm64 arm64-apple-ios15.0
build_slice arm64e arm64e-apple-ios15.0

cp -R "$WORK_ROOT/install-arm64/include/." "$OUTPUT_ROOT/include/"
for library in avformat avcodec avutil; do
  "$TOOLCHAIN_BIN/lipo" -create \
    "$WORK_ROOT/install-arm64/lib/lib${library}.a" \
    "$WORK_ROOT/install-arm64e/lib/lib${library}.a" \
    -output "$OUTPUT_ROOT/lib/lib${library}.a"
done
cp "$SOURCE_ROOT/COPYING.LGPLv2.1" "$OUTPUT_ROOT/COPYING.LGPLv2.1"
echo "Built universal arm64/arm64e FFmpeg $FFMPEG_VERSION"

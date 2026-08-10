#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
THEOS_ROOT="${VCAM_THEOS:-/opt/theos}"
SDK_PATH="${VCAM_IOS_SDK:-$THEOS_ROOT/sdks/iPhoneOS16.5.sdk}"
TOOLCHAIN_BIN="${VCAM_IOS_TOOLCHAIN_BIN:-$THEOS_ROOT/toolchain/linux/iphone/bin}"
GST_ROOT="$PROJECT_ROOT/dist/gstreamer-prebuilt/inspection-1.28.6/GStreamer.xcframework/ios-arm64"
OUTPUT_DIR="$PROJECT_ROOT/dist/gstreamer-probe"
OUTPUT="$OUTPUT_DIR/vcam-gstreamer-rtsp-probe"

if [[ ! -x "$TOOLCHAIN_BIN/clang" ]]; then
  echo "iOS clang is missing: $TOOLCHAIN_BIN/clang" >&2
  exit 1
fi
if [[ ! -f "$GST_ROOT/libGStreamer.a" || ! -f "$GST_ROOT/Headers/gst/gst.h" ]]; then
  echo "Verified GStreamer 1.28.6 arm64 files are missing under $GST_ROOT" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
"$TOOLCHAIN_BIN/clang" \
  -target arm64-apple-ios16.0 \
  -isysroot "$SDK_PATH" \
  -O2 -Wall -Wextra -Werror=return-type \
  -I"$GST_ROOT/Headers" -I"$GST_ROOT/Headers/arm64" \
  "$PROJECT_ROOT/tools/gstreamer-rtsp-probe/main.c" \
  "$GST_ROOT/libGStreamer.a" \
  -Wl,-dead_strip \
  -framework Accelerate \
  -framework AudioToolbox \
  -framework AVFoundation \
  -framework CFNetwork \
  -framework CoreAudio \
  -framework CoreFoundation \
  -framework CoreGraphics \
  -framework CoreMedia \
  -framework CoreText \
  -framework CoreVideo \
  -framework Foundation \
  -framework IOSurface \
  -framework Metal \
  -framework OpenGLES \
  -framework QuartzCore \
  -framework Security \
  -framework SystemConfiguration \
  -framework UIKit \
  -framework VideoToolbox \
  -lc++ -liconv -lresolv -lsqlite3 -lz \
  -o "$OUTPUT"

"$TOOLCHAIN_BIN/ldid" -S"$PROJECT_ROOT/vcamd.entitlements" "$OUTPUT"
sha256sum "$OUTPUT"
file "$OUTPUT"

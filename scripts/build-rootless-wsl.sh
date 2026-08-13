#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THEOS_ROOT="${VCAM_THEOS:-/opt/theos}"
SDK_PATH="${VCAM_IOS_SDK:-$THEOS_ROOT/sdks/iPhoneOS16.5.sdk}"
TOOLCHAIN_BIN="${VCAM_IOS_TOOLCHAIN_BIN:-$THEOS_ROOT/toolchain/linux/iphone/bin}"

if [[ ! -f "$THEOS_ROOT/makefiles/common.mk" ]]; then
  echo "Theos is missing: $THEOS_ROOT" >&2
  exit 1
fi
if [[ ! -d "$SDK_PATH/System/Library/Frameworks" ]]; then
  echo "iOS SDK is missing: $SDK_PATH" >&2
  exit 1
fi
if [[ ! -x "$TOOLCHAIN_BIN/clang" ]]; then
  echo "iOS toolchain is missing: $TOOLCHAIN_BIN" >&2
  exit 1
fi

export THEOS="$THEOS_ROOT"
export THEOS_SDKS_PATH="$(dirname "$SDK_PATH")"
export SDKBINPATH="$TOOLCHAIN_BIN"
export VCAM_IOS_SDK="$SDK_PATH"
export VCAM_IOS_TOOLCHAIN_BIN="$TOOLCHAIN_BIN"
export PATH="$TOOLCHAIN_BIN:$PATH"

cd "$PROJECT_ROOT"
bash ./scripts/build-ffmpeg-ios-linux.sh

BUILD_ROOT="$(mktemp -d /tmp/vcam-rootless-build.XXXXXX)"
trap 'rm -rf "$BUILD_ROOT"' EXIT
# Historical artifacts make a blind workspace copy both slow and ambiguous.
# Stage only build inputs; the git database, previous packages and compiler
# cache are never inputs to a clean verification build.
tar --exclude='./.git' --exclude='./.theos' --exclude='./packages' \
    --exclude='./dist' -C "$PROJECT_ROOT" -cf - . | tar -C "$BUILD_ROOT" -xf -
chmod -R a+rX,go-w "$BUILD_ROOT"
chmod 755 "$BUILD_ROOT/layout/DEBIAN"
case "$BUILD_ROOT" in
  /tmp/vcam-rootless-build.*) ;;
  *) echo "Unexpected build root: $BUILD_ROOT" >&2; exit 1 ;;
esac
cd "$BUILD_ROOT"
if [[ "${VCAM_COMPILE_ONLY:-0}" == "1" ]]; then
  # Local WSL vendor/ffmpeg only ships arm64; build the arm64 slice for the
  # compile check. CI builds both slices with build-ffmpeg-ios.sh.
  make clean all FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless ARCHS=arm64
  echo "Rootless compile check passed (no package produced)"
  exit 0
fi
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless

mapfile -t PACKAGES < <(find "$BUILD_ROOT/packages" -maxdepth 1 -type f -name '*.deb' -print)
if [[ "${#PACKAGES[@]}" -ne 1 ]]; then
  echo "Expected exactly one new rootless package, found ${#PACKAGES[@]}" >&2
  printf '%s\n' "${PACKAGES[@]}" >&2
  exit 1
fi

PACKAGE_PATH="${PACKAGES[0]}"
PACKAGE_VERSION="$(dpkg-deb -f "$PACKAGE_PATH" Version)"
PACKAGE_ARCH="$(dpkg-deb -f "$PACKAGE_PATH" Architecture)"
EXPECTED_PACKAGE_VERSION="$(awk '/^Version:/ {print $2; exit}' "$PROJECT_ROOT/control")"
if [[ -z "$EXPECTED_PACKAGE_VERSION" || "$PACKAGE_VERSION" != "$EXPECTED_PACKAGE_VERSION" ]]; then
  echo "Unexpected package version: $PACKAGE_VERSION" >&2
  exit 1
fi
if [[ "$PACKAGE_ARCH" != "iphoneos-arm64" ]]; then
  echo "Unexpected package architecture: $PACKAGE_ARCH" >&2
  exit 1
fi

STAGING_DIR="$PROJECT_ROOT/dist/wsl-rootless"
STAGED_PACKAGE="$STAGING_DIR/com.codex.vcam_${PACKAGE_VERSION}_iphoneos-arm64.deb"
mkdir -p "$STAGING_DIR"
cp "$PACKAGE_PATH" "$STAGED_PACKAGE"

echo "Rootless package ready: $STAGED_PACKAGE"
sha256sum "$STAGED_PACKAGE"

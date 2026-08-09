ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCAMMediaServerClient VCAMSpringBoardClient
TOOL_NAME = vcamd vcaminjectd

VCAM_SHARED_FILES = Sources/Shared/VCAMSharedFrame.m
VCAM_MODULE_CACHE_FLAGS = -fmodules-cache-path=$(THEOS_PROJECT_DIR)/.theos/module-cache
VCAM_UI_FILES = \
	Sources/UI/VCAMControlPanelViewController.m \
	Sources/UI/VCAMMediaPickerController.m \
	Sources/UI/VCAMSharedFramePreviewView.m

# mediaserverd is deliberately a shallow consumer: no network stack, decoder,
# UIKit, asset reader or FFmpeg is linked into this injected process.
VCAMMediaServerClient_FILES = \
	Sources/Hooks/VCAMMediaServerRefEntry.xm \
	Sources/Hooks/VCAMMediaServerRefImageUtils.m \
	$(VCAM_SHARED_FILES)
VCAMMediaServerClient_CFLAGS = -fobjc-arc -Wall -Wextra -Werror=return-type -Wno-deprecated-declarations -DVCAM_WITH_CONTROL_UI=0 $(VCAM_MODULE_CACHE_FLAGS)
VCAMMediaServerClient_FRAMEWORKS = CoreImage CoreMedia CoreVideo Foundation IOSurface ImageIO Metal VideoToolbox

# SpringBoard owns the broker; SpringBoard and filtered app clients host only
# the white-dot UI/panel. This target never hooks camera frames or decodes media.
VCAMSpringBoardClient_FILES = \
	Sources/Hooks/VCAMSpringBoardEntry.xm \
	Sources/Hooks/VCAMSpringBoardDiagnosticsStubs.m \
	Sources/SpringBoard/VCAMSpringBoardMediaBridge.m \
	Sources/Core/VCAMConfiguration.m \
	$(VCAM_UI_FILES) \
	$(VCAM_SHARED_FILES)
VCAMSpringBoardClient_CFLAGS = -fobjc-arc -Wall -Wextra -Werror=return-type -DVCAM_WITH_CONTROL_UI=1 $(VCAM_MODULE_CACHE_FLAGS)
VCAMSpringBoardClient_FRAMEWORKS = AVFoundation CoreImage CoreMedia CoreVideo Foundation IOSurface Metal PhotosUI QuartzCore UIKit UniformTypeIdentifiers

# vcamd is package-owned and is not injected. All local media, OBS, RTSP and
# HLS work lives here so a decoder/network failure cannot directly crash an
# injected client.
vcamd_FILES = \
	Sources/Daemon/main.m \
	Sources/Daemon/VCAMHardwareVideoDecoder.m \
	Sources/Daemon/VCAMPixelConverter.m \
	Sources/Daemon/VCAMFrameProducer.m \
	Sources/Core/VCAMConfiguration.m \
	Sources/Core/VCAMFrameRenderer.m \
	Sources/Sources/VCAMLocalMediaSource.m \
	Sources/Sources/VCAMOBSStreamSource.m \
	Sources/Sources/VCAMRTSPStreamSource.m \
	$(VCAM_SHARED_FILES)
vcamd_ARCHS = arm64
vcamd_INSTALL_PATH = /usr/libexec
vcamd_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/vcamd.entitlements
vcamd_CFLAGS = -fobjc-arc -Wall -Wextra -Werror=return-type -I$(THEOS_PROJECT_DIR)/vendor/ffmpeg/include $(VCAM_MODULE_CACHE_FLAGS)
vcamd_FRAMEWORKS = Accelerate AVFoundation AudioToolbox CoreMedia CoreVideo Foundation IOSurface ImageIO QuartzCore Security VideoToolbox
vcamd_LDFLAGS = -L$(THEOS_PROJECT_DIR)/vendor/ffmpeg/lib
vcamd_LIBRARIES = avformat avcodec avutil

# A tiny root watchdog repairs only the two allowed dylib mappings after a
# SpringBoard/mediaserverd restart. It never decodes media and never targets an
# application process.
vcaminjectd_FILES = Sources/Daemon/VCAMInjectionMonitor.m
vcaminjectd_ARCHS = arm64
vcaminjectd_INSTALL_PATH = /usr/libexec
vcaminjectd_CFLAGS = -fobjc-arc -Wall -Wextra -Werror=return-type $(VCAM_MODULE_CACHE_FLAGS)
vcaminjectd_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk

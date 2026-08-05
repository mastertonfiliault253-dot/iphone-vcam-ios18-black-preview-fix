ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCAMMediaServerClient VCAMSpringBoardClient
TOOL_NAME = vcamd

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
VCAMMediaServerClient_FRAMEWORKS = CoreImage CoreMedia CoreVideo Foundation Metal

# SpringBoard owns the white-dot UI, configuration broker, media picker and
# preview. It reads published frames but never decodes RTSP or local video.
VCAMSpringBoardClient_FILES = \
	Sources/Hooks/VCAMSpringBoardEntry.xm \
	Sources/Hooks/VCAMSpringBoardDiagnosticsStubs.m \
	Sources/Core/VCAMConfiguration.m \
	$(VCAM_UI_FILES) \
	$(VCAM_SHARED_FILES)
VCAMSpringBoardClient_CFLAGS = -fobjc-arc -Wall -Wextra -Werror=return-type -DVCAM_WITH_CONTROL_UI=1 $(VCAM_MODULE_CACHE_FLAGS)
VCAMSpringBoardClient_FRAMEWORKS = AVFoundation CoreMedia CoreVideo Foundation PhotosUI QuartzCore UIKit UniformTypeIdentifiers

# vcamd is package-owned and is not injected. All local media, OBS and direct
# RTSP work lives here so a decoder/network failure cannot directly crash an
# injected client.
vcamd_FILES = \
	Sources/Daemon/main.m \
	Sources/Daemon/VCAMFrameProducer.m \
	Sources/Core/VCAMConfiguration.m \
	Sources/Core/VCAMFrameRenderer.m \
	Sources/Sources/VCAMLocalMediaSource.m \
	Sources/Sources/VCAMOBSStreamSource.m \
	Sources/Sources/VCAMRTSPStreamSource.m \
	$(VCAM_SHARED_FILES)
vcamd_ARCHS = arm64
vcamd_INSTALL_PATH = /usr/libexec
vcamd_CFLAGS = -fobjc-arc -Wall -Wextra -Werror=return-type -I$(THEOS_PROJECT_DIR)/vendor/ffmpeg/include $(VCAM_MODULE_CACHE_FLAGS)
vcamd_FRAMEWORKS = AVFoundation AudioToolbox CoreMedia CoreVideo Foundation ImageIO QuartzCore VideoToolbox
vcamd_LDFLAGS = -L$(THEOS_PROJECT_DIR)/vendor/ffmpeg/lib
vcamd_LIBRARIES = avformat avcodec avutil

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk

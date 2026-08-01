ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Camera

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCAM

VCAM_FILES = \
	Sources/Hooks/VCAMCaptureHooks.xm \
	Sources/Core/VCAMConfiguration.m \
	Sources/Core/VCAMAssetWriterRecorder.m \
	Sources/Core/VCAMFramePipeline.m \
	Sources/Core/VCAMFrameRenderer.m \
	Sources/Core/VCAMPhotoAuxiliaryData.m \
	Sources/Hooks/VCAMPreviewDriver.m \
	Sources/Sources/VCAMLocalMediaSource.m \
	Sources/Sources/VCAMOBSStreamSource.m
VCAM_CFLAGS = -fobjc-arc -Wall -Wextra -Werror=return-type
VCAM_FRAMEWORKS = AVFoundation AudioToolbox CoreImage CoreMedia CoreVideo Foundation ImageIO QuartzCore UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

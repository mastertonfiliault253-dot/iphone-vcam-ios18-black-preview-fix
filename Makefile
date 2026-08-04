ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Camera

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCAM VCAMAppClient VCAMSpringBoardClient

VCAM_COMMON_FILES = \
	Sources/Hooks/VCAMCaptureHooks.xm \
	Sources/Core/VCAMConfiguration.m \
	Sources/Core/VCAMInjectionPolicy.m \
	Sources/Core/VCAMAssetWriterRecorder.m \
	Sources/Core/VCAMFramePipeline.m \
	Sources/Core/VCAMFrameRenderer.m \
	Sources/Core/VCAMPhotoAuxiliaryData.m \
	Sources/Sources/VCAMLocalMediaSource.m \
	Sources/Sources/VCAMOBSStreamSource.m \
	Sources/Sources/VCAMRTSPStreamSource.m
VCAM_UI_FILES = \
	Sources/UI/VCAMControlPanelViewController.m \
	Sources/UI/VCAMMediaPickerController.m
VCAM_FILES = $(VCAM_COMMON_FILES) Sources/Hooks/VCAMCameraPreviewHooks.xm Sources/Hooks/VCAMPreviewDriver.m $(VCAM_UI_FILES)
VCAM_CFLAGS = -fobjc-arc -Wall -Wextra -Werror=return-type -DVCAM_WITH_CONTROL_UI=1
VCAM_FRAMEWORKS = AVFoundation AudioToolbox CoreImage CoreMedia CoreVideo Foundation ImageIO PhotosUI QuartzCore UIKit UniformTypeIdentifiers VideoToolbox
VCAM_LDFLAGS = -L$(THEOS_PROJECT_DIR)/vendor/ffmpeg/lib
VCAM_LIBRARIES = avformat avcodec avutil
VCAM_CFLAGS += -I$(THEOS_PROJECT_DIR)/vendor/ffmpeg/include

VCAMAppClient_FILES = $(VCAM_COMMON_FILES) $(VCAM_UI_FILES)
VCAMAppClient_CFLAGS = -fobjc-arc -Wall -Wextra -Werror=return-type -DVCAM_WITH_CONTROL_UI=1 -I$(THEOS_PROJECT_DIR)/vendor/ffmpeg/include
VCAMAppClient_FRAMEWORKS = AVFoundation AudioToolbox CoreImage CoreMedia CoreVideo Foundation ImageIO PhotosUI QuartzCore UIKit UniformTypeIdentifiers VideoToolbox
VCAMAppClient_LDFLAGS = -L$(THEOS_PROJECT_DIR)/vendor/ffmpeg/lib
VCAMAppClient_LIBRARIES = avformat avcodec avutil


VCAMSpringBoardClient_FILES = Sources/Hooks/VCAMSpringBoardEntry.xm Sources/Hooks/VCAMSpringBoardDiagnosticsStubs.m Sources/Core/VCAMConfiguration.m Sources/Core/VCAMInjectionPolicy.m $(VCAM_UI_FILES)
VCAMSpringBoardClient_CFLAGS = -fobjc-arc -Wall -Wextra -Werror=return-type -DVCAM_WITH_CONTROL_UI=1
VCAMSpringBoardClient_FRAMEWORKS = AVFoundation Foundation PhotosUI QuartzCore UIKit UniformTypeIdentifiers

include $(THEOS_MAKE_PATH)/tweak.mk

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:18.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VCAMDetectProbe
VCAMDetectProbe_FILES = main.m ProbeRunner.m
VCAMDetectProbe_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo CoreMotion ImageIO MobileCoreServices WebKit
VCAMDetectProbe_CFLAGS = -fobjc-arc -Wall -Wextra -Werror=return-type -Wno-deprecated-declarations
VCAMDetectProbe_CODESIGN_FLAGS = -Sentitlements.plist
VCAMDetectProbe_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

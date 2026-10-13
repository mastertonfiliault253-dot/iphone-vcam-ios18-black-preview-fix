ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:18.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VCAMDetectProbe
VCAMDetectProbe_FILES = main.m ProbeRunner.m MiniRunner.m
VCAMDetectProbe_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo CoreMotion ImageIO MobileCoreServices WebKit Vision
VCAMDetectProbe_CFLAGS = -fobjc-arc -Wall -Wextra -Werror=return-type -Wno-deprecated-declarations
VCAMDetectProbe_CODESIGN_FLAGS = -Sentitlements.plist
VCAMDetectProbe_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

# CLI 探针（装到 /var/jb/usr/bin）：非 App 身份的原生采集载体，
# 用于隔离"palette App 零帧"是否由应用安装/启动身份造成。
TOOL_NAME = vcamprobcli
vcamprobcli_FILES = cli_main.m MiniRunner.m
vcamprobcli_FRAMEWORKS = Foundation AVFoundation CoreMedia CoreVideo
vcamprobcli_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tool.mk

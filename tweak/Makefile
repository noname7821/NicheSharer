ARCHS = arm64 arm64e
# Tuned for Dopamine (rootless) on iOS 15: latest SDK, 15.0 floor.
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NicheShare

NicheShare_FILES = Tweak.xm NSDaemon.m NSInputInjector.m NSScreenCapture.m NSLogger.m
NicheShare_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
NicheShare_FRAMEWORKS = Foundation UIKit CoreGraphics VideoToolbox

include $(THEOS_MAKE_PATH)/tweak.mk

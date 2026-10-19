THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:16.3
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WXRelay
WXRelay_FILES = Tweak.m
WXRelay_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-parameter
WXRelay_FRAMEWORKS = Foundation UIKit CoreFoundation AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

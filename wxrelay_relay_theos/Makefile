THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:16.3
ARCHS = arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WXRelayRelay
WXRelayRelay_FILES = Tweak.m
WXRelayRelay_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-parameter
WXRelayRelay_FRAMEWORKS = Foundation CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

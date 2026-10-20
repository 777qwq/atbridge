THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:16.3
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = wxrelaypref
wxrelaypref_FILES = Root.m
wxrelaypref_FRAMEWORKS = UIKit Foundation
wxrelaypref_INSTALL_PATH = /Library/PreferenceBundles
wxrelaypref_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/bundle.mk

after-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp wxrelayprefentry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/wxrelaypref.plist$(ECHO_END)

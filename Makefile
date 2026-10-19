THEOS tweaks skipped — cloud build via GitHub Actions (xcodebuild/clang):
TARGET = ATBridge.dylib
CFLAGS = -arch arm64 -arch arm64e -dynamiclib -framework Foundation -framework CoreFoundation -fobjc-arc
$(TARGET): Tweak.m
	clang $(CFLAGS) -o $@ $<
	ldid -M -S $@

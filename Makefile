# Hapus baris di bawah kalau jailbreak kamu rootful (unc0ver/checkra1n/palera1n rootful)
export THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GlassSearch
GlassSearch_FILES = Tweak.x
GlassSearch_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable
GlassSearch_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

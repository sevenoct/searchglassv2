TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = GlassSearchPrefs
GlassSearchPrefs_FILES = GSRootListController.m
GlassSearchPrefs_FRAMEWORKS = UIKit
GlassSearchPrefs_LDFLAGS = -undefined dynamic_lookup
GlassSearchPrefs_INSTALL_PATH = /Library/PreferenceBundles
GlassSearchPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

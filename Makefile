TARGET := iphone:clang:latest:15.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME ?= rootless
INSTALL_TARGET_PROCESSES := Aweme

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := DYFullScreen
DYFullScreen_FILES := DYFullScreen.xm
DYFullScreen_CFLAGS := -fobjc-arc -w -ISources
DYFullScreen_FRAMEWORKS := UIKit Foundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = OmniSpeedPrefs

OmniSpeedPrefs_FILES = OSPRootListController.m
OmniSpeedPrefs_FRAMEWORKS = UIKit
OmniSpeedPrefs_PRIVATE_FRAMEWORKS = Preferences
OmniSpeedPrefs_INSTALL_PATH = /Library/PreferenceBundles
# Version shown in the footer card, read from ../control.
OmniSpeedPrefs_CFLAGS = -fobjc-arc -I../App -DTWEAK_VERSION=\"$(shell sed -n 's/^Version: *//p' ../control | tr -d '\r')\"

include $(THEOS_MAKE_PATH)/bundle.mk

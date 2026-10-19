TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_VERSION := $(shell sed -n 's/^Version: *//p' control | tr -d '\r')

# Layout (no hooks - OmniSpeed is an app + its settings page):
#   App/              the OmniSpeed app (/Applications/OmniSpeed.app): GPS speed + the road's maxspeed from
#                     OpenStreetMap (Overpass API, cached). App/OmniSpeed.h is the contract shared with the prefs.
#   omnispeedprefs/   Settings > OmniSpeed (PreferenceLoader bundle), built as a subproject

# --- App ------------------------------------------------------------------------------------------
# Installed to /Applications; the package manager runs uicache. omnispeed:// opens it (Shortcuts / Siri).
APPLICATION_NAME = OmniSpeed

OmniSpeed_FILES = $(wildcard App/*.m)
OmniSpeed_FRAMEWORKS = UIKit CoreLocation QuartzCore
OmniSpeed_CFLAGS = -fobjc-arc -IApp -DTWEAK_VERSION=\"$(TWEAK_VERSION)\"
OmniSpeed_RESOURCE_DIRS = App/Resources
OmniSpeed_CODESIGN_FLAGS = -SApp/entitlements.plist

# --- Settings bundle ------------------------------------------------------------------------------
SUBPROJECTS += omnispeedprefs

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

# Everything in the package must be world-readable (the Settings app reads the bundle as user mobile).
after-stage::
	find "$(THEOS_STAGING_DIR)" -name '*.plist' -exec chmod 644 {} +

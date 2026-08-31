# WetypePlus — theos 工程（照 KeyboardPlusPro 范式）
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:14.0:14.5
export THEOS_PACKAGE_SCHEME = rootless
export GO_EASY_ON_ME = 1

include $(THEOS)/makefiles/common.mk

# ---------------- Tweak（ElleKit / TweakInject 注入） ----------------
TWEAK_NAME = WetypePlus
WetypePlus_FILES = src/Tweak.xm
WetypePlus_FRAMEWORKS = UIKit Foundation CoreGraphics
WetypePlus_LDFLAGS = -Wl,-undefined,dynamic_lookup
WetypePlus_CFLAGS = -fobjc-arc -fobjc-exceptions -Wno-deprecated-declarations -Wno-error -Isrc
include $(THEOS_MAKE_PATH)/tweak.mk

# ---------------- 设置面板 PreferenceBundle ----------------
BUNDLE_NAME = WetypePlusPrefs
WetypePlusPrefs_FILES = Preferences/WPSettingsController.m
WetypePlusPrefs_INSTALL_PATH = /Library/PreferenceBundles
WetypePlusPrefs_FRAMEWORKS = UIKit Foundation
WetypePlusPrefs_CFLAGS = -fobjc-arc -fobjc-exceptions -Isrc
WetypePlusPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
include $(THEOS_MAKE_PATH)/bundle.mk

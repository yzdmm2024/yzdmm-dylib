# KKGameAutoLogin — theos 工程（照 keyboardpluspro 范式）
# 关键：ARCHS = arm64 arm64e → 用 macOS 原生 clang/ld 产出真正的 FAT arm64e
#        （带合法 LC_DYLD_CHAINED_FIXUPS，roothide/A14 加载器才接受）。
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:14.0:14.5
export THEOS_PACKAGE_SCHEME = rootless
export GO_EASY_ON_ME = 1

include $(THEOS)/makefiles/common.mk

# ---------------- Tweak（TweakInject 注入：dylib + Filter.plist） ----------------
TWEAK_NAME = KKGameAutoLogin
KKGameAutoLogin_FILES = src/Tweak.xm
KKGameAutoLogin_FRAMEWORKS = UIKit Foundation WebKit
# 纯 Objective-C runtime swizzle + 符号动态解析，避免链接期缺框架。
KKGameAutoLogin_LDFLAGS = -Wl,-undefined,dynamic_lookup
KKGameAutoLogin_CFLAGS = -fobjc-arc -fobjc-exceptions -Wno-deprecated-declarations -Wno-error -Isrc
include $(THEOS_MAKE_PATH)/tweak.mk

# ---------------- 设置面板 PreferenceBundle ----------------
# 编译成 MH_DYLIB，由 CI 注入 layout 的 bundle 作为 CFBundleExecutable。
BUNDLE_NAME = KKGameAutoLoginPrefs
KKGameAutoLoginPrefs_FILES = Preferences/KKGameSettingsController.m
KKGameAutoLoginPrefs_INSTALL_PATH = /Library/PreferenceBundles
KKGameAutoLoginPrefs_FRAMEWORKS = UIKit Foundation
KKGameAutoLoginPrefs_CFLAGS = -fobjc-arc -fobjc-exceptions -Isrc
KKGameAutoLoginPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
include $(THEOS_MAKE_PATH)/bundle.mk
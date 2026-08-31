# KeyboardPlusPro — theos 工程（照 SN3extension 范式）
# 关键：ARCHS = arm64 arm64e → 用 macOS 原生 clang/ld 产出真正的 FAT arm64e
#        （带合法 LC_DYLD_CHAINED_FIXUPS，roothide/A14 加载器才接受）。
# 之前 Windows lld 方案产不出合法 arm64e（bind 操作码损坏），故改用本 theos 流程。
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:14.0:14.5
export THEOS_PACKAGE_SCHEME = rootless
# theos 默认开 -Werror，CI 难预编译验证时易被无害 warning 卡住。
export GO_EASY_ON_ME = 1

include $(THEOS)/makefiles/common.mk

# ---------------- Tweak（ElleKit / TweakInject 注入） ----------------
TWEAK_NAME = KeyboardPlusPro
KeyboardPlusPro_FILES = src/Tweak.xm
KeyboardPlusPro_FRAMEWORKS = UIKit Foundation CoreGraphics
# 原始 Windows 构建对一切符号走 dynamic_lookup；这里同样兜底，
# 避免 Tweak.xm 用到未显式列出的框架时链接失败。
KeyboardPlusPro_LDFLAGS = -Wl,-undefined,dynamic_lookup
KeyboardPlusPro_CFLAGS = -fobjc-arc -fobjc-exceptions -Wno-deprecated-declarations -Wno-error -Isrc
include $(THEOS_MAKE_PATH)/tweak.mk

# ---------------- 设置面板 PreferenceBundle ----------------
# 编译成 MH_DYLIB（与正常工作的偏好 bundle 一致），由 CI 注入 layout 的 bundle 作为 CFBundleExecutable。
BUNDLE_NAME = KeyboardPlusProPrefs
KeyboardPlusProPrefs_FILES = Preferences/KBPSettingsController.m
KeyboardPlusProPrefs_INSTALL_PATH = /Library/PreferenceBundles
KeyboardPlusProPrefs_FRAMEWORKS = UIKit Foundation
KeyboardPlusProPrefs_CFLAGS = -fobjc-arc -fobjc-exceptions -Isrc
# 偏好 bundle 在设置进程内加载，只引用标准框架 + 自身类（无外部自定义类），
# 用 dynamic_lookup 把解析推到运行时即可。
KeyboardPlusProPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
include $(THEOS_MAKE_PATH)/bundle.mk

# 用 Xcode 自带的 clang + iphoneos SDK 交叉编译出 iOS arm64 dylib
# 不依赖 theos / Substrate，纯 runtime 方法交换，非越狱自签注入可用。

SDK  := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC   := xcrun clang

CFLAGS := -dynamiclib \
          -arch arm64 \
          -isysroot $(SDK) \
          -miphoneos-version-min=9.0 \
          -fobjc-arc \
          -ObjC \
          -framework Foundation \
          -framework UIKit \
          -framework AVFoundation

BBAdBlockPlugin.dylib: BBAdBlockPlugin.m
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f BBAdBlockPlugin.dylib

.PHONY: clean

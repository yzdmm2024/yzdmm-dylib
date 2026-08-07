#!/bin/bash
# 把编译好的 dylib 注入目标 App 的 IPA，并用你的开发证书重签。
# 需要：brew install insert_dylib
#
# 用法：
#   ./inject.sh /path/to/Game.ipa "iPhone Developer: Your Name (TEAMID)" [输出名.ipa]
#
# 流程：解压 IPA -> insert_dylib 注入主二进制 -> 拷贝 dylib 进 .app ->
#       用同一证书重签 app 与 dylib -> 重新打包为 IPA。

set -e

IPA="$1"
CERT="$2"
OUT="${3:-Game_patched.ipa}"

if [ -z "$IPA" ] || [ -z "$CERT" ]; then
  echo "用法: ./inject.sh <Game.ipa> <证书名> [输出.ipa]"
  exit 1
fi

[ -f BBAdBlockPlugin.dylib ] || { echo "先 make 生成 BBAdBlockPlugin.dylib"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

unzip -q "$IPA" -d "$WORK"
APP=$(find "$WORK/Payload" -name "*.app" -maxdepth 1 | head -n1)
BIN=$(find "$APP" -type f -perm +111 ! -name "*.dylib" ! -name "*.framework" | head -n1)

echo "[*] 注入 dylib 到: $BIN"
insert_dylib --all-yes --inplace @executable_path/BBAdBlockPlugin.dylib "$BIN"

echo "[*] 拷贝 dylib 进 .app"
cp BBAdBlockPlugin.dylib "$APP/"

echo "[*] 重签（dylib + app 用同一证书）"
codesign --force --sign "$CERT" "$APP/BBAdBlockPlugin.dylib"
codesign --force --deep --sign "$CERT" "$APP"

echo "[*] 重新打包"
cd "$WORK" && zip -qr "$OUT" Payload
echo "[+] 完成 -> $OUT"

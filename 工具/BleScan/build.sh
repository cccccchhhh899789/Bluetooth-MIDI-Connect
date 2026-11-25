#!/bin/bash
# build.sh — 编译 BleScan 阳性对照扫描器（bundle 版，声明 NSBluetoothAlwaysUsage）
# 产物：build/BleScan.app（universal2）
# 用法：bash build.sh
set -e
cd "$(dirname "$0")"

APP="build/BleScan.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
SRC="main.m"

echo "==> 清理"
rm -rf build/ && mkdir -p build/clang-module-cache "$MACOS" "$RES"

echo "==> 编译（x86_64 + arm64）"
clang -fobjc-arc -fmodules \
  -fmodules-cache-path="build/clang-module-cache" \
  -arch x86_64 -arch arm64 \
  -O2 \
  -Wno-poison-system-directories \
  -Wno-direct-ivar-access \
  -Wno-declaration-after-statement \
  "$SRC" \
  -framework CoreBluetooth -framework Foundation \
  -o "$MACOS/BleScan"

echo "==> 写 Info.plist（含 NSBluetoothAlwaysUsage）"
cp Info.plist "$CONTENTS/Info.plist"

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$APP" 2>/dev/null

echo "==> 架构检查"
lipo -archs "$MACOS/BleScan"

echo "==> 完成：$APP"

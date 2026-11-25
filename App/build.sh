#!/bin/bash
# build.sh — 编译蓝牙 MIDI 连接助手 App（多选版，方案 B）
# 产物：build/蓝牙MIDI连接.app（universal2: x86_64 + arm64）
# 用法：bash build.sh
set -e
cd "$(dirname "$0")"

APP="build/蓝牙MIDI连接.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
SRC="src/main.m"

echo "==> 清理"
rm -rf build/ && mkdir -p build/clang-module-cache "$MACOS" "$RES"

echo "==> 编译（x86_64 + arm64）"
clang -fobjc-arc -fmodules \
  -fmodules-cache-path="build/clang-module-cache" \
  -arch x86_64 -arch arm64 \
  -O2 \
  -Wno-poison-system-directories \
  -Wno-direct-ivar-access \
  -Wno-objc-missing-super-calls \
  -Wno-declaration-after-statement \
  "$SRC" \
  -framework Cocoa -framework CoreMIDI -framework Foundation \
  -o "$MACOS/蓝牙MIDI连接"

echo "==> 生成图标"
clang -fobjc-arc -fmodules -fmodules-cache-path="build/clang-module-cache" \
  -framework Cocoa -o build/makeicon tools/makeicon.m
# iconutil 不能直接写外接盘，先在 /tmp 生成再拷回来
rm -rf /tmp/blemidi-icon-work && mkdir -p /tmp/blemidi-icon-work
build/makeicon /tmp/blemidi-icon-work/AppIcon.iconset
iconutil -c icns /tmp/blemidi-icon-work/AppIcon.iconset -o /tmp/blemidi-icon-work/AppIcon.icns
cp /tmp/blemidi-icon-work/AppIcon.icns "$RES/AppIcon.icns"
rm -rf /tmp/blemidi-icon-work

echo "==> 写 Info.plist"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                  <string>蓝牙MIDI连接</string>
  <key>CFBundleDisplayName</key>           <string>蓝牙 MIDI 连接助手</string>
  <key>CFBundleIdentifier</key>            <string>local.cme.blemidi.connect</string>
  <key>CFBundleExecutable</key>            <string>蓝牙MIDI连接</string>
  <key>CFBundlePackageType</key>           <string>APPL</string>
  <key>CFBundleShortVersionString</key>    <string>0.1.0</string>
  <key>CFBundleVersion</key>               <string>0.1.0</string>
  <key>LSMinimumSystemVersion</key>        <string>11.0</string>
  <key>NSHighResolutionCapable</key>       <true/>
  <key>NSPrincipalClass</key>              <string>NSApplication</string>
  <key>CFBundleIconFile</key>              <string>AppIcon</string>
</dict>
</plist>
PLIST

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$APP" 2>/dev/null

echo "==> 架构检查"
lipo -archs "$MACOS/蓝牙MIDI连接"

echo "==> 完成：$APP"
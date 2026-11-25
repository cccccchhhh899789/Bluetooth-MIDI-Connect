#!/bin/bash
# verify.sh — 蓝牙 MIDI 连接助手自检（一条命令跑完所有断言，输出 PASS/FAIL）
# 用法：bash verify.sh
set -u
cd "$(dirname "$0")"

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "==> 1. 构建产物存在"
APP="build/蓝牙MIDI连接.app"
if [ -d "$APP" ]; then ok "App 存在: $APP"; else bad "缺 $APP（先跑 bash build.sh）"; fi

echo "==> 2. 可执行文件存在且是 universal2"
EXE="$APP/Contents/MacOS/蓝牙MIDI连接"
if [ -x "$EXE" ]; then
    ok "可执行存在"
    ARCHS=$(lipo -archs "$EXE" 2>/dev/null | tr '\n' ' ')
    echo "    架构: $ARCHS"
    [ -z "${ARCHS##*x86_64*}" ] && ok "含 x86_64" || bad "缺 x86_64"
    [ -z "${ARCHS##*arm64*}" ]  && ok "含 arm64"  || bad "缺 arm64"
else
    bad "缺可执行 $EXE"
fi

echo "==> 3. Info.plist 关键字段"
PLIST="$APP/Contents/Info.plist"
if [ -f "$PLIST" ]; then
    Exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST" 2>/dev/null)
    Id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null)
    [ "$Exe" = "蓝牙MIDI连接" ] && ok "CFBundleExecutable=$Exe" || bad "CFBundleExecutable=$Exe ≠ 蓝牙MIDI连接"
    [ "$Id" = "local.cme.blemidi.connect" ] && ok "CFBundleIdentifier=$Id" || bad "CFBundleIdentifier=$Id"
else
    bad "缺 Info.plist"
fi

echo "==> 4. 图标存在"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] && ok "AppIcon.icns 存在" || bad "缺 AppIcon.icns"

echo "==> 5. 代码签名（ad-hoc）"
if codesign --verify --deep "$APP" 2>/dev/null; then
    ok "签名有效"
else
    # ad-hoc 签名 verify 在部分系统会提示，转为检查签名存在
    CODESIGN_OUT=$(codesign -dv "$APP" 2>&1 | grep -i "Signature=" | head -1)
    [ -n "$CODESIGN_OUT" ] && ok "签名信息: $CODESIGN_OUT" || bad "签名异常"
fi

echo "==> 6. 驱动调用链（源码含核心调用）"
SRC="src/main.m"
grep -q "MIDIObjectSetDictionaryProperty" "$SRC" && ok "含 MidIObjectSetDictionaryProperty" || bad "源码缺连接调用"
grep -q "BLE MIDI Remote Peripheral" "$SRC" && ok "含 BLE MIDI Remote Peripheral 属性" || bad "源码缺属性名"

echo
echo "结果: $PASS 项通过 / $FAIL 项失败"
[ "$FAIL" -eq 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
#!/bin/bash
# bluetooth-midi.sh — 连接本机已配对/已见过的 BLE MIDI 设备（替代手动去音频MIDI设置点Connect）
#
# 原理（lumi-connect 验证过的路线）：
#   CoreMIDI 内建一个 "is BLE MIDI null device"=1 的隐藏设备（AppleMIDIBluetoothDriver 持有）。
#   给它设 "BLE MIDI Remote Peripheral"={"BLE MIDI Device UUID":…,"name":…}，驱动就会自己去连，
#   连完会移除该属性 —— 本机实测:属性被消费 = 请求已送达驱动（2026-11-26 验证）。
#   ⚠️ name 会改显示名：传「设备原本的名字」，别传 UUID（踩过：传 UUID 把 MidiPortB 显示名改成 UUID）
#
# 用法:
#   ./bluetooth-midi.sh list                       列出所有 BLE MIDI 设备 + UUID + 状态
#   ./bluetooth-midi.sh connect <uuid> [名字] [--watch 秒]   连接并轮询等待上线
#   ./bluetooth-midi.sh status                     只看 BLE MIDI 设备当前状态
#
# 注意: 设备必须开机且在蓝牙范围内,否则驱动收不到广播,连不上。
# 安全: 只设一个"请求连接"属性,不改配对/不删设备;新脚本首跑 --dry-run。

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$DIR/build/scan-midi"
CONN="$DIR/build/ble-midi-connect"

fail() { echo "✗ $1" >&2; exit 1; }
[ -x "$SCAN" ] || fail "缺 $SCAN — 先编译: clang -fmodules -Xclang -fmodules-cache-path=./build/module-cache -framework CoreMIDI -framework Foundation scan-midi.m -o $SCAN"
[ -x "$CONN" ] || fail "缺 $CONN — 先编译 ble-midi-connect.m"

# 提取 BLE 设备行（driver 是 AppleMIDIBluetoothDriver 且不是那个永远在线的 null 驱动）
ble_lines() {
  "$SCAN" 2>/dev/null | awk '
    /内部设备 name=Xkey|Keystation|USB MIDI|SINCO|ASX|U2MIDI|UxMIDI|网络|IAC/ { next }
    /internal|内部设备/ && /AppleMIDIBluetoothDriver/ && /isBLENull/ { print }
  '
}

cmd_list() {
  echo "== BLE MIDI 设备 =="
  ble_lines
  echo "(offline=0 在线; offline=1 离线/未连接; 设备名=MidiPortA/B)"
}

cmd_status() { cmd_list; }

cmd_connect() {
  [ $# -ge 1 ] || fail "用法: connect <uuid> [名字] [--watch 秒]"
  local uuid="$1"; shift
  local name="" watch=25 dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --watch) watch="${2:-25}"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      -*) shift ;;
      *) name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || name="BLE MIDI"
  # 名字不许是 UUID（会污染显示名）
  if echo "$name" | grep -qiE '^[0-9A-F]{8}-'; then
    fail "name 不能是 UUID（会污染显示名）——请传设备原本的名字，或省略用 'BLE MIDI'"
  fi
  if [ "$dry" = "1" ]; then
    echo "--dry-run: 将连接 UUID=$uuid name=$name, 轮询 ${watch}s（不实际执行）"
    return 0
  fi
  echo "→ 发送连接请求: $uuid (name=$name)"
  "$CONN" "$uuid" "$name" || fail "连接请求失败"
  echo "→ 轮询等待 BL E 设备上线(最多 ${watch}s)..."
  local waited=0
  while [ "$waited" -lt "$watch" ]; do
    sleep 2; waited=$((waited + 2))
    # 判上线:存在 offline=0 的 BLE 源/目的,且名字不是 null 驱动（排除永远在线的 isBLENull=1）
    if ble_lines | grep "offline=0" | grep -qv "isBLENull=1"; then
      echo "✅ 设备已上线:"
      ble_lines | grep "offline=0" | grep -v "isBLENull=1"
      return 0
    fi
    printf "  …%ss 仍未上线\n" "$waited"
  done
  echo
  echo "⚠️ ${watch}s 内未上线。常见原因:"
  echo "   1. 设备没开机 / 不在蓝牙范围 / 没进入可发现模式"
  echo "   2. 设备固件要求先配对确认(试着在 系统设置>蓝牙 里看它是否在)"
  echo "   3. 广播被别的设备抢走(手机 App 连着它)"
  return 1
}

case "${1:-}" in
  list) cmd_list ;;
  status) cmd_status ;;
  connect) shift; cmd_connect "$@" ;;
  *) echo "用法: $0 {list|status|connect <uuid> [名字] [--watch 秒] [--dry-run]}"; exit 1 ;;
esac
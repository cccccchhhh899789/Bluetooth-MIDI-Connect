#!/bin/bash
# cleanup-midi-bt.sh — 扫描并清理「占用 MIDI / 蓝牙」的进程
#
# 先查证结论(2026-11-26,来源 MIDIServer(8) 手册 + Thrum MIDIServer 指南 + Apple Audio MIDI Setup 手册):
#   · MIDIServer = CoreMIDI 中枢,本体 /System/Library/Frameworks/CoreMIDI.framework/MIDIServer
#     由 launchd 作业 com.apple.midiserver 托管,App 用 MIDI 或蓝牙 MIDI 连入时启动,平时空闲。
#   · 没有音乐 App 在用 MIDI 时,退出 MIDIServer 安全,launchd 会自动重启;
#     但运行中退出会**静默切断**正在用 MIDI 的 App(无报错,连接变哑)。
#   · CoreMIDI **没有**「谁持有 MIDIClient」的枚举 API → 「谁占用」只能靠 进程 + 蓝牙授权(TCC) 间接判断。
#   · MIDIServer 高 CPU 常见来源:设备持续发时钟/传感器消息、第三方 MIDI 驱动、网络/蓝牙 MIDI 反复重连。
#
# 用法:
#   ./cleanup-midi-bt.sh scan                       只读扫描,列出占用情况(默认动作,不动手)
#   ./cleanup-midi-bt.sh clean                      预览将要执行的清理动作(dry-run,不动手)
#   ./cleanup-midi-bt.sh clean --apply              真正执行预览的动作
#   ./cleanup-midi-bt.sh clean --apply --midiserver        仅重启 MIDIServer
#   ./cleanup-midi-bt.sh clean --apply --midi-apps        仅退出疑似 MIDI 类用户进程
#   ./cleanup-midi-bt.sh clean --apply --bt-apps          仅退出有蓝牙授权的用户进程
#   ./cleanup-midi-bt.sh clean --apply --kill "Logic"     仅退出指定进程(可多个)
#   ./cleanup-midi-bt.sh clean --apply --all              全部动作
#
# 安全: 默认 dry-run,真正清理必须显式 --apply;本脚本不删除任何文件。

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$DIR/build/scan-midi"
MIDISERVER="/System/Library/Frameworks/CoreMIDI.framework/MIDIServer"
TCC_DB="/var/db/TCC.db"
DRIVER_DIR="/Library/Audio/MIDI Drivers"

say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n== %s ==\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

# 进程基名列表(去重,排除纯系统路径里无斜杠的系统服务由调用方再筛)
proc_basenames() {
  have ps || return 0
  ps -axo command= 2>/dev/null | sed 's#.*/##' | grep -v '^$' | sort -u
}

# MIDI 类用户进程名特征(只用于提示,不直接杀)
MIDI_APP_KEYS='midi|logic|garageband|reaper|cubase|studioone|ableton|bitwig|musescore|finale|sibelius|airbuddy|kontrol|maschine|launchpad|keystation|auria|midi|pxr|meter|loopy'
BT_APP_KEYS='bluetooth|airbuddy|steam|chrome|firefox|spotify|music'

# ---------------------------------------------------------------- scan
do_scan() {
  say "蓝牙/MIDI 占用扫描    $(date '+%Y-%m-%d %H:%M:%S')"

  # 1) MIDIServer
  hdr "1. MIDIServer (CoreMIDI 中枢)"
  if have pgrep && pgrep -x MIDIServer >/dev/null 2>&1; then
    say "● 正在运行"
    ps -axo pid,user,%cpu,%mem,rss,etime,command= 2>/dev/null \
      | awk 'NR==1 || /[M]IDIServer/'
    say "提示: 运行时若有音乐 App 在用 MIDI,直接 kill 会静默切断它。"
  else
    say "○ 未运行(没有 App 在用 MIDI,或蓝牙 MIDI 未连入)——此时 kill 最安全。"
  fi
  [ -x "$MIDISERVER" ] && say "本体: $MIDISERVER ✓" || warn "本体缺失: $MIDISERVER"

  # 2) 疑似 MIDI 类用户进程
  hdr "2. 疑似 MIDI 类用户进程(间接判断)"
  proc_basenames | grep -Ei "$MIDI_APP_KEYS" | sed 's/^/   /' || say "   (无)"
  say "   (CoreMIDI 无持有者枚举 API,以上为按名字特征的间接判断)"

  # 3) 有蓝牙授权的应用(TCC.db)
  hdr "3. 有蓝牙授权的应用 (TCC.db)"
  if have sqlite3 && [ -f "$TCC_DB" ]; then
    sqlite3 "$TCC_DB" \
      "SELECT client_value FROM TCC WHERE service LIKE '%Bluetooth%';" 2>/dev/null \
      | sed 's/^/   /' | sort -u || say "   (读不到,可能需要「完全磁盘访问权限」)"
  else
    warn "TCC.db 不可读或 sqlite3 缺失,跳过。授权应用列表需系统设置查看。"
  fi

  # 4) 有蓝牙授权且正在运行的
  hdr "4. 有蓝牙授权、且当前在运行"
  if have sqlite3 && [ -f "$TCC_DB" ]; then
    bt_auth="$(sqlite3 "$TCC_DB" \
      "SELECT client_value FROM TCC WHERE service LIKE '%Bluetooth%';" 2>/dev/null | sort -u)"
    [ -n "$bt_auth" ] || say "   (未读到授权列表)"
    if [ -n "$bt_auth" ]; then
      while IFS= read -r b; do
        [ -n "$b" ] || continue
        # bundle id → 进程基名(取最后一段,粗略)
        bn="${b##*.}"
        proc_basenames | grep -qx "$bn" && say "   $b  (进程: $bn)"
      done <<< "$bt_auth"
    fi
  fi

  # 5) 已连接的蓝牙设备
  hdr "5. 已连接的蓝牙设备"
  have system_profiler && system_profiler SPBluetoothDataType 2>/dev/null \
    | sed -n '/Connected:/,$p' | sed 's/^/   /' || say "   (不可用)"

  # 6) MIDI 设备状态
  hdr "6. MIDI 设备状态"
  if [ -x "$SCAN" ]; then
    "$SCAN" 2>/dev/null | sed 's/^/   /'
  else
    warn "缺 $SCAN,跳过。先编译: clang -fmodules -Xclang -fmodules-cache-path=$DIR/build/module-cache -framework CoreMIDI -framework Foundation scan-midi.m -o $SCAN"
  fi

  # 7) 第三方 MIDI 驱动
  hdr "7. 第三方 MIDI 驱动 ($DRIVER_DIR)"
  if [ -d "$DRIVER_DIR" ]; then
    ls -1 "$DRIVER_DIR" 2>/dev/null | sed 's/^/   /' || say "   (空)"
  else
    say "   (目录不存在,无第三方驱动)"
  fi

  say "\n结论: 先看第 1 项。MIDIServer 未运行时清理最安全;"
  say "      想要精确清理,用 clean 预览再 --apply。"
}

# ---------------------------------------------------------------- clean
apply=0
kill_list=""
do_midiserver=0
do_midi_apps=0
do_bt_apps=0

do_clean() {
  # 逐个解析(用 while+shift,不能用 for+shift,否则会打乱迭代、把选项名当成进程名)
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply)      apply=1; shift ;;
      --midiserver) do_midiserver=1; shift ;;
      --midi-apps)  do_midi_apps=1; shift ;;
      --bt-apps)    do_bt_apps=1; shift ;;
      --all)        do_midiserver=1; do_midi_apps=1; do_bt_apps=1; shift ;;
      --kill)
        shift
        if [ $# -gt 0 ]; then kill_list="$kill_list $1"; shift; else warn "--kill 后面缺进程名"; fi
        ;;
      -*) warn "未知选项: $1"; shift ;;
      *)  warn "多余参数: $1"; shift ;;
    esac
  done

  hdr "清理预览(dry-run)"
  if [ "$apply" -eq 0 ]; then
    say "⚠ 当前为预览模式,不执行任何操作。加 --apply 才真正清理。"
  else
    say "✔ 已指定 --apply,将执行下方动作。"
  fi

  # --- 1 MIDIServer
  if [ "$do_midiserver" -eq 1 ]; then
    say "[1] 重启 MIDIServer"
    if have pgrep && pgrep -x MIDIServer >/dev/null 2>&1; then
      say "    将执行: killall MIDIServer"
      say "    影响: 正在用 MIDI 的 App 会被静默切断,MIDIServer 会被 launchd 自动重启。"
      [ "$apply" -eq 1 ] && { say "    → 执行 killall MIDIServer"; killall MIDIServer 2>/dev/null && say "    已发送,稍候 MIDIServer 会重启。"; }
    else
      say "    MIDIServer 未运行,无需操作。"
    fi
  fi

  # --- 2 疑似 MIDI 类进程
  if [ "$do_midi_apps" -eq 1 ]; then
    say "[2] 退出疑似 MIDI 类用户进程"
    hits="$(proc_basenames | grep -Ei "$MIDI_APP_KEYS" || true)"
    if [ -n "$hits" ]; then
      say "$hits" | sed 's/^/    将退出: /'
      [ "$apply" -eq 1 ] && while IFS= read -r n; do
        [ -n "$n" ] || continue
        say "    → 执行 killall $n"; killall "$n" 2>/dev/null || warn "    killall $n 失败(可能已退出)"
      done <<< "$hits"
    else
      say "    (无匹配进程)"
    fi
  fi

  # --- 3 蓝牙授权进程
  if [ "$do_bt_apps" -eq 1 ]; then
    say "[3] 退出有蓝牙授权、且正在运行的用户进程"
    if have sqlite3 && [ -f "$TCC_DB" ]; then
      bt_auth="$(sqlite3 "$TCC_DB" \
        "SELECT client_value FROM TCC WHERE service LIKE '%Bluetooth%';" 2>/dev/null | sort -u)"
      running="$(proc_basenames)"
      found=0
      while IFS= read -r b; do
        [ -n "$b" ] || continue
        bn="${b##*.}"
        if printf '%s\n' "$running" | grep -qx "$bn"; then
          say "    将退出: $b (进程: $bn)"; found=1
          [ "$apply" -eq 1 ] && { say "    → 执行 killall $bn"; killall "$bn" 2>/dev/null || warn "    killall $bn 失败"; }
        fi
      done <<< "$bt_auth"
      [ "$found" -eq 0 ] && say "    (授权列表里没有正在运行的)"
    else
      warn "TCC.db 不可读,跳过蓝牙授权进程清理。"
    fi
  fi

  # --- 4 显式指定
  if [ -n "$kill_list" ]; then
    say "[4] 退出指定进程"
    for n in $kill_list; do
      if proc_basenames | grep -qx "$n"; then
        say "    将退出: $n"
        [ "$apply" -eq 1 ] && { say "    → 执行 killall $n"; killall "$n" 2>/dev/null || warn "    killall $n 失败"; }
      else
        say "    跳过 $n(当前未运行)"
      fi
    done
  fi

  # 无动作
  if [ "$do_midiserver" -eq 0 ] && [ "$do_midi_apps" -eq 0 ] && [ "$do_bt_apps" -eq 0 ] && [ -z "$kill_list" ]; then
    warn "没有指定任何清理动作。参考: clean --all 或 clean --apply --midiserver"
  fi

  say
  if [ "$apply" -eq 0 ]; then
    say "以上为预览。确认无误后加 --apply 执行。"
  else
    say "清理动作已执行完毕。建议随后打开音频 MIDI 设置或本 App 确认设备恢复。"
  fi
}

# ---------------------------------------------------------------- main
case "${1:-scan}" in
  scan)        do_scan ;;
  scan-*)      do_scan "${@:2}" ;;
  clean)       do_clean "${@:2}" ;;
  clean-*)     do_clean "${@:2}" ;;
  -h|--help|help)
    sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
  *)
    warn "未知命令: $1(可用: scan / clean)"
    exit 2
    ;;
esac

#!/bin/bash
# make-installer.sh — 把「蓝牙MIDI连接.app」打包成安装包（dmg / pkg）
#
# 前提：先构建出 App
#   cd App && bash build.sh      # 生成 App/build/蓝牙MIDI连接.app
#
# 用法：
#   ./make-installer.sh                     # 打成 dmg（默认，拖出即用）
#   ./make-installer.sh --pkg              # 打成 pkg（双击安装）
#   ./make-installer.sh --dmg --out ~/Desktop/xxx.dmg
#   ./make-installer.sh --dry-run          # 只打印将执行的动作，不动手
#
# 说明：
#   - 版本号从 App 的 Info.plist 读 CFBundleShortVersionString，读不到默认 1.0.0
#   - dmg 的源(-srcfolder)必须在 APFS：App 先复制到 /tmp 的 staging 再打包，
#     源在 ExFAT 外接盘会被 hdiutil 拒（「操作不被允许」，本机实测）
#   - dmg 是 HFS+ 镜像，不能直写 ExFAT：脚本自动检测目标文件系统，
#     非 APFS/HFS 时先在 /tmp(APFS) 生成，成功后再移入目标
#   - pkg 用 pkgbuild 生成分发包（未签名，安装时会有提示）
#   - 脚本自建的 /tmp 临时目录会在结束时清理；不删除、不移动用户文件；
#     同名旧安装包会被覆盖
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$SCRIPT_DIR/App/build/蓝牙MIDI连接.app"
APP_NAME="蓝牙MIDI连接"

MODE="dmg"
DRY=0
OUT=""

# 脚本自建的 /tmp 临时目录（staging）；结束时清理，不影响用户文件
STAGE_DIR=""
cleanup() { [ -n "$STAGE_DIR" ] && rm -rf "$STAGE_DIR"; }
trap cleanup EXIT

# 打印文件头注释块（第 2 行起，遇到第一个非 # 行即停）
usage() {
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dmg)  MODE="dmg" ;;
    --pkg)  MODE="pkg" ;;
    --dry-run) DRY=1 ;;
    --out)  OUT="${2:?--out 需要一个路径}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "✗ 未知参数：$1"; echo; usage; exit 1 ;;
  esac
  shift
done

# —— 前置检查 ——
if [ ! -d "$APP_PATH" ]; then
  echo "✗ 找不到 App：$APP_PATH"
  echo "  先运行： cd App && bash build.sh"
  exit 1
fi

# —— 读版本号 ——
VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$VER" ] || VER="1.0.0"
VOLNAME="${APP_NAME} ${VER}"
echo "· App：$APP_PATH"
echo "· 版本：$VER"

run() {
  if [ "$DRY" -eq 1 ]; then
    echo "  [dry-run] $*"
  else
    echo "  + $*"
    "$@"
  fi
}

# 目标所在文件系统类型（apfs / hfs / exfat / tmpfs / ...），取最长前缀挂载点
# 注意：/tmp 是软链，真实路径 /private/tmp；挂载点 /System/Volumes/Data 等价于 /
fs_type_of() {
  local target="$1" dir real line mp norm match best_mp best_type
  dir="$(dirname "$target")"
  real="$(cd "$dir" 2>/dev/null && pwd -P)" || real="$target"
  best_mp=""; best_type=""
  while IFS= read -r line; do
    mp="$(printf '%s' "$line" | awk '{print $3}')"
    [ -n "$mp" ] || continue
    norm="$mp"
    [ "$norm" = "/System/Volumes/Data" ] && norm="/"
    if [ "$norm" = "/" ]; then
      match=1
    elif [ "$real" = "$norm" ] || [ "${real#"$norm"/}" != "$real" ]; then
      match=1
    else
      match=0
    fi
    if [ "$match" -eq 1 ]; then
      if [ -z "$best_mp" ] || [ ${#norm} -gt ${#best_mp} ]; then
        best_mp="$norm"
        best_type="$(printf '%s' "$line" | sed -n 's/.*(\([^)]*\).*/\1/p' | cut -d, -f1)"
      fi
    fi
  done < <(mount)
  printf '%s' "$best_type"
}

# DMG 是 HFS+ 镜像：只有 APFS/HFS/UFS 能直写，其余（ExFAT/FAT/tmpfs）需先落 /tmp
can_write_dmg_direct() {
  case "${1:-}" in
    apfs|hfs|ufs) return 0 ;;
    *) return 1 ;;
  esac
}

case "$MODE" in
  dmg)
    [ -n "$OUT" ] || OUT="$SCRIPT_DIR/${APP_NAME}-${VER}.dmg"
    OUTDIR="$(dirname "$OUT")"
    if [ ! -d "$OUTDIR" ]; then
      echo "✗ 输出目录不存在：$OUTDIR"
      exit 1
    fi
    FSTYPE="$(fs_type_of "$OUTDIR")"
    TMPDMG=""
    if can_write_dmg_direct "$FSTYPE"; then
      echo "· 目标文件系统：${FSTYPE}（可直写 dmg）"
    else
      TMPDMG="${TMPDIR:-/tmp}/${APP_NAME}-${VER}.dmg"
      echo "· 目标文件系统：${FSTYPE:-未知}（dmg 需先在 /tmp 生成，成功后再移入）"
    fi
    # staging：把 App 复制到 /tmp(APFS) 再打包。
    # hdiutil 的 -srcfolder 源在 ExFAT 外接盘会被拒（「操作不被允许」，本机实测，
    # 输出位置改到 /tmp 也一样失败）；源必须在 APFS——参考脚本
    # /Volumes/Toshiba/Deepseek/CME_UF8/cme-uf8-router/make-dmg.sh 即此模式（源在 /tmp staging）。
    STAGE_DIR="${TMPDIR:-/tmp}/${APP_NAME}-dmg-staging"
    run rm -rf "$STAGE_DIR"
    run mkdir -p "$STAGE_DIR"
    run cp -R "$APP_PATH" "$STAGE_DIR/"
    STAGE="$STAGE_DIR"
    # 若目标 dmg 正被挂载，先卸载，避免冲突
    DEV="$(hdiutil info "$OUT" 2>/dev/null | grep -E '^/dev/' | head -1 || true)"
    if [ -n "$DEV" ]; then
      run hdiutil detach "$DEV" -force
    fi
    if [ -n "$TMPDMG" ]; then
      run hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov "$TMPDMG"
      if [ "$DRY" -eq 1 ]; then
        echo "（dry-run）将先在 /tmp 生成，再移入：$OUT"
      else
        mv "$TMPDMG" "$OUT"
        echo "✅ 完成：$OUT"
      fi
    else
      run hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov "$OUT"
      if [ "$DRY" -eq 1 ]; then
        echo "（dry-run）将生成：$OUT"
      else
        echo "✅ 完成：$OUT"
      fi
    fi
    ;;

  pkg)
    [ -n "$OUT" ] || OUT="$SCRIPT_DIR/${APP_NAME}-${VER}.pkg"
    OUTDIR="$(dirname "$OUT")"
    if [ ! -d "$OUTDIR" ]; then
      echo "✗ 输出目录不存在：$OUTDIR"
      exit 1
    fi
    IDENT="com.huahua.blemidiconnect"
    run pkgbuild \
      --root "$APP_PATH" \
      --identifier "$IDENT" \
      --version "$VER" \
      --install-location /Applications \
      "$OUT"
    if [ "$DRY" -eq 1 ]; then
      echo "（dry-run）将生成：$OUT"
    else
      echo "✅ 完成：$OUT"
      echo "  （pkg 未签名，双击安装时系统会有「未验证开发者」提示，属正常）"
    fi
    ;;
esac

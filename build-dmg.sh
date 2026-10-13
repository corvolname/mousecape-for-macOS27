#!/bin/bash
# build-dmg.sh —— 把一个 .app 打成可分发 DMG（含"拖到 Applications"安装布局）
# ---------------------------------------------------------------------------
# 【为什么用它而不是 create-dmg】本机没有 create-dmg，也不必装：
#   hdiutil 是系统自带，做"可读写临时 dmg → 布置布局 → 转压缩只读 dmg"这套标准流程足够。
#
# 【DMG 内布局】
#   Mousecape.app            ← 待安装
#   Applications -> /Applications   （symlink，方便拖放）
#   安装说明.txt              ← ★必须：本 App 是 **ad-hoc 签名**，首次打开会被 Gatekeeper 拦，
#                             说明里给出右键打开 / 去 quarantine 的具体做法
#
# 【用法】
#   bash build-dmg.sh <app 路径> [输出 dmg 路径]
set -euo pipefail

APP="${1:?用法: bash build-dmg.sh <app 路径> [输出 dmg 路径]}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
[ -d "$APP" ] || { echo "  ✗ 找不到 app: $APP" >&2; exit 2; }
APPNAME="$(basename "$APP" .app)"
# ★版本必须在"生成安装说明"之前取到（早先放在后面 ⇒ sed 用到时 unbound）
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
OUT="${2:-$(dirname "$APP")/${APPNAME}.dmg}"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
STAGE="$(mktemp -d)"
TMP_DMG="$(mktemp -u).dmg"
MOUNT="/Volumes/${APPNAME}_dmg_build_$$"

cleanup() {
  hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  rm -rf "$STAGE" "$TMP_DMG" 2>/dev/null || true
}
trap cleanup EXIT

echo "  源 App : $APP"
echo "  输出   : $OUT"

# ── 1. 暂存：复制 App + Applications 软链 + 安装说明 ──────────
echo "  [1/4] 准备暂存目录"
cp -Rp "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# ★安装说明与一键安装脚本：放在 dist-files/ 里作为**独立文件**维护，
#   由本脚本复制进 DMG。
#   ★★为什么不内联 heredoc：脚本里的 `$(...)`、反引号会在**本脚本**解析时被提前展开
#     （实测踩过：helper 里的 $(basename ...) 被外层执行 ⇒ "command not found"）。
DRY_SRC="$(cd "$(dirname "$0")" && pwd)/dist-files"
[ -d "$DRY_SRC" ] || { echo "  ✗ 找不到 dist-files/ 目录" >&2; exit 2; }

# 安装说明：模板里替换 App 名与版本
sed -e "s/@APPNAME@/${APPNAME}/g" -e "s/@VER@/${VER}/g" \
    "$DRY_SRC/安装说明.txt.in" > "$STAGE/安装说明.txt"

# 一键安装脚本：直接复制并确保可执行
cp -p "$DRY_SRC/一键安装.command" "$STAGE/一键安装.command"
chmod +x "$STAGE/一键安装.command"

# ── 2. 建可读写 DMG 并挂载 ──────────────────────────────────
echo "  [2/4] 创建并挂载临时 DMG"
SIZE_KB=$(( $(du -sk "$STAGE" | awk '{print $1}') + 20480 ))   # 留 20MB 余量
hdiutil create -srcfolder "$STAGE" -volname "${APPNAME} ${VER}" \
        -fs HFS+ -format UDRW -size "${SIZE_KB}k" "$TMP_DMG" -quiet
hdiutil attach "$TMP_DMG" -mountpoint "$MOUNT" -nobrowse -quiet

# ── 3. 用 Finder 摆好图标位置（无背景图，只定位置与视图）──────
echo "  [3/4] 设置窗口布局"
osascript <<OSA 2>/dev/null || echo "        （跳过 Finder 布局：无图形会话时属正常）"
tell application "Finder"
  tell disk "${APPNAME} ${VER}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 140, 800, 520}
    set vo to the icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to 128
    set position of item "${APPNAME}.app" of container window to {170, 190}
    set position of item "Applications" of container window to {450, 190}
    set position of item "安装说明.txt" of container window to {310, 340}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
OSA
sync

# ── 4. 卸载 → 转压缩只读 DMG ─────────────────────────────────
echo "  [4/4] 转为压缩只读 DMG"
hdiutil detach "$MOUNT" -quiet
rm -f "$OUT"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet

echo
echo "  ✅ 完成: $OUT"
ls -la "$OUT" | awk '{printf "     体积: %.1f MB\n", $5/1048576}'
echo "     校验: $(shasum -a 256 "$OUT" | cut -c1-32)…"

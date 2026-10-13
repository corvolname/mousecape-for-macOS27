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

# ★安装说明：ad-hoc 签名会被 Gatekeeper 拦，必须写清怎么打开
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
cat > "$STAGE/安装说明.txt" <<EOF
${APPNAME} ${VER} — macOS 26 / 27 适配版

【安装】
  把左侧的 ${APPNAME}.app 拖到右侧的 Applications 文件夹。

【★首次打开会被拦住 —— 这是正常的】
  本 App 为了让鼠标指针主题在 macOS 26/27 上真正生效，替换了内部的 mousecloak
  命令行组件，因此**只能用临时签名（ad-hoc）重新签名**，不再是苹果公证版本。
  ⇒ 首次打开时 macOS 会提示"无法验证开发者"或"已损坏"，请任选一种方式：

  方式一（推荐）：在 Applications 里 **右键点 App → 打开 → 再点"打开"**。
                 只需做一次，之后双击即可正常启动。

  方式二（命令行，一次性）：
      xattr -dr com.apple.quarantine "/Applications/${APPNAME}.app"

【为什么需要这个适配版】
  自 macOS 26 起，系统改从新名字绘制「箭头」和「I 型文字光标」
  （com.apple.coregraphics.ArrowS / .IBeamS）。
  原版 Mousecape 只注册旧名字，虽然报告 "Applied successfully"，
  但箭头和文字光标**不会改变**。本版会在新旧两个名字上同时注册，
  并在注册后**回读校验**（因为"返回成功"在 macOS 26/27 上不再等于生效）。

【已知限制】
  · 特权辅助工具（负责"登录时自动重新应用"）仍是旧逻辑。若未在 App 里执行过
    "Install Helper Tool"，则无影响。
  · 若你从旧版本升级：建议先在旧版里点一次 Reset，再装本版。

【上游与许可】
  基于 alexzielenski/Mousecape（含 PR #308 的实现）。
  上游许可证含"仅限个人非商业用途"条款 —— 请勿用于商业目的。
  源码与完整说明：https://github.com/corvolname/mousecape-for-macOS27
EOF

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

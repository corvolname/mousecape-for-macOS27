#!/bin/bash
# install-into-app.sh —— 把修复后的 mousecloak 装进 Mousecape.app（就地替换 + 备份）
# ---------------------------------------------------------------------------
# 【它改什么】只替换 `Mousecape.app/Contents/MacOS/mousecloak` 这一个命令行二进制，
#   即"应用 cape 时真正去注册指针"的那段逻辑。**不动** GUI 二进制、nib、Sparkle、辅助工具。
#
# 【为什么这样最安全】
#   · 原 App 的 GUI 在 macOS 27 上本身没问题（已公证、无崩溃），失效的只是指针注册逻辑。
#   · 替换后需要**重新签名**（原为 Developer ID + 公证，改一个字节签名即失效）。
#     这里用 ad-hoc 签名保证本机能跑；★代价：App 不再是"公证"状态，
#     首次打开若被 Gatekeeper 拦，右键→打开，或执行：
#         xattr -dr com.apple.quarantine "<app 路径>"
#
# 【用法】
#   bash install-into-app.sh                      # 就地改 /Applications/Mousecape.app（或其唯一副本）
#   bash install-into-app.sh /path/to/Mousecape.app
#   DRY=1 bash install-into-app.sh                # 只显示将做什么
#
# 【回滚】替换前会把原二进制备份为同目录 `mousecloak.orig-<时间戳>`；
#   恢复：cp mousecloak.orig-<时间戳> mousecloak && codesign --force --sign - <该文件>
#   ★更彻底的回滚：用安装前复制出来的 .app 副本覆盖回去。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NEW="$HERE/build/mousecloak"
DRY="${DRY:-0}"

# ── 1. 定位目标 App ─────────────────────────────────────────
APP="${1:-}"
if [ -z "$APP" ]; then
  for c in "/Applications/Mousecape.app" "$HOME/Applications/Mousecape.app" \
           "/Users/corvolname/Downloads/Mousecape.app" "/Users/corvolname/Downloads/Mousecape-2.app"; do
    [ -d "$c" ] && { APP="$c"; break; }
  done
fi
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "  找不到 Mousecape.app。请显式指定：bash install-into-app.sh /path/to/Mousecape.app" >&2
  exit 2
fi
TARGET="$APP/Contents/MacOS/mousecloak"
echo "  目标 App : $APP"
echo "  目标文件 : $TARGET"

# ── 2. 前置检查 ─────────────────────────────────────────────
[ -f "$TARGET" ] || { echo "  ✗ 该 App 内没有 Contents/MacOS/mousecloak" >&2; exit 2; }
if [ ! -x "$NEW" ]; then
  echo "  构建修复版 mousecloak ..."
  bash "$HERE/build-mousecloak.sh" >/dev/null 2>&1 || { echo "  ✗ 构建失败，请先跑 build-mousecloak.sh 看错误" >&2; exit 2; }
fi
echo "  修复版架构: $(lipo -archs "$NEW" 2>/dev/null || echo '?')"
echo "  原版架构  : $(lipo -archs "$TARGET" 2>/dev/null || echo '?')"

# 已经装过就不再重复
if cmp -s "$NEW" "$TARGET"; then
  echo "  = 目标已是修复版，无需替换。"
  exit 0
fi

# ── 3. 备份 + 替换 + 签名 ───────────────────────────────────
TS="$(date +%Y%m%d-%H%M%S)"
BAK="$TARGET.orig-$TS"
if [ "$DRY" = "1" ]; then
  echo "  [DRY] 将备份 $TARGET -> $BAK"
  echo "  [DRY] 将复制 $NEW -> $TARGET"
  echo "  [DRY] 将对 $TARGET 执行 ad-hoc 签名"
  exit 0
fi

cp -p "$TARGET" "$BAK" || { echo "  ✗ 备份失败" >&2; exit 3; }
echo "  已备份 -> $(basename "$BAK")"
cp "$NEW" "$TARGET" || { echo "  ✗ 替换失败（已保留备份）" >&2; exit 3; }
chmod +x "$TARGET"

# ★★必须重签**整个 .app 包**，不能只签包内那一个文件。
#   实测（macOS 27.0.1）：改动包内任何文件后，外层包的签名即失效，
#   AppleSystemPolicy 会直接杀掉进程，只留一条内核日志：
#       ASP: Security policy would not allow process: <pid>, <app>/Contents/MacOS/mousecloak
#   表现为 `Killed: 9`（rc=137）、**毫无输出**，极易误判成"新二进制有 bug"。
codesign --remove-signature "$APP" 2>/dev/null
if codesign --force --deep --sign - "$APP" 2>/dev/null; then
  echo "  已对整个 .app 重签（ad-hoc）"
else
  echo "  ⚠ 包签名失败；请手动：codesign --force --deep --sign - \"$APP\""
fi

# ★另有一个坑：**未公证的 ad-hoc 包在 /tmp 等位置会被策略拒绝执行**（同样 rc=137）。
#   实测同一份包在 ~/Downloads 正常、在 /tmp 被杀 ⇒ 安装到常规位置。
case "$APP" in
  /tmp/*|/private/tmp/*|/var/folders/*)
    echo "  ⚠ 目标位于临时目录，macOS 策略可能拒绝执行（rc=137）。建议放到 ~/Applications 或 /Applications。" ;;
esac

# ── 4. 自检：用**装进去的那份**跑一次探测 ───────────────────
echo
echo "  自检（用 App 内的二进制，--probe）:"
probe_out="$("$TARGET" --probe 2>&1)"; probe_rc=$?
if [ "$probe_rc" -eq 137 ]; then
  echo "    [FAIL] 进程被系统策略杀掉（rc=137）——多为**位置问题**（临时目录）或包签名未生效。"
  echo "           请把 App 移到 ~/Applications 或 /Applications 后再试。"
elif printf '%s' "$probe_out" | grep -q "Every built-in cursor can be replaced"; then
  echo "    [OK] 本机允许替换全部内置指针"
else
  echo "    [注意] 探测未显示全部可替换，请人工确认："
  printf '%s\n' "$probe_out" | sed 's/^/      /'
fi

cat <<EOF

  ✅ 完成。接下来：
    1) 首次打开若被 Gatekeeper 拦：右键 -> 打开；或
         xattr -dr com.apple.quarantine "$APP"
    2) 打开 Mousecape -> 应用你的 cape
    3) 验证是否**真的生效**（别只看 "Applied successfully"）：
         "$HERE/build/cursor-state" --compare "<你的 cape 文件>"
       要看到 Arrow 一行显示 "一致（已生效）"

  ⚠ 已知残留：Contents/Library/LoginItems 里的**特权辅助工具**仍是旧逻辑，
    它负责"登录时自动重新应用"。你没执行 "Install Helper Tool" 的话不影响；
    若已安装且希望它也用新逻辑，需要重新构建与签名（需开发者证书），当前脚本不处理。
  ↩ 回滚：cp "$BAK" "$TARGET" && codesign --force --sign - "$TARGET"
EOF

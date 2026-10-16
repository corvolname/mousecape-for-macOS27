#!/bin/sh
# install-login-persistence.sh —— 让 Mousecape 的游标在**登录/重启后自动恢复**
# ---------------------------------------------------------------------------
# 【为什么需要它】2026-10-16 用户报「重启以后又失效了」。实测根因（不是补丁失效）：
#   1. 补丁本身**有效**：`mousecloak --apply <cape>` 后 Arrow/ArrowS 从 28x40 变 32x32 ✅
#   2. 但 Mousecape 的"跨重启保持"机制在 macOS 27 上**没跑起来**：
#      · 原设计：helper 登录项（`com.alexzielenski.mousecloakhelper`）在登录时启动，
#        跑 `mousecloak --listen`，在用户切换时重新应用当前 cape。
#      · 实测：该登录项**已注册且 enabled**（`sfltool dumpbtm` / `launchctl print` 均可证），
#        但 `active count = 0`、进程根本没起来（手工启动它则完全正常 ⇒ 不是崩溃，是没被启动）。
#        同时主 app 自身的登录项 Disposition = **disabled**。
#      ⇒ 我们的构建是 **ad-hoc 签名（TeamIdentifier=not set）**，而 BTM 里记的开发者是
#        原作者的 Team ID（3GD8ABJ22W）⇒ 登录项在启动时的签名校验环节被拦下。
#   3. 另外 `appliedCape` 是 **weak 属性**（不持久化）⇒ 主程序重启也不会自己恢复。
#      ⇒ 结论：**必须有一条在登录时可靠执行的路径**把 cape 重新 apply 一次。
#
# 【本脚本做什么】装一个**用户 LaunchAgent**（`RunAtLoad`），登录时执行
#   `mousecloak --apply <cape>`。用户 LaunchAgent 走 legacy 登录项通道，
#   **不经** SMLoginItemSetEnabled 的签名校验，因此 ad-hoc 签名也能可靠执行（已实测）。
#
# 【用法】
#   sh install-login-persistence.sh                 # 用最近修改的 cape
#   sh install-login-persistence.sh <cape 路径>      # 指定 cape
#   sh install-login-persistence.sh --uninstall     # 卸载（恢复原状）
#
# 【实测证据】（2026-10-16）
#   mousecloak --reset          ⇒ Arrow/ArrowS 28x40（系统默认）
#   launchctl bootstrap <plist> ⇒ Arrow/ArrowS 32x32（主题自动恢复）✅
#   launchctl print             ⇒ runs=1, last exit code = 0, properties = runatload
set -eu

LABEL="local.corvolname.mousecape-cursor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
MOUSECLOAK="/Applications/Mousecape.app/Contents/MacOS/mousecloak"
CAPE_DIR="$HOME/Library/Application Support/Mousecape/capes"

# ---------- 卸载 ----------
if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "已卸载：$LABEL"
  echo "（游标仍是当前已应用的那套；若要恢复系统默认，跑："
  echo "  \"$MOUSECLOAK\" --reset ）"
  exit 0
fi

# ---------- 前置检查 ----------
[ -x "$MOUSECLOAK" ] || { echo "找不到 mousecloak：$MOUSECLOAK" >&2; exit 1; }
CAPE="${1:-}"
if [ -z "$CAPE" ]; then
  # 取最近修改的 cape 作为默认（通常就是当前在用的那套）
  CAPE=$(ls -t "$CAPE_DIR"/*.cape 2>/dev/null | head -1 || true)
fi
if [ -z "$CAPE" ] || [ ! -f "$CAPE" ]; then
  echo "找不到 cape。用：sh $0 <cape 路径>" >&2
  echo "现有 cape：" >&2
  ls -1 "$CAPE_DIR" 2>/dev/null | sed 's/^/  /' >&2
  exit 1
fi
echo "使用 cape：$CAPE"

# ---------- 写 LaunchAgent ----------
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$MOUSECLOAK</string>
    <string>--apply</string>
    <string>$CAPE</string>
  </array>
  <!-- ★登录时执行一次即可：cape 一旦注册进 WindowServer 就会一直有效，
       直到下次登录/重启（那正是我们要覆盖的场景）。 -->
  <key>RunAtLoad</key><true/>
  <!-- 需要连 WindowServer：标成 Interactive，避免被当作后台任务节流。 -->
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLISTEOF

plutil -lint "$PLIST" >/dev/null || { echo "plist 校验失败" >&2; exit 1; }

# ---------- 加载（同时立即生效一次，等于预演登录时的行为）----------
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "已安装：$PLIST"
echo "等 2 秒验证…"
sleep 2
launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E "state|last exit|runs|properties" | sed 's/^/  /' || true
echo
echo "若上面 last exit code = 0 且 runs >= 1，则登录时自动应用已生效。"
echo "卸载：sh $0 --uninstall"

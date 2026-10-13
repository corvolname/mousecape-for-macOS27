#!/bin/bash
# 一键安装：把本 App 装到「应用程序」文件夹，并处理干净
#   · 复制到 /Applications（启动台只认这几个位置：/Applications、~/Applications）
#   · 去掉隔离标记（否则首次打开会被 Gatekeeper 拦）
#   · 重建 Spotlight 索引 + 注册到 Launch Services（否则可能不被识别为 App，启动台不显示）
#   · 刷新启动台
set -uo pipefail
cd "$(dirname "$0")" || exit 1

APP="$(ls -d ./*.app 2>/dev/null | head -1)"
if [ -z "$APP" ]; then
  echo "✗ 当前目录里找不到 .app"
  read -r -p "按回车关闭"
  exit 1
fi
NAME="$(basename "$APP")"
DEST="/Applications/$NAME"

echo "== 安装 $NAME =="
echo "   来源: $PWD/$NAME"
echo "   目标: $DEST"
echo

# 已存在则先改名备份，绝不直接删
if [ -e "$DEST" ]; then
  STAMP="$(date +%Y%m%d-%H%M%S)"
  BAK="/Applications/${NAME%.app}-old-$STAMP.app"
  echo "· 发现同名 App，先改名为备份：$(basename "$BAK")"
  if ! mv "$DEST" "$BAK"; then
    echo "✗ 改名失败（可能需要管理员权限：用 sudo 运行本脚本）"
    read -r -p "按回车关闭"
    exit 1
  fi
fi

echo "· 复制到应用程序文件夹..."
if ! cp -Rp "$APP" "$DEST"; then
  echo "✗ 复制失败（可能需要管理员权限：sudo bash 本脚本）"
  read -r -p "按回车关闭"
  exit 1
fi

echo "· 去除隔离标记..."
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null

echo "· 重建 Spotlight 索引（关键：否则可能被当成普通文件夹，启动台不显示）..."
mdimport -r "$DEST" 2>/dev/null

echo "· 注册到 Launch Services..."
LSR="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSR" ]; then
  "$LSR" -f "$DEST" 2>/dev/null
fi

echo "· 刷新启动台..."
killall Dock 2>/dev/null

echo
echo "✅ 完成！请在「启动台」或「应用程序」文件夹里打开 $NAME"
echo "   （首次打开如被拦：右键点它 → 打开 → 再点打开）"
echo
read -r -p "按回车关闭此窗口"

#!/bin/bash
# build-gui.sh —— 在只有 Command Line Tools（无 Xcode）的机器上重新编译 Mousecape 的 **GUI 二进制**
# ---------------------------------------------------------------------------
# 【为什么需要它】2026-10-16：用户要求把"登录项持久化"**内置进 app**
#   （「安装 app 应用，并在菜单栏里的 install helper tool 后，以后不管怎么重启都不再失效」）。
#   · `mousecloak`（命令行二进制）我们早已能重建（见 build-mousecloak.sh）。
#   · 但 "Install Helper Tool" 菜单项在 **GUI 二进制**里（MCAppDelegate.m 的 toggleInstall:）
#     ⇒ 要改它就必须重编 GUI。而 `xcodebuild` 在本机**不可用**（需要完整 Xcode）。
#
# 【可行性依据（都已实测/核对）】
#   · 26 个 .m，约 3819 行，全部只依赖系统框架 + 一个**弱依赖** Sparkle。
#   · Sparkle 只在 **MainMenu.xib** 里以 `customClass="SUUpdater"` 出现，**不是编译期符号**；
#     `nm -u` 现有二进制里 Sparkle 符号为 **0 个** ⇒ 源码不 import Sparkle ⇒ 可以不链接它
#     （xib 里的类名找不到只会静默失效，不影响其它功能）。
#   · nib（Library/MainMenu/Edit/…）**不需要重编**：app 里已有 2020 年编译好的 nib，
#     且它们引用的是既有类名，我们只是替换二进制 ⇒ nib 原样复用。
#     （本机也没有 ibtool。）
#   · 工程设置：Mousecape target 用 **CLANG_ENABLE_OBJC_ARC = YES**（与 mousecloak 相反！），
#     GCC_PREFIX_HEADER = Mousecape/Mousecape-Prefix.pch。
#
# 【用法】
#   bash build-gui.sh                      # 输出到 build/Mousecape
#   bash build-gui.sh /tmp/out/Mousecape   # 指定输出
#
# 【注意】产物是 **universal（arm64 + x86_64）**，与原 app 的 x86_64 保持兼容。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/Mousecape"
OUT="${1:-$HERE/build/Mousecape}"
OBJ="$(mktemp -d)"
SDK="$(xcrun --show-sdk-path)"
trap 'rm -rf "$OBJ"' EXIT

ARCHS=(arm64 x86_64)
MIN=12.0        # 原工程是 10.13，Xcode 27 的 SDK 不接受；统一 12.0（与 mousecloak 一致）

# 框架搜索路径：Sparkle 若在 app bundle 里就弱链接（保持 load command 与原版一致）
APP="${MOUSECAPE_APP:-/Applications/Mousecape.app}"
SPARKLE_DIR="$APP/Contents/Frameworks"

build_arch() {           # $1=arch $2=输出目录
  local arch="$1" objdir="$2"
  mkdir -p "$objdir"
  # ★把所有子目录都加入 include 路径：GUI 源码散布在 src/{models,controllers,views,categories,...}
  # ★数组 + `set -u` 安全展开："${incs[@]+"${incs[@]}"}"（空数组在 bash 3.2 + set -u 下会报错）
  local incs=()
  while IFS= read -r d; do incs+=(-I "$d"); done < <(find "$SRC" -type d | sort)
  local common=(-isysroot "$SDK" -mmacosx-version-min=$MIN -arch "$arch" -O2
                -fobjc-arc
                "${incs[@]+"${incs[@]}"}"
                -I "$SRC"
                -I "$SRC/src"
                -I "$SRC/external"
                # ★GUI 复用 mousecloak 的游标模型/定义（MCDefs.h 会 #import "CGSCursor.h"）
                -I "$HERE/src/shared"
                -I "$HERE/src/mousecloak"
                -I "$HERE/src/mousecloak/CGSInternal"
                -I "$HERE/src/mousecloak/vendor"
                -Wno-deprecated-declarations -Wno-objc-method-access -Wno-unguarded-availability)
  # ★用绝对路径列表，避免子目录里的同名文件冲突
  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(find "$SRC" -name '*.m' | sort)
  # ★共用实现（登录项持久化）——GUI 也要用它，见 src/shared/loginitem.m
  while IFS= read -r f; do files+=("$f"); done < <(find "$HERE/src/shared" -name '*.m' | sort)
  # ★GUI 直接调用 mousecloak 的实现函数（applyCapeAtPath / restoreAllCursors / setCursorScale ...）
  #   ⇒ 必须把 mousecloak 的这些 .m 也编进来。排除 main.m（有 int main，会与 GUI 的冲突）。
  for f in "$HERE/src/mousecloak"/*.m; do
    [ "$(basename "$f")" = "main.m" ] && continue
    files+=("$f")
  done
  local i=0
  for f in "${files[@]}"; do
    i=$((i+1))
    # ★工程里是**逐文件覆盖 ARC**：Mousecape target 全局 ARC=YES，
    #   但这几个文件在 Xcode 里显式标了 COMPILER_FLAGS = "-fno-objc-arc"（它们是老的手动内存管理代码）。
    #   在别处再逐个补（例如 RBLClipView）成本高，所以这里按**文件名黑名单**判定。
    # 用**字符串**而非数组：macOS 自带 bash 3.2 + set -u 下空数组会报 unbound variable
    local extra=()
    case "$(basename "$f")" in
      NSColor+RBLCGColorAdditions.m|NSOrderedSet+AZSortedInsert.m|RBLScrollView.m)
        extra=(-fno-objc-arc) ;;
    esac
    # mousecloak 本体全是手动内存管理（工程里也是 -fno-objc-arc）
    case "$f" in
      */src/mousecloak/*) extra=(-fno-objc-arc) ;;
    esac
    clang -c "${common[@]}" "${extra[@]+"${extra[@]}"}" -include "$SRC/Mousecape-Prefix.pch" "$f" -o "$objdir/o$i.o" || {
      echo "  !! 编译失败: ${f#$SRC/}" >&2; return 1; }
  done
  local link=(-arch "$arch" -mmacosx-version-min=$MIN -isysroot "$SDK" -o "$objdir/Mousecape.$arch" "$objdir"/*.o
              -framework Cocoa -framework QuartzCore -framework Security
              -framework ServiceManagement -framework SystemConfiguration
              -framework ApplicationServices
              -Wl,-rpath,@executable_path/../Frameworks)
  # Sparkle：**弱链接**（源码不引用它，但保持与原版一致的 @rpath 记录）
  if [ -d "$SPARKLE_DIR/Sparkle.framework" ]; then
    link+=(-F "$SPARKLE_DIR" -weak_framework Sparkle)
  fi
  clang "${link[@]}" || return 1
}

# ★2026-10-16：把内置 cape 打进 app（Contents/Resources/capes）——
#   `build-gui.sh` 只产出裸二进制，资源由这里准备；install-into-app.sh 负责最终拷进 .app。
CAPES_SRC="$HERE/src/capes"
if [ -d "$CAPES_SRC" ]; then
  echo "  内置 cape: $(ls -1 "$CAPES_SRC"/*.cape 2>/dev/null | wc -l | tr -d ' ') 套 ($(ls -1 "$CAPES_SRC" 2>/dev/null | tr '\n' ' '))"
fi

mkdir -p "$(dirname "$OUT")"
slices=()
for a in "${ARCHS[@]}"; do
  echo "  [编译] $a"
  build_arch "$a" "$OBJ/$a" || { echo "  !! $a 构建失败"; exit 1; }
  slices+=("$OBJ/$a/Mousecape.$a")
done
echo "  [合并] universal"
lipo -create "${slices[@]}" -output "$OUT"
lipo -archs "$OUT" | sed 's/^/  架构: /'
echo "  ✅ $OUT"

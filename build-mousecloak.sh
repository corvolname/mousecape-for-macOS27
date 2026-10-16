#!/bin/bash
# build-mousecloak.sh —— 在 macOS 27（26A434+）上构建 mousecloak CLI（arm64 原生）
# ---------------------------------------------------------------------------
# 为什么需要这个脚本：原工程只能用 Xcode 构建，而本机只有 Command Line Tools
#   （xcodebuild 不可用）。这里用 clang 直接编译，严格照 Xcode 工程里的设置：
#     · CLANG_ENABLE_OBJC_ARC = NO      → mousecloak 源码是手动内存管理（retain/autorelease）
#     · GCC_PREFIX_HEADER                → mousecloak-Prefix.pch 提供 Foundation/Cocoa
#     · MACOSX_DEPLOYMENT_TARGET         → 原为 10.13，Xcode 27 不接受，这里用 12.0
#   GBCli（vendor/）用 __weak，必须单独以 ARC 编译后链接。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/mousecloak"
OUT="${1:-$HERE/build/mousecloak}"
OBJ="$(mktemp -d)"
SDK="$(xcrun --show-sdk-path)"
trap 'rm -rf "$OBJ"' EXIT

# ★构建 universal（arm64 + x86_64）：原 App 是 x86_64 且已公证，
#   只出 arm64 会丢掉 Intel 兼容性（别人拿到就废）。
#   Xcode 27 只接受 12.0~27.0，故统一用 12.0。
ARCHS=(arm64 x86_64)
MIN=12.0

build_arch() {           # $1=arch  $2=输出目录
  local arch="$1" objdir="$2"
  mkdir -p "$objdir"
  local common=(-isysroot "$SDK" -mmacosx-version-min=$MIN -arch "$arch" -O2
                -I "$SRC" -I "$SRC/CGSInternal" -I "$SRC/vendor"
                -I "$HERE/src/shared"   # ★内置 cape / 登录项共用实现（GUI 与 mousecloak 共用）
                -Wno-deprecated-declarations -Wno-objc-method-access -Wno-unguarded-availability)
  # GBCli 用 __weak ⇒ 必须 ARC；mousecloak 本体是手动内存管理 ⇒ 非 ARC（照 Xcode 设置）
  for f in "$SRC"/vendor/GBCli/*.m; do
    clang -c -fobjc-arc -include "$SRC/mousecloak-Prefix.pch" "${common[@]}" "$f" -o "$objdir/gb_$(basename "${f%.m}").o" || return 1
  done
  for f in "$SRC"/*.m; do
    clang -c "${common[@]}" -include "$SRC/mousecloak-Prefix.pch" "$f" -o "$objdir/mc_$(basename "${f%.m}").o" || return 1
  done
  # ★2026-10-16：与 GUI 共用的"登录项持久化"实现（src/shared/loginitem.m）
  local SHARED="$HERE/src/shared"
  for f in "$SHARED"/*.m; do
    [ -e "$f" ] || continue
    clang -c "${common[@]}" -I "$SHARED" -include "$SRC/mousecloak-Prefix.pch" "$f" -o "$objdir/sh_$(basename "${f%.m}").o" || return 1
  done
  clang -arch "$arch" -mmacosx-version-min=$MIN -isysroot "$SDK" -o "$objdir/mousecloak.$arch" "$objdir"/*.o \
    -framework Cocoa -framework SystemConfiguration -framework ApplicationServices || return 1
}

mkdir -p "$(dirname "$OUT")"
slices=()
for a in "${ARCHS[@]}"; do
  echo "  [编译] $a"
  build_arch "$a" "$OBJ/$a" || { echo "  !! $a 编译失败"; exit 1; }
  slices+=("$OBJ/$a/mousecloak.$a")
done
echo "  [合并] universal"
lipo -create "${slices[@]}" -output "$OUT"
lipo -archs "$OUT" | sed 's/^/  架构: /'
echo "  ✅ $OUT"

#!/bin/bash
# run-verify.sh —— 一键验证：本工程构建的 mousecloak 是否真能在本机 macOS 上换掉鼠标指针
# ---------------------------------------------------------------------------
# 【为什么需要】
#   macOS 26/27 上 `CGSRegisterCursorWithImages` 对某些名字会**返回成功但静默忽略**
#   （`com.apple.coregraphics.Arrow` / `.IBeam` 就是这样，系统改从 `ArrowS` / `IBeamS` 绘制）。
#   ⇒ 只看 mousecloak 打印的 "Applied successfully" 会被骗；
#     必须把指针**读回来**与 cape 定义逐像素比对，才有判别力。
#
# 【做五件事】
#   0. 构建 mousecloak 与只读探测工具 cursor-state
#   1. --probe：本机允许替换哪些内置指针
#   2. 基线：--reset 后 Arrow 应是**系统默认**（证明比对方法有判别力）
#   3. 应用：本工程构建版应用 cape → 逐像素比对 + 别名一致性
#   4. A/B 对照：改用原版旧 mousecloak 再跑一遍（预期箭头**不生效**，复现缺陷）
#   5. 复位：重置回系统默认
#
# 【用法】bash run-verify.sh [cape 文件]
#   ★会实际改动当前鼠标指针；脚本结束前会复位。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CAPE="${1:-$HERE/src/com.maxrudberg.svanslosbluehazard.cape}"
NEW="$HERE/build/mousecloak"
STATE="$HERE/build/cursor-state"
OLD="/Users/corvolname/Downloads/Mousecape-2.app/Contents/MacOS/mousecloak"

pass=0; fail=0
ok()  { printf '  [OK]   %s\n' "$1"; pass=$((pass+1)); }
no()  { printf '  [FAIL] %s  %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
hr()  { printf '\n======== %s ========\n' "$1"; }

# 只从 cursor-state 的结果表里取值。
# ★踩过的坑：用宽松的 grep 'Arrow' 会命中工具末尾的提示文字
#   （"…Arrow 与 ArrowS 会返回同一份…"）⇒ 把提示当结果，判定假红。
#   ⇒ 一律按"行首就是该名字"精确匹配（$1==n）。
syssize() { "$STATE" --name "$1" 2>/dev/null | awk -v n="$1" '$1==n {print $2; exit}'; }
capline() { awk -v n="$1" '$1==n {print; exit}'; }

# ── 0. 准备 ─────────────────────────────────────────────────
hr "0. 构建/准备工具"
if [ ! -x "$NEW" ]; then bash "$HERE/build-mousecloak.sh" >/dev/null 2>&1; fi
if [ ! -x "$STATE" ]; then
  clang -fobjc-arc -framework Foundation -framework AppKit -o "$STATE" "$HERE/tools/cursor-state.m" 2>/dev/null
fi
[ -x "$NEW" ]   && ok "mousecloak 已构建"            || { no "mousecloak 构建失败"; exit 2; }
[ -x "$STATE" ] && ok "cursor-state 已构建（只读）"    || { no "cursor-state 构建失败"; exit 2; }
[ -f "$CAPE" ]  && ok "测试 cape：$(basename "$CAPE")" || { no "找不到 cape：$CAPE"; exit 2; }

# ── 1. 可替换性 ─────────────────────────────────────────────
hr "1. 系统与可替换性"
sw_vers 2>/dev/null | sed 's/^/    /'
probe="$("$NEW" --probe 2>&1)"
if printf '%s' "$probe" | grep -q "Every built-in cursor can be replaced"; then
  ok "本机允许替换全部内置指针"
else
  no "有内置指针不可替换" "$(printf '%s' "$probe" | grep -iE 'refus|not.*replace' | head -2 | tr '\n' ' ')"
fi
if printf '%s' "$probe" | grep -q "ArrowS"; then
  ok "别名 ArrowS 已出现在探测结果里（macOS 26+ 的关键）"
else
  no "探测结果里没有 ArrowS"
fi

# ── 2. 基线 ─────────────────────────────────────────────────
hr "2. 基线（--reset 后）"
"$NEW" --reset >/dev/null 2>&1
base_arrow="$(syssize com.apple.coregraphics.Arrow)"
base_line="$("$STATE" --compare "$CAPE" 2>/dev/null | capline com.apple.coregraphics.Arrow)"
printf '    Arrow 系统值: %s\n    %s\n' "${base_arrow:-未知}" "${base_line:-（未取到）}"
if printf '%s' "$base_line" | grep -q "不同"; then
  ok "基线干净：Reset 后 Arrow 与 cape 不同 => 比对方法有判别力"
else
  no "基线可疑：Reset 后 Arrow 仍等于 cape（比对可能失效）"
fi

# ── 3. 应用 ─────────────────────────────────────────────────
hr "3. 本工程构建版 —— 应用 cape"
"$NEW" --apply "$CAPE" 2>&1 | tail -2 | sed 's/^/    /'
out="$("$STATE" --compare "$CAPE" 2>/dev/null)"
printf '%s\n' "$out" | sed 's/^/  /'
new_line="$(printf '%s' "$out" | capline com.apple.coregraphics.Arrow)"
if printf '%s' "$new_line" | grep -q "一致"; then
  ok "Arrow 已按 cape 生效（别名修复有效）"
else
  no "Arrow 未生效" "$new_line"
fi
if printf '%s' "$out" | grep -qE "不同 0"; then
  ok "cape 内所有指针均已生效"
else
  no "仍有指针未生效"
fi
a="$(syssize com.apple.coregraphics.Arrow)"
b="$(syssize com.apple.coregraphics.ArrowS)"
if [ -n "$a" ] && [ "$a" = "$b" ]; then
  ok "Arrow 与 ArrowS 同值(${a})=> 系统按别名绘制，已同步"
else
  no "Arrow(${a:-空}) 与 ArrowS(${b:-空}) 不一致"
fi

# ── 4. A/B 对照 ─────────────────────────────────────────────
hr "4. A/B 对照 —— 原版旧 mousecloak"
if [ -x "$OLD" ]; then
  "$NEW" --reset >/dev/null 2>&1
  "$OLD" --apply "$CAPE" >/dev/null 2>&1
  oldout="$("$STATE" --compare "$CAPE" 2>/dev/null)"
  old_line="$(printf '%s' "$oldout" | capline com.apple.coregraphics.Arrow)"
  printf '    旧版应用后: %s\n    新版应用后: %s\n' "${old_line:-（未取到）}" "${new_line:-（未取到）}"
  if printf '%s' "$old_line" | grep -q "不同"; then
    ok "对照成立：旧版应用后 Arrow 仍是系统默认 => 复现了 macOS 26/27 的缺陷"
  else
    printf '  [SKIP] 旧版这次也生效了（本机不再复现，或该二进制已被替换过）\n'
  fi
else
  printf '  [SKIP] 未找到原版旧 mousecloak\n'
fi

# ── 5. 复位 ─────────────────────────────────────────────────
hr "5. 复位"
"$NEW" --reset >/dev/null 2>&1
rst="$(syssize com.apple.coregraphics.Arrow)"
printf '    重置后 Arrow 系统值: %s\n' "${rst:-未知}"
if [ -n "$rst" ] && [ "$rst" != "${a:-}" ]; then
  ok "已重置回系统默认(${a:-?} -> $rst)"
else
  no "重置后仍与 cape 相同" "${rst:-空}"
fi

hr "结论"
printf '  通过 %d   失败 %d\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
  printf '  => 本工程构建的 mousecloak 在 macOS %s 上可正常替换指针。\n' "$(sw_vers -productVersion)"
  exit 0
fi
printf '  => 有判据未通过，见上。\n'
exit 1

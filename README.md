# Mousecape · macOS 26 / 27 适配（逆向 + 重构建）

> 目标：让 [Mousecape](https://github.com/alexzielenski/Mousecape)（macOS 鼠标指针主题工具）
> 在 **macOS 27** 上真正能换掉指针。
>
> 本机实测环境：**macOS 27.0.1（Build 26A434，Apple Silicon）**

---

## 0 直接下载（不想自己编译就用这个）

### ⬇️ [Mousecape-macOS27.dmg](https://github.com/corvolname/mousecape-for-macOS27/releases/download/v1813-macos27/Mousecape-macOS27.dmg)

| 项 | 值 |
|---|---|
| 版本 | 1813（macOS 26/27 适配版）|
| 体积 | 4.1 MB |
| SHA-256 | `a385a0b2d4c0780f95fd51da86651787fba46af5eab0247b44b50d66f5db422c` |
| 要求 | macOS 12.0+（含 26 / 27）；universal（Apple Silicon + Intel）|
| 直达 Release | [v1813-macos27](https://github.com/corvolname/mousecape-for-macOS27/releases/tag/v1813-macos27) |

**安装**：打开 DMG → 把 App 拖到 Applications。

**★首次打开会被拦 —— 这是正常的**：为了让修复生效，必须替换 App 内部的
`mousecloak` 组件并**用临时签名（ad-hoc）重新签名**，因此不再是苹果公证版本。
任选一种方式打开（只需一次）：

```bash
# 方式一（推荐）：在 Applications 里「右键点 App → 打开 → 再点打开」
# 方式二（命令行）：
xattr -dr com.apple.quarantine "/Applications/Mousecape-2.app"
```

DMG 内附 `安装说明.txt`，同样内容。

**验证是否真的生效**（别只看 App 的 `Applied successfully`）：

```bash
# 先跑一次探测，确认本机允许替换
./build/mousecloak --probe

# 应用你的 cape 后，回读并与 cape 逐像素比对
./build/cursor-state --compare "你的.cape"
#   Arrow 一行必须显示「一致（已生效）」
```

### 校验下载完整性

```bash
shasum -a 256 ~/Downloads/Mousecape-macOS27.dmg
# 应输出：a385a0b2d4c0780f95fd51da86651787fba46af5eab0247b44b50d66f5db422c
```

### 更新机制

App 的 `SUFeedURL` 指向本仓库的 [`appcast.xml`](appcast.xml)（**已从上游改为本仓库**，
否则它会把本适配版"更新"成上游原版，等于把修复覆盖掉）。
发布新版本的做法写在 `appcast.xml` 顶部注释里。

---

## 1 结论先说

| 项 | 结论 |
|---|---|
| 原 App 能不能跑？ | **能** —— GUI 无崩溃、签名公证正常（`accepted / Notarized Developer ID`），x86_64 走 Rosetta |
| 真正失效的是什么？ | **指针注册逻辑**：应用 cape 后报告 `Applied successfully`，但**箭头 / I 型光标保持系统默认** |
| 根因 | macOS 26 起系统改从**新名字**绘制箭头与 I 型光标：`com.apple.coregraphics.ArrowS` / `.IBeamS` |
| 修法 | 应用 cape 时**把同一个指针同时注册到新旧两个名字**（别名）＋ **回读校验**（因为"返回成功"不再等于"生效"）|
| 现在状态 | mousecloak 已修好并**在 macOS 27 上实测生效**（arm64 与 x86_64 两个切片都验证过）|

**实测对照（本机跑出来的，不是推断）**：

```
重置后    Arrow: cape=20x24  sys=32x32   ✗ 未生效（系统默认）
原版应用  Arrow: cape=20x24  sys=32x32   ✗ 未生效   ← 报告成功，实际没换
新版应用  Arrow: cape=20x24  sys=20x24   ✅ 已生效   ← 逐像素与 cape 一致
```

---

## 2 为什么会失效：机制

`CGSRegisterCursorWithImages`（SkyLight 私有 API）在 macOS 26/27 上**对某些名字会返回
`kCGErrorSuccess` 但静默忽略**。实测矩阵：

| 名字 | 注册返回 | 是否真的生效 |
|---|---|---|
| `com.apple.coregraphics.Arrow` / `.IBeam` | `kCGErrorSuccess` | **否**（静默忽略）|
| **`com.apple.coregraphics.ArrowS` / `.IBeamS`** | `kCGErrorSuccess` | **是**（屏幕实际画的就是它）|
| 其他 `com.apple.coregraphics.*` | `kCGErrorSuccess` | 是 |
| `com.apple.cursor.N` | `kCGErrorSuccess` | 是 |

另一个坑：**回读 `Arrow` 得到的是 `ArrowS` 的内容**（两者同源）。所以
`cursor-state` 工具里会看到 `Arrow` 与 `ArrowS` 尺寸/签名完全一致 —— 这不是巧合，
正是"系统按别名绘制"的证据。

> **最大的陷阱**：`CGSCopyRegisteredCursorImages` 读回来的值**看起来是对的**，
> 只有"读 `Arrow` 到底是谁的内容"这一点能揭穿它。
> ⇒ 判据必须是**回读 + 与 cape 逐像素比对**，不能只看注册返回值或日志。

---

## 3 改了什么

上游 `master` 与社区适配之间的差异，以及本次落地的版本（含 PR
[#308](https://github.com/alexzielenski/Mousecape/issues/308) 的实现，来自
`seanjseymour/Mousecape@macos27-cursor-names`）：

| 文件 | 改动 | 作用 |
|---|---|---|
| `MCDefs.m/.h` | 新增 `cursorAliases()` | `Arrow → ArrowS`、`IBeam → IBeamS` 映射 |
| `apply.m/.h` | 别名注册 + **回读校验** + `MCApplyResult` | 定义别名时同步注册；校验是否真生效；不再"假成功" |
| `backup.m` | **逐个指针备份** | 原逻辑"有 Arrow 备份就整体跳过" ⇒ 后注册的指针拿不到备份，macOS 27 又无法移除 ⇒ **重置后卡住**（实测 Wait 会卡）|
| `restore.m` | 重置时也处理别名 | 重置覆盖 `ArrowS` / `IBeamS` |
| `main.m` | 新增 `--probe` | 探测本机允许替换哪些内置指针，便于每次 macOS 升级后自检 |
| `apply.m:45` | 签名修为 `char *` | 上游此处参数类型错误（3d11937 修复）|

对应的 unified diff 在 `patch/`（可直接 `patch -p1` 到上游源码）。

### 3.1 我额外补的两件事

1. **`build-mousecloak.sh`** —— 本机**只有 Command Line Tools、没有完整 Xcode**
   （`xcodebuild` 不可用），所以用 clang 直接编译。严格照 Xcode 工程设置：
   `CLANG_ENABLE_OBJC_ARC = NO`（mousecloak 是手动内存管理）、`GCC_PREFIX_HEADER`
   （否则 `NSString` 未声明）；`vendor/GBCli` 用 `__weak` 必须单独以 **ARC** 编译。
   产物是 **universal（arm64 + x86_64）** —— 原 App 是 x86_64 + 公证，只出 arm64 会丢 Intel 兼容性。
2. **`tools/cursor-state.m` + `run-verify.sh`** —— 把"是否真的生效"做成**可判定**的判据
   （MAC 上无法程序化截图看指针，所以用回读比对）。

---

## 4 怎么用

### 4.1 只跑验证（推荐先做这个）

```bash
bash run-verify.sh                     # 用内置示例 cape 跑完整套件
bash run-verify.sh /path/to/your.cape  # 用你自己的 cape
```

它做五件事：构建 → `--probe` → **基线**（重置后应与 cape 不同，证明判据有判别力）→
应用并逐像素比对 → **A/B 对照**（原版旧 CLI 应留成系统默认）→ 复位。
★会实际改动指针，结束前会复位。

### 4.2 装进 App

```bash
DRY=1 bash install-into-app.sh /path/to/Mousecape.app   # 先看会做什么
bash install-into-app.sh /path/to/Mousecape.app         # 实装
```

只替换 `Contents/MacOS/mousecloak`（应用 cape 时真正注册指针的那个二进制），
**不动** GUI、nib、Sparkle、辅助工具。原文件备份为 `mousecloak.orig-<时间戳>`。

替换后 **ad-hoc 重新签名**（原为 Developer ID + 公证，改一个字节签名即失效）。
代价：App 不再是"公证"状态 —— 首次打开若被拦，右键→打开，或
`xattr -dr com.apple.quarantine "<app 路径>"`。

### 4.3 手动用 CLI

```bash
./build/mousecloak --probe                 # 本机允许替换哪些指针
./build/mousecloak --apply your.cape       # 应用
./build/mousecloak --reset                 # 还原系统默认
./build/cursor-state                       # 看当前注册的指针
./build/cursor-state --compare your.cape   # ★判据：与 cape 逐像素比对
```

---

## 5 残留与已知限制

| 项 | 状态 |
|---|---|
| **特权辅助工具**（`Contents/Library/LoginItems/...mousecloakhelper`） | **仍是旧逻辑**。它负责"登录时自动重新应用"。没执行过 App 里的 *Install Helper Tool* 则无影响；若已安装且希望它也带新逻辑，需重新构建 + **用开发者证书重签并走 SMJobBless 重新安装**，当前脚本不处理（避免破坏已注册的特权工具）。|
| `package.json`/Xcode 工程 | **未改**。构建走 `build-mousecloak.sh`，不需要 Xcode。 |
| 完整 GUI 重建 | **本次未做**：本机无完整 Xcode（仅 CLT），且 GUI 在 macOS 27 上工作正常，无需重建。 |
| 动画指针 | `cursor-state` 只比**首帧**（动画指针在系统里也以首帧注册），足以判断"是不是 cape 的图"。 |
| macOS 26 | 未实测（本机只有 27）。别名机制与 #308 报告的 26 行为一致。 |

---

## 6 目录

```
mousecape-macos27/
├── README.md                ← 本文件
├── src/                     ← 已修好的完整工程（来自 PR #308 分支）
├── patch/                   ← 相对上游 master 的 unified diff（可 patch -p1）
├── tools/cursor-state.m     ← 只读探测工具：读回系统注册的指针并比对
├── build-mousecloak.sh      ← 无 Xcode 构建 universal mousecloak
├── run-verify.sh            ← 一键验证（含 A/B 对照）
├── install-into-app.sh      ← 装进 .app（含备份/签名/自检/回滚说明）
└── build/                   ← 产物：mousecloak（universal）、cursor-state
```

---

## 6.5 实装时踩到的两个坑（★必读）

### ① 必须重签**整个 .app 包**，不能只签包内那个文件

只签 `Contents/MacOS/mousecloak` 时，进程被 **`Killed: 9`（rc=137）且无任何输出**。
内核日志给出真因：

```
(AppleSystemPolicy) ASP: Security policy would not allow process: 6007, <app>/Contents/MacOS/mousecloak
```

⇒ 改动包内任何文件后，**外层包的签名即失效**，AppleSystemPolicy 直接拒绝执行。
极易误判成"新二进制有 bug"。`install-into-app.sh` 现在会 `codesign --remove-signature`
后 `--force --deep --sign -` 重签整包。

### ② 未公证的 ad-hoc 包在**临时目录**会被拒；且会被 **App Translocation**

- 同一份包：在 `~/Downloads` **正常**，在 `/tmp` **被杀（rc=137）** ⇒ 安装到常规位置。
- ad-hoc 签名还会触发 **App Translocation**：GUI 进程实际从
  `/private/var/folders/.../AppTranslocation/.../Mousecape-2.app` 启动。
  ★已实测：**translocation 副本里也带着修复版 CLI**，所以"应用 cape"这条路仍然有效。
- 代价：App 不再是"公证"状态（改代码就无法保留原签名）。若要恢复公证，
  必须由持有开发者证书的人重新签名并公证。

### ③ `codesign` 会改变文件哈希（不是代码被改坏）

实装后 `shasum` 与构建产物不同。验证方法：两边都 `codesign --remove-signature` 后再 `cmp`，
**去签名后逐字节一致** ⇒ 差异只是嵌入的签名。`--probe` 输出也逐字一致。
⇒ **别用"文件哈希不同"判定替换失败**，要先剥签名再比。

## 6.6 第二个真实故障：文字光标变成"红点"（探测残留自锁）

**现象**：鼠标悬停在文字上时，I 型光标显示成一个**红点**。

**排查**（逐层排除，没有猜）：
1. 导出当前 I 型光标 → **8×8 纯色方块**（确证是红点）。
2. 查 cape 定义 → **cape 只含 4 个指针**（Arrow / Wait / cursor.3 / cursor.5），
   **根本没有 IBeam** ⇒ **不是 cape 的问题**。
3. 查 `--probe` 实现 → 探测用的测试图是 **纯洋红 32×32**
   （`apply.m`：`CGContextSetRGBFillColor(ctx, 1, 0, 1, 1)`）。
4. 查 Mousecape 备份指针 → `…mousecape.com.apple.coregraphics.IBeam` = **23×22**（健康的原始 I 型光标，已导出肉眼确认），
   而 `…IBeamS` 的备份 = **8×8（就是那个坏值）**。

**★★自锁机制（这是最难缠的地方）**：
`backupCursorForIdentifier` 见"备份已存在"就**不再更新**。
于是坏值一旦被当成"原始值"备份进去，`--reset` / 应用 cape 时的 `resetAllCursors`
只会把**坏值再装回去** —— 怎么重置都去不掉。

**修复**：
| 动作 | 说明 |
|---|---|
| 用健康备份覆盖活动指针 | `repair-cursor --from …IBeam --to com.apple.coregraphics.IBeam --to …IBeamS --apply` |
| **同时覆盖坏的备份本身** | 否则下一次 `--reset` 又把红点装回来（已连测 5 轮 apply/reset 稳定） |
| 加固 `--probe` 的恢复 | 恢复后**回读校验 + 3 次重试**，失败明确报错（连跑 6 次 probe，I 型光标每次完好） |

**新增工具** `tools/repair-cursor.m`：从任一健康备份恢复指定指针（含别名），默认只演练、需 `--apply` 写入。

**★另有一个误判要记**：`Alias` / `Copy` / `ArrowCtx` / `IBeamXOR` 的 8×8 是**系统原生尺寸**，不是损坏。
我一开始按"尺寸偏小"把它们都当成坏的 —— **判据要先建立基线（本机系统默认值），再谈异常**。

## 6.7 About 对话框署名改造

系统标准 About 面板，内容来自两处：

| 显示项 | 来源字段 |
|---|---|
| 应用名 / 版本 | `CFBundleName` / `CFBundleShortVersionString` |
| 版权行 | `NSHumanReadableCopyright` |
| 属名段落 | `Resources/<lang>.lproj/Credits.rtf` |

**改动**（用户要求：原四段署名全部去掉，版权改署，且版权要**分两行**显示）：
- **移除** `Credits.rtf` 里原来的四段署名（Engineering / Icons and Testing / Testing /
  With special thanks to），代之以两行版权：
  ```
  Copyright © 2022-2026 Corvol Name Hostmax.
  All rights reserved.
  ```
- **从主 `Info.plist` 删除 `NSHumanReadableCopyright`**
  ★为什么：该键是**单行**字段，显示在"图标下方"；而多行只能由属名段落提供。
  两者并存会让版权**显示两遍**。所以版权统一由 `Credits.rtf` 承担。
- 辅助工具 `Info.plist` 的 `NSHumanReadableCopyright` 保留为新版权行（它没有独立 About 面板，
  不影响显示；留着是为了万一被别处读取时口径一致）。
- 改完**必须重签整个 .app**（见 §6.5 ①）

**★RTF 里的中文/符号要用转义**：`©` 必须写成 `\'a9`（`ansicpg1252` 码位），
文件本体按 ASCII 写入 —— 直接写 UTF-8 的 `©` 会让 `textutil` 与面板渲染异常。

**★★换行位置受「面板宽度」限制（这是真正的坑）**：

About 面板对属名段落有**固定可用宽度**（由实测折行位置反推 **约 180~220pt**）。
超出就**自动折行**，硬换行 `\` 也救不了 —— 表现为断在奇怪的地方（如名字被劈成两半）。

用 `NSFont sizeWithAttributes:` 精确量宽度（11pt Helvetica）：

| 方案 | 第1行 | 第2行 | 最长行 | 结果 |
|---|---|---|---|---|
| A 采用 | Copyright (c) 2022-2026 Corvol Name | Hostmax. All rights reserved. | **181pt** | 装得下 |
| B | Copyright (c) 2022-2026 | Corvol Name Hostmax. All rights reserved. | 207pt | 装得下 |
| C 弃 | Copyright (c) 2022-2026 Corvol Name Hostmax. | All rights reserved. | **231pt** | **折行**（名字被劈开）|

定稿用 A：两行都远小于 220pt，不会被二次折行。

**为什么不能靠「渲染缩略图」量面板宽度**：`qlmanage -t` / `textutil` 渲染时
**不施加面板宽度约束**（实测连 50 个 `X` 都不折行）。
量面板宽度只能靠**精确字宽 + 观察真实面板的折行位置反推**。

**★验证方法（不用打开 GUI 也能验）**：
```bash
textutil -convert txt -stdout "<app>/Contents/Resources/en.lproj/Credits.rtf"
# 应输出两行：
#   Copyright © 2022-2026 Corvol Name
#   Hostmax. All rights reserved.
```

**★只改"显示给人看"的字段，绝不动技术标识符**：
`CFBundleIdentifier` / `UTTypeIdentifier` / 辅助工具 `CFBundleExecutable` 里的
`com.alexzielenski.*` **保持原样** —— 改了会破坏 cape 文件关联与特权辅助工具的注册。
⇒ 全包搜索"署名文字"应清零，但技术标识符里的名字**故意保留**。

**★仍未改（需你决定）**：`SUFeedURL` 仍指向原作者仓库的 `appcast.xml`
（`https://raw.githubusercontent.com/alexzielenski/Mousecape/master/appcast.xml`）。
它不在 About 面板里，但会让 App 去检查**上游**更新，可能提示你有新版本。
自用可不管；要彻底干净就得指向自己的 appcast 或清空该键。

## 6.8 ★全面审计：还有哪些指针显示不正常

用户追问"还有没类似的图标显示不正常的问题"。为此新增 `tools/audit-cursors.m`，
**一次扫全部指针并量化判定异常**，不再靠肉眼逐个看。

### 判定口径（可量化）

对每个指针取首帧 → RGBA，算：
- **填充率** `fill` = 不透明像素 / 外接矩形面积
- **颜色数** `colors` = 不透明像素里不同 RGB 数（量化到 5 位，避免抗锯齿噪声）

**异常判据：`fill ≥ 0.97 且 colors ≤ 2` ⇒ 实心单色块。**
正常光标是笔画/轮廓，填充率低、颜色数多。这个判据**已用真实故障自证**
（I 型光标的"红点"正是 fill=1.000 / colors=1）。

### 审计覆盖面

- 11 个系统定义指针（`com.apple.coregraphics.*`，含 macOS 26+ 的 `ArrowS`/`IBeamS`）
- **46 个 `com.apple.cursor.N`**（★cape 会直接改这些名字；实测 cape 用了 3 与 5）
- 每个的**备份**（`com.alexzielenski.mousecape.*`）
⇒ 共审计 63 项。

★**为什么必须含 `com.apple.cursor.N`**：漏掉这一族会"审计全绿但屏幕上仍是坏指针"。
实测它与系统内置光标 ID 有映射（`cursor.3` ↔ Alias、`cursor.5` ↔ Copy，
尺寸/颜色数完全一致）。

### 查出并修复的问题：4 个指针是"纯红实心块"

| 名字 | 之前 | 恢复后 | 对应系统内置 ID |
|---|---|---|---|
| `IBeamXOR` | 8×8 红块 | **16×21** 反转 I 型 | 2 |
| `Alias` | 8×8 红块 | **28×40** 灰色禁止符号 | 3 |
| `Copy` | 8×8 红块 | **28×40** 绿色加号 | 5 |
| `ArrowCtx` | 8×8 红块 | **32×32** 十字准星 | 7 |

且**它们的备份也是红块** ⇒ 属"污染自锁"：`--reset` 只会把红块装回来。

### 恢复手段：`repair-cursor --sys`

`CoreCursorCopyImages`（在 **ApplicationServices**，不在 SkyLight）能读出**系统内置光标图**，
按 ID 取，正好是这些名字的原始值：

```bash
repair-cursor --sys 3 --to com.apple.coregraphics.Alias \
                      --to com.alexzielenski.mousecape.com.apple.coregraphics.Alias --apply
```
★**同时修活动值与备份值** —— 只修一个，下次 `--reset` 就白干。

`ID → 名字`对照（实测 macOS 27）：
```
2 = IBeamXOR   3 = Alias   4 = Wait   5 = Copy   7 = ArrowCtx
```

### 结果

```
异常活动指针（实心块）: 0
★被污染的备份（实心块）: 0
```
且"应用 cape → 审计 → `--reset` → 审计"全链路仍为 0 异常。

## 7 排查纪律（本轮的教训）

1. **`dlsym` 找不到 ≠ 符号不存在。** 我一开始只在 CoreGraphics / SkyLight 里找
   `CoreCursorSet`，全部报"未找到"，差点判定"macOS 27 移除了它"。实际它在
   **ApplicationServices** 里，一找就有。⇒ 查私有符号要**遍试相关框架**，别只试一个。
2. **"返回成功"是最会骗人的信号。** mousecloak 打印 `Applied successfully`、
   注册函数返回 `kCGErrorSuccess`，指针却纹丝不动。⇒ 判据要**回读实际状态**。
3. **对照实验必须清基线。** 我第一次比较"原版 vs 新版"时，新版的结果还留在系统里，
   于是原版也"看起来生效了"。加上 `--reset` 做干净基线后，差异才现出来。
4. **宽松的文本匹配会把提示当成结果。** 验证脚本里我开始用 `grep Arrow`，
   命中了工具末尾的提示文字，判定假红。⇒ 按"行首即该标识"精确匹配。
5. **`$var` 后紧跟全角字符会被 bash 并进变量名。** `"（$a）"` 触发
   `unbound variable`。⇒ 写 `${a}` 或改用半角括号。

---

## 8 致谢与出处

- 原工程：[alexzielenski/Mousecape](https://github.com/alexzielenski/Mousecape)（MIT 风格许可，见 `src/LICENSE`）
- macOS 26/27 适配与 `--probe`/回读校验设计：**PR #308**（`seanjseymour/Mousecape@macos27-cursor-names`），
  其描述里的实测矩阵是本次工作的关键依据
- 社区另一版适配：[AdamWawrzynkowskiGF/Mousecape-TahoeSupport](https://github.com/AdamWawrzynkowskiGF/Mousecape-TahoeSupport)（`TahoeSupport` 分支）

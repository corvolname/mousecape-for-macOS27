//
//  loginitem.h
//  mousecloak
//
//  ★2026-10-16 新增：让 Mousecape 的游标在**登录/重启后自动恢复**。
//  ---------------------------------------------------------------------------
//  【为什么需要】macOS 27 上，Mousecape 原本的"跨重启保持"机制失效了：
//    · 原设计：helper 登录项（com.alexzielenski.mousecloakhelper，由
//      SMLoginItemSetEnabled 注册）在登录时启动 `mousecloak --listen`，
//      由 listen.m 在启动时读 `MCAppliedCursor` 偏好并重新 apply。
//    · 实测：该登录项**已注册且 enabled**，但进程**从未被启动**（active count = 0）；
//      手工直接跑那个可执行文件则完全正常 ⇒ 不是崩溃，是登录时没被拉起。
//      最可能的原因是签名：本 app 为 **ad-hoc 签名**（TeamIdentifier 为空），
//      而登录项启动要过签名校验。
//    · 且 `appliedCape` 是 weak 属性，不持久化 ⇒ 主程序重启也不会自己恢复。
//  【本方案】改用一个**用户 LaunchAgent**（~/Library/LaunchAgents）：
//    · 它走 legacy 登录项通道，**不经** SMLoginItemSetEnabled 的签名校验
//      ⇒ ad-hoc 签名也能可靠执行（已实测：runs=1, exit=0，游标被恢复）。
//    · LaunchAgent 执行 `mousecloak --listen`：listen.m 启动时会
//      `applyCapeAtPath(appliedCapePathForUser(NSUserName()))` —— 即
//      **自己读偏好、自己应用**，无需任何参数；并继续监听用户切换与显示器变化。
//
#ifndef Mousecape_loginitem_h
#define Mousecape_loginitem_h

#import <Foundation/Foundation.h>

/// 安装/卸载"登录时自动恢复游标"的 LaunchAgent。
/// @param install YES=安装，NO=卸载
/// @param executable **要在登录时执行哪个二进制**的绝对路径。
///        · 从 `mousecloak` 自己调用 ⇒ 传它自己的路径（传 nil 则自动取 mainBundle）。
///        · 从 GUI（Mousecape.app）调用 ⇒ 必须传 app 内 `Contents/MacOS/mousecloak` 的路径，
///          因为"应用游标"这件事只有 mousecloak 会做（GUI 自己不做）。
/// @param error   失败时返回错误（可为 NULL）
/// @return 成功返回 YES
BOOL MCSetLoginPersistenceEnabled(BOOL install, NSString *executable, NSError **error);

/// 当前是否已安装（供 UI 显示"已安装/未安装"）
BOOL MCLoginPersistenceInstalled(void);

/// LaunchAgent 的完整路径（调试/日志用）
NSString *MCLoginPersistencePath(void);

/* ★★2026-10-16 内置 cape（用户口径）：
   「这两套是**随 app 内置**的，**可以删除编辑，用户也可以新增**」
   ⇒ 内置的两套是"**初始主题库**"，不是不可变的资源库：
     · app 首次运行时把它们**复制进用户库**（于是用户可以编辑/删除/新增）；
     · 只在"用户库为空"时导入 ⇒ **用户删掉的不会再冒出来**。
   同时"重启后自动恢复"用**内置兜底**，因此**不依赖任何外部脚本或用户目录**。 */

/// 返回内置 cape 目录（app 包内 `Contents/Resources/capes`）；不在 app 内运行时返回 nil。
NSString *MCEmbeddedCapesDirectory(void);

/// 把内置 cape 复制进用户库（幂等；**仅当用户库里没有任何 .cape 时**才导入）。
/// 返回本次导入的文件数（0 表示无需导入）。
NSUInteger MCImportEmbeddedCapesIfNeeded(void);

/// app 内置的 default 那套（`Resources/capes/default.cape`）。
/// ★listen.m 在"用户库那套不存在"时用它兜底 ⇒ 开箱即用、不依赖用户目录。
NSString *MCEmbeddedDefaultCapePath(void);

/// 解析"本次应该应用哪一套 cape"（用户口径：以 app 内当前应用的为准，回退到内置 default）：
///   ① 偏好 MCAppliedCursor 记录的那套（且文件存在）；
///   ② 内置的 default 那套（`Resources/capes/default.cape`）；
///   ③ 都没有 ⇒ 用户库里最新的一套；再没有 ⇒ nil。
NSString *MCEffectiveCapePath(void);

#endif /* Mousecape_loginitem_h */

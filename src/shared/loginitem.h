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

#endif /* Mousecape_loginitem_h */

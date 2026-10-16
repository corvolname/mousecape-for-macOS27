//
//  listen.m
//  Mousecape
//
//  Created by Alex Zielenski on 2/1/14.
//  Copyright (c) 2014 Alex Zielenski. All rights reserved.
//

#import "listen.h"
#import "apply.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import "MCPrefs.h"
#import "CGSCursor.h"
#import <Cocoa/Cocoa.h>
#import "scale.h"
#import "loginitem.h"   /* ★内置 cape 兜底（与 GUI 共用实现） */

NSString *appliedCapePathForUser(NSString *user) {
    NSString *home = NSHomeDirectoryForUser(user);
    NSString *ident =     MCDefaultFor(@"MCAppliedCursor", user, (NSString *)kCFPreferencesCurrentHost);
    NSString *appSupport = [home stringByAppendingPathComponent:@"Library/Application Support"];
    NSString *userPath = [[[appSupport stringByAppendingPathComponent:@"Mousecape/capes"] stringByAppendingPathComponent:ident] stringByAppendingPathExtension:@"cape"];

    /* ★★2026-10-16：用户库那套不存在时，回退到 **app 内置**的那套。
       用户口径：「所有东西都是内置的，封装进 app，不是安装后还需要单独去跑独立的脚本」。
       为什么需要这条：登录时若偏好为空（从未应用过 / 被 --reset 清过）或
       指向的 cape 已被用户删除，原实现会拿一个**不存在的路径**去 apply ⇒ 静默失败、
       游标保持系统默认。有了内置兜底，**开箱即用**。
       ★注意：用户**显式**应用的那套始终优先（用户可编辑/删除/新增）。 */
    if (![[NSFileManager defaultManager] fileExistsAtPath:userPath]) {
        NSString *embedded = MCEmbeddedDefaultCapePath();
        if (embedded) return embedded;
    }
    return userPath;
}

static void UserSpaceChanged(SCDynamicStoreRef	store, CFArrayRef changedKeys, void *info) {
    CFStringRef currentConsoleUser = SCDynamicStoreCopyConsoleUser(store, NULL, NULL);
    
    MMLog("Current user is %s", [(__bridge NSString *)currentConsoleUser UTF8String]);
    
    if (!currentConsoleUser || CFEqual(currentConsoleUser, CFSTR("loginwindow"))) {
        return;
    }
    
    NSString *appliedPath = appliedCapePathForUser((NSString *)currentConsoleUser);
    MMLog(BOLD GREEN "User Space Changed to %s, applying cape..." RESET, [(__bridge NSString *)currentConsoleUser UTF8String]);
    if (!applyCapeAtPath(appliedPath)) {
        MMLog(BOLD RED "Application of cape failed" RESET);
    }
    
    setCursorScale(defaultCursorScale());
    
    CFRelease(currentConsoleUser);
}

void reconfigurationCallback(CGDirectDisplayID display,
    	CGDisplayChangeSummaryFlags flags,
    	void *userInfo) {
    MMLog("Reconfigure user space");
    applyCapeAtPath(appliedCapePathForUser(NSUserName()));
    float scale;
    CGSGetCursorScale(CGSMainConnectionID(), &scale);
    CGSSetCursorScale(CGSMainConnectionID(), scale + .3);
    CGSSetCursorScale(CGSMainConnectionID(), scale);
}


void listener(void) {
    SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("com.apple.dts.ConsoleUser"), UserSpaceChanged, NULL);
    assert(store != NULL);
    
    CFStringRef key = SCDynamicStoreKeyCreateConsoleUser(NULL);
    assert(key != NULL);
    
    CFArrayRef keys = CFArrayCreate(NULL, (const void **)&key, 1, &kCFTypeArrayCallBacks);
    assert(keys != NULL);
    
    Boolean success = SCDynamicStoreSetNotificationKeys(store, keys, NULL);
    assert(success);
    
    /* ★★2026-10-16 去掉 NSApplicationLoad()（用户反馈："重启后 dock 栏有 2 个 app
       图标，而且一直在跳跃"）。
       原因：`NSApplicationLoad()` 会把**命令行工具**注册成一个 GUI 应用
         ⇒ Dock 里出现一个 mousecloak 图标；而它永远不会 `[NSApp run]` / activate
         ⇒ macOS 认为"这个 app 还在启动中" ⇒ **图标一直跳**。
       为什么可以去掉：本函数后面的能力都不需要 GUI 应用 ——
         · `CGDisplayRegisterReconfigurationCallback` 是 CoreGraphics 的 C 接口；
         · 用户切换靠 `SCDynamicStore`（SystemConfiguration）；
         · 应用主题靠已注册的 CGS 接口。
       ⇒ 去掉后它就是个安静的**后台进程**，不再有 Dock 图标、也不再跳。 */
    CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, NULL);
    MMLog(BOLD CYAN "Listening for Display changes" RESET);
    
    CFRunLoopSourceRef rls = SCDynamicStoreCreateRunLoopSource(NULL, store, 0);
    assert(rls != NULL);
    MMLog(BOLD CYAN "Listening for User changes" RESET);
    
    // Apply the cape for the user on load
    applyCapeAtPath(appliedCapePathForUser(NSUserName()));
    setCursorScale(defaultCursorScale());
    
    CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, kCFRunLoopDefaultMode);
    CFRunLoopRun();

    // Cleanup
    CFRunLoopSourceInvalidate(rls);
    CFRelease(rls);
    CFRelease(keys);
    CFRelease(key);
    CFRelease(store);
}
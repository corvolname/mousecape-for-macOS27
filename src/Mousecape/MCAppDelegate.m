//
//  MCAppDelegate.m
//  Mousecape
//
//  Created by Alex Zielenski on 2/1/14.
//  Copyright (c) 2014 Alex Zielenski. All rights reserved.
//

#import "MCAppDelegate.h"
#import <Security/Security.h>
#import <ServiceManagement/ServiceManagement.h>
#import "MCCursorLibrary.h"
#import "create.h"
#import "MASPreferencesWindowController.h"
#import "MCGeneralPreferencesController.h"
/* ★2026-10-16：「登录项持久化」的共用实现（与 mousecloak 同一份源码，见 src/shared/loginitem.m） */
#import "loginitem.h"

@interface MCAppDelegate () {
    MASPreferencesWindowController *_preferencesWindowController;
}
@property (readonly) MASPreferencesWindowController *preferencesWindowController;
- (void)configureHelperToolMenuItem;
@end

@implementation MCAppDelegate
@dynamic preferencesWindowController;

/* ★2026-10-16：app 内 mousecloak 的绝对路径。
   登录项要执行的是它（"应用游标"只有 mousecloak 会做），**不是** GUI 自己。
   用 mainBundle.executablePath 换末段文件名 —— 无论 app 放在哪都正确。 */
- (NSString *)mousecloakExecutablePath {
    NSString *exe = NSBundle.mainBundle.executablePath;
    if (exe.length == 0) return nil;
    return [exe.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"mousecloak"];
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    self.libraryWindowController = [[MCLibraryWindowController alloc] initWithWindowNibName:@"Library"];
    [self.libraryWindowController loadWindow];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    /* ★★2026-10-16 自愈：启动时确保"登录时自动恢复游标"的 LaunchAgent 已装。
       用户口径：「安装 app 应用，并在菜单栏里的 install helper tool 后，
       以后不管怎么重启都不在发生失效」。
       ⇒ 点一次按钮就永久生效；这里再做一层兜底（幂等，重复启动无副作用）：
         ① 已装且能用 ⇒ 什么都不做；
         ② 没装 ⇒ 自动装上（用户连按钮都不用点）。
       ★只在能解析到 cape 时才装：还没应用过任何主题的话，装了也没意义。 */
    {
        NSError *e = nil;
        if (!MCLoginPersistenceInstalled()) {
            if (MCSetLoginPersistenceEnabled(YES, [self mousecloakExecutablePath], &e)) {
                NSLog(@"[Mousecape] login persistence auto-installed");
            } else {
                NSLog(@"[Mousecape] login persistence auto-install skipped: %@", e.localizedDescription);
            }
        }
    }
    [self configureHelperToolMenuItem];
    [self.libraryWindowController showWindow:self];
    
    // Re-apply currently applied cape
    if (self.libraryWindowController.libraryViewController.libraryController.appliedCape != NULL) {
        [self.libraryWindowController.libraryViewController.libraryController reapplyCape:self.libraryWindowController.libraryViewController.libraryController.appliedCape];
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    BOOL open = [filename.pathExtension.lowercaseString isEqualToString:@"cape"];
    NSURL *url = [NSURL fileURLWithPath:filename];
    if (open) {
        [self.libraryWindowController.libraryViewController.libraryController importCapeAtURL:url];
    }
    return open;
}

/* ★2026-10-16 重写：原实现只看 SMLoginItemSetEnabled 是否注册过 job，
   而 macOS 27 上即使"注册过"进程也**不会被启动**（登录项失效）⇒ 菜单会显示
   "Uninstall Helper Tool"，用户无从修复"重启后失效"。
   ⇒ 现在以 **LaunchAgent 是否存在**为准（那才是真正生效的东西，见 src/shared/loginitem.m）。 */
- (void)configureHelperToolMenuItem {
    CFDictionaryRef dict = SMJobCopyDictionary(kSMDomainUserLaunchd, CFSTR("com.alexzielenski.mousecloakhelper"));
    BOOL legacyJob = (dict != NULL);
    if (dict) CFRelease(dict);
    BOOL agent = MCLoginPersistenceInstalled();   /* 真正生效的那条 */

    [self.toggleHelperItem setTag:(agent || legacyJob) ? 1 : 0];
    [self.toggleHelperItem setTitle:self.toggleHelperItem.tag ?
                    NSLocalizedString(@"Uninstall Helper Tool", "Uninstall Helper Tool Menu Item") :
                    NSLocalizedString(@"Install Helper Tool", "Install Helper Tool Menu Item")];
}

- (IBAction)toggleInstall:(NSMenuItem *)sender {
    /* ★★2026-10-16 重写（用户口径：「安装 app 并在菜单栏里 install helper tool 后，
       以后不管怎么重启都不再发生失效」）：
       · 原实现只调 SMLoginItemSetEnabled —— 实测在 macOS 27 + ad-hoc 签名下，
         该 API **返回成功但登录项进程不会被启动** ⇒ 用户点了"安装"、重启后照样失效。
       · 新实现安装一个**用户 LaunchAgent**（走 legacy 登录项通道，不经该签名校验），
         登录时执行 `mousecloak --apply <当前 cape>` ⇒ 实测游标被真正恢复。
       · 仍然调用一次 SMLoginItemSetEnabled 作为**兜底**（在签名正常的机器上它也能工作）；
         它的返回值**不作为成功判据**（那正是假成功的来源）。 */
    BOOL uninstall = (self.toggleHelperItem.tag != 0);
    NSError *error = nil;
    NSString *exe = [self mousecloakExecutablePath];

    BOOL ok = MCSetLoginPersistenceEnabled(!uninstall, exe, &error);

    /* 兜底：老的 helper 登录项（失败也不影响，因为我们已有 LaunchAgent） */
    SMLoginItemSetEnabled(CFSTR("com.alexzielenski.mousecloakhelper"), uninstall ? false : true);

    if (ok) {
        [self.toggleHelperItem setTag:uninstall ? 0 : 1];
        [self.toggleHelperItem setTitle:uninstall ?
            NSLocalizedString(@"Install Helper Tool", "Install Helper Tool Menu Item") :
            NSLocalizedString(@"Uninstall Helper Tool", "Uninstall Helper Tool Menu Item")];

        NSRunAlertPanel(uninstall ? NSLocalizedString(@"Success", "Helper Tool Uninstall Result Title Success")
                                  : NSLocalizedString(@"Success", "Helper Tool Install Result Title Success"),
                        uninstall
                          ? NSLocalizedString(@"The Mousecape helper was successfully uninstalled",
                                              "Helper Tool Uninstall Success Result")
                          : NSLocalizedString(@"The Mousecape helper was successfully installed. Your cursor theme will be restored automatically after every restart.",
                                              "Helper Tool Install Success Result"),
                        NSLocalizedString(@"Sweet", "Helper Tool Install Result Gratitude 1"),
                        NSLocalizedString(@"Thanks", "Helper Tool Install Result Gratitude 2"), nil);
    } else {
        /* ★如实报错：不再出现"提示成功、其实没生效" */
        NSRunAlertPanel(NSLocalizedString(@"Failure", "Helper Tool Result Title Failure"),
                        [NSString stringWithFormat:@"%@\n\n%@",
                            error.localizedDescription ?: @"The action did not complete successfully.",
                            exe ?: @"(mousecloak not found)"],
                        NSLocalizedString(@"OK", "OK"), nil, nil);
    }
}

- (MASPreferencesWindowController *)preferencesWindowController {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSViewController *general = [[MCGeneralPreferencesController alloc] init];
        _preferencesWindowController = [[MASPreferencesWindowController alloc] initWithViewControllers:@[ general ] title:NSLocalizedString(@"Preferences", "Preferences Window Title")];
    });
    
    return _preferencesWindowController;
}

#pragma mark - Interface Actions

- (IBAction)restoreCape:(id)sender {
    [self.libraryWindowController.libraryViewController.libraryController restoreCape];
}

- (IBAction)convertCape:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes  = @[ @"MightyMouse" ];
    panel.title             = NSLocalizedString(@"Import", "MightyMouse Import Panel Title");
    panel.message           = NSLocalizedString(@"Choose a MightyMouse file to import", "MightyMouse Import Panel useless description");
    panel.prompt            = NSLocalizedString(@"Import", "MightyMouse Import Panel Prompt");
    if ([panel runModal] == NSFileHandlingPanelOKButton) {
        NSString *name = panel.URL.lastPathComponent.stringByDeletingPathExtension;
        NSDictionary *metadata = @{
                                   @"name": name,
                                   @"version": @1.0,
                                   @"author": NSLocalizedString(@"Unknown", "MightyMouse Import Default Author"),
                                   @"identifier": [NSString stringWithFormat:@"local.import.%@.%f", name, [NSDate timeIntervalSinceReferenceDate]]
                                   };
        
        NSDictionary *cape = createCapeFromMightyMouse([NSDictionary dictionaryWithContentsOfURL:panel.URL], metadata);
        MCCursorLibrary *library = [MCCursorLibrary cursorLibraryWithDictionary:cape];
        [self.libraryWindowController.libraryViewController.libraryController importCape:library];
    }
}

- (IBAction)newDocument:(id)sender {
    [self.libraryWindowController.libraryViewController.libraryController importCape:[[MCCursorLibrary alloc] init]];
}

- (IBAction)openDocument:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedFileTypes  = @[ @"cape" ];
    panel.title             = NSLocalizedString(@"Import", "Mousecape Import Title");
    panel.message           = NSLocalizedString(@"Choose a Mousecape to import", "Mousecape Import useless description");
    panel.prompt            = NSLocalizedString(@"Import", "Mousecape Import Prompt");
    if ([panel runModal] == NSFileHandlingPanelOKButton) {
        [self.libraryWindowController.libraryViewController.libraryController importCapeAtURL:panel.URL];
    }
}

- (IBAction)showPreferences:(id)sender {
    [self.preferencesWindowController showWindow:sender];
}

@end

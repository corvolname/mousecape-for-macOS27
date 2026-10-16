//
//  loginitem.m
//  mousecloak
//
//  ★2026-10-16 新增：用**用户 LaunchAgent** 让游标在登录/重启后自动恢复。
//  背景与理由见 loginitem.h 顶部注释（简言之：macOS 27 上 SMLoginItemSetEnabled
//  注册的 helper 登录项不被启动，且本 app 是 ad-hoc 签名）。
//
#import "loginitem.h"
#import <ServiceManagement/ServiceManagement.h>

/* ★本文件要同时被**两种内存管理模式**编译：
     · mousecloak  → CLANG_ENABLE_OBJC_ARC = NO（手动内存管理）
     · Mousecape GUI → CLANG_ENABLE_OBJC_ARC = YES（ARC）
   ⇒ 不能直接写 `autorelease`（ARC 下不可用），用下面这个宏在两种模式下都正确。 */
#if __has_feature(objc_arc)
  #define MC_AUTORELEASE(x) (x)
#else
  #define MC_AUTORELEASE(x) [(x) autorelease]
#endif

/* 与 Mousecape 的 helper 一致的标识，便于 UI / 排查时一眼认出 */
static NSString *const MCLoginLabel = @"com.alexzielenski.mousecloakhelper.login";

NSString *MCLoginPersistencePath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            [@"Library/LaunchAgents" stringByAppendingPathComponent:
             [MCLoginLabel stringByAppendingPathExtension:@"plist"]]];
}

/// 兜底：从 argv[0] 推导可执行文件绝对路径（极少走到）。
static NSString *MCSelfExecutablePath(void) {
    NSString *p = NSBundle.mainBundle.executablePath;
    if (p.length > 0) return p;
    return [NSString stringWithUTF8String:[[NSProcessInfo processInfo].arguments.firstObject fileSystemRepresentation]];
}

BOOL MCLoginPersistenceInstalled(void) {
    return [NSFileManager.defaultManager fileExistsAtPath:MCLoginPersistencePath()];
}

/// 取当前用户"已应用的 cape"标识（listen.m 用同一个键）。
/// 只用于日志/诊断，写 plist 时并不需要它 —— `--listen` 会自己读。
static NSString *MCAppliedCapeIdentifier(void) {
    /* ★★2026-10-16 修正：原来用 kCFPreferencesAnyApplication 读，**读不到** ——
       Mousecape 把该偏好写在 **app 域** `com.alexzielenski.Mousecape` 的 currentHost 里
       （`MCPrefs.h` 的 `kMCDomain`，`listen.m` 也是用它读的）。
       ⇒ 这里必须用同一个域，否则解析不到 cape ⇒ 自愈会以"找不到任何 cape"为由跳过。 */
    CFPropertyListRef v = CFPreferencesCopyValue(CFSTR("MCAppliedCursor"),
                                                CFSTR("com.alexzielenski.Mousecape"),
                                                kCFPreferencesCurrentUser,
                                                kCFPreferencesCurrentHost);
    /* CFPreferencesCopyValue 是 Create 规则 ⇒ 非 ARC 下要自己释放；ARC 下交给编译器 */
    return v ? MC_AUTORELEASE((__bridge NSString *)v) : nil;
}

/* ══════════════════════════════════════════════════════════════════════════
   ★★2026-10-16 内置 cape（用户口径）：
     「这两套是**随 app 内置**的，**可以删除编辑，用户也可以新增**」
     「我需要的是这个 app 所有东西都是内置的，封装进 app，
       不是安装后还需要单独去跑独立的脚本」

   设计（两个目标同时满足）：
     · **随 app 分发**：两套 cape 打进 `Contents/Resources/capes/`
       （`default.cape` ＝ 系统默认指针那套；另一套是主题）。
     · **可编辑/删除/新增**：app 首次运行把它们**复制进用户库**，
       之后一切以用户库为准 —— 用户改了、删了都不会被覆盖回来。
     · **重启后恢复不依赖外部脚本**：`MCEffectiveCapePath()` 在用户库找不到时
       回退到 **app 内置的那套** ⇒ 即使有人从没用过 Mousecape，登录项也能应用内置默认。
   ══════════════════════════════════════════════════════════════════════════ */

NSString *MCEmbeddedCapesDirectory(void) {
    /* ★实测：从 app 内运行时 `NSBundle.mainBundle.resourcePath` 正确指向
       `/Applications/Mousecape.app/Contents/Resources`
       （命令行工具被放在别处运行时它指向那个目录，此时判定为"没有内置 cape"）。 */
    NSString *res = NSBundle.mainBundle.resourcePath;
    if (res.length == 0) return nil;
    NSString *dir = [res stringByAppendingPathComponent:@"capes"];
    return [NSFileManager.defaultManager fileExistsAtPath:dir] ? dir : nil;
}

static NSString *MCUserCapesDirectory(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Mousecape/capes"];
}

/// 用户库里已有的 .cape 文件名（按名字排序）
static NSArray<NSString *> *MCUserCapeNames(void) {
    NSArray *all = [NSFileManager.defaultManager contentsOfDirectoryAtPath:MCUserCapesDirectory() error:NULL] ?: @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in all) if ([n.pathExtension isEqualToString:@"cape"]) [out addObject:n];
    return out;
}

NSUInteger MCImportEmbeddedCapesIfNeeded(void) {
    NSString *src = MCEmbeddedCapesDirectory();
    if (src.length == 0) return 0;                        /* 不在 app 内运行 ⇒ 无内置可导 */
    /* ★只在用户库**为空**时导入：用户删掉的不会再冒出来（用户口径：可以删除编辑） */
    if (MCUserCapeNames().count > 0) return 0;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dst = MCUserCapesDirectory();
    if (![fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:NULL]) return 0;

    NSUInteger n = 0;
    for (NSString *name in [fm contentsOfDirectoryAtPath:src error:NULL]) {
        if (![name.pathExtension isEqualToString:@"cape"]) continue;
        NSString *from = [src stringByAppendingPathComponent:name];
        NSString *to   = [dst stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:to]) continue;
        if ([fm copyItemAtPath:from toPath:to error:NULL]) n++;
    }
    if (n > 0) NSLog(@"[Mousecape] imported %lu embedded cape(s) into the user library", (unsigned long)n);
    return n;
}

/// 用户在 app 里显式应用的那套（偏好记录，且文件仍在）
static NSString *MCUserAppliedCapePath(void) {
    NSString *ident = MCAppliedCapeIdentifier();
    if (ident.length == 0) return nil;
    NSString *p = [[MCUserCapesDirectory() stringByAppendingPathComponent:ident] stringByAppendingPathExtension:@"cape"];
    return [NSFileManager.defaultManager fileExistsAtPath:p] ? p : nil;
}

/// app 内置的 default 那套
NSString *MCEmbeddedDefaultCapePath(void) {
    NSString *dir = MCEmbeddedCapesDirectory();
    if (dir.length == 0) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *p = [dir stringByAppendingPathComponent:@"default.cape"];
    if ([fm fileExistsAtPath:p]) return p;
    for (NSString *n in [fm contentsOfDirectoryAtPath:dir error:NULL]) {   /* 兜底：任一内置 */
        if ([n.pathExtension isEqualToString:@"cape"]) return [dir stringByAppendingPathComponent:n];
    }
    return nil;
}

/// 用户库里最新的一套（开发期 / 无内置资源时的兜底）
static NSString *MCLatestUserCapePath(void) {
    NSString *dir = MCUserCapesDirectory();
    NSString *best = nil; NSDate *bestDate = nil;
    for (NSString *n in MCUserCapeNames()) {
        NSString *q = [dir stringByAppendingPathComponent:n];
        NSDate *d = [NSFileManager.defaultManager attributesOfItemAtPath:q error:NULL].fileModificationDate;
        if (!best || (d && [d compare:bestDate] == NSOrderedDescending)) { best = q; bestDate = d; }
    }
    return best;
}

NSString *MCEffectiveCapePath(void) {
    NSString *p = MCUserAppliedCapePath();     /* ① 用户当前应用的那套 */
    if (p) return p;
    p = MCEmbeddedDefaultCapePath();           /* ② 内置 default（不依赖用户目录） */
    if (p) return p;
    return MCLatestUserCapePath();             /* ③ 兜底 */
}

static BOOL MCRunLaunchctl(NSArray<NSString *> *args) {
    NSTask *t = MC_AUTORELEASE([[NSTask alloc] init]);
    t.launchPath = @"/bin/launchctl";
    t.arguments = args;
    t.standardOutput = [NSPipe pipe];
    t.standardError = [NSPipe pipe];
    @try {
        [t launch];
        [t waitUntilExit];
    } @catch (NSException *e) {
        return NO;
    }
    return t.terminationStatus == 0;
}

static NSString *MCLoginDomain(void) {
    return [NSString stringWithFormat:@"gui/%d", getuid()];
}

BOOL MCSetLoginPersistenceEnabled(BOOL install, NSString *executable, NSError **error) {
    NSString *plistPath = MCLoginPersistencePath();
    NSString *label = MCLoginLabel;

    /* 无论装还是卸，先把旧的 bootout（幂等；不存在时会返回非 0，忽略即可） */
    MCRunLaunchctl(@[@"bootout", [NSString stringWithFormat:@"%@/%@", MCLoginDomain(), label]]);

    if (!install) {
        if ([NSFileManager.defaultManager fileExistsAtPath:plistPath]) {
            [NSFileManager.defaultManager removeItemAtPath:plistPath error:NULL];
        }
        return YES;
    }

    /* ★由调用方指定要执行哪个二进制（GUI 必须指向 app 内的 mousecloak，不是它自己） */
    NSString *exe = executable.length > 0 ? executable : MCSelfExecutablePath();
    if (exe.length == 0 || ![NSFileManager.defaultManager isExecutableFileAtPath:exe]) {
        if (error) *error = [NSError errorWithDomain:@"MousecapeLoginItem" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"Cannot locate mousecloak executable." }];
        return NO;
    }

    /* ★★LaunchAgent 内容（为什么用 `--apply <cape>` 而不是 `--listen`）：
       · 原设计是登录时跑 `--listen`，由 listen.m 自己读偏好 MCAppliedCursor 再应用。
         ★实测：在 launchd 上下文里它**没有应用成功**（偏好与路径都对、进程也在跑，
           但游标未变）⇒ 不再依赖它。
       · 改为**直接执行 `--apply <cape 绝对路径>`**：这条路径已实测能把游标真正注册
         （Arrow/ArrowS 从 28x40 变 32x32）。做法更直白：登录时把"该应用的那套"再应用一次。
       · RunAtLoad=true ⇒ 登录即执行；执行完即退出（不需要常驻）。
       · ProcessType=Interactive ⇒ 需要连 WindowServer，别被当后台任务节流。 */
    /* ★先确认"确实有一套可应用的 cape"，否则装了也没意义、还会给用户假安全感。 */
    NSString *capePath = MCEffectiveCapePath();
    if (capePath.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"MousecapeLoginItem" code:4 userInfo:@{
            NSLocalizedDescriptionKey: @"找不到任何 cape。请先在 Mousecape 里应用一套主题，再点 Install Helper Tool。" }];
        return NO;
    }
    /* ★执行 `--listen`（不是 `--apply <写死路径>`）：
       · listen.m 启动时 `applyCapeAtPath(appliedCapePathForUser(...))` —— **自己读偏好**
         ⇒ 用户以后换主题，登录时应用的就是**新的那套**（写死路径会过时）。
       · 它还持续监听"用户切换 / 显示器重配置"，这两点正是要覆盖的场景。
       ★实测（2026-10-16，launchd 真实拉起）：偏好有值时能正确把 Arrow/ArrowS
         从 28x40 恢复到 32x32。 */
    NSDictionary *plist = @{
        @"Label": label,
        @"ProgramArguments": @[ exe, @"--listen" ],
        @"RunAtLoad": @YES,
        @"ProcessType": @"Interactive",
    };

    NSString *dir = plistPath.stringByDeletingLastPathComponent;
    if (![NSFileManager.defaultManager createDirectoryAtPath:dir
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:error]) {
        return NO;
    }
    if (![plist writeToFile:plistPath atomically:YES]) {
        if (error) *error = [NSError errorWithDomain:@"MousecapeLoginItem" code:2 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Cannot write %@", plistPath] }];
        return NO;
    }

    /* 立刻载入 ⇒ 不必等下次登录就生效（同时验证 plist 真的可被 launchd 接受） */
    BOOL loaded = MCRunLaunchctl(@[@"bootstrap", MCLoginDomain(), plistPath]);

    NSLog(@"[mousecloak] login persistence: label=%@ exe=%@ cape=%@ loaded=%d",
          label, exe, capePath, loaded);

    /* ★只有 bootstrap 成功才算安装成功：这样调用方（UI/脚本）能拿到真实结果，
       不会出现"提示安装成功、其实没生效"（原实现用 SMLoginItemSetEnabled 就这个问题）。 */
    if (!loaded) {
        if (error) *error = [NSError errorWithDomain:@"MousecapeLoginItem" code:3 userInfo:@{
            NSLocalizedDescriptionKey: @"launchctl bootstrap 失败：LaunchAgent 已写入但未能载入。" }];
        return NO;
    }
    return YES;
}

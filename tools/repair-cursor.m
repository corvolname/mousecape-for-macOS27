// repair-cursor.m —— 从 Mousecape 的备份指针恢复指定指针（含 macOS 26+ 的别名）
// ---------------------------------------------------------------------------
// 【为什么需要】实践中出现过：某指针（此处是 I 型光标）的**备份本身是坏的**，
//   于是 mousecloak --reset / 应用 cape 时的 resetAllCursors「恢复备份」只是把坏值又装回去，
//   表现为"重置了但红点还在"。
//   ⇒ 需要一个工具能从**另一个仍然健康的备份**恢复，并同时覆盖别名（IBeam + IBeamS）。
//
// 【原理】Mousecape 的备份就是注册进 WindowServer 的指针，名字前缀
//   `com.alexzielenski.mousecape.`。本工具读出源备份的图与几何，再注册到目标名字上。
//
// 【用法】
//   ./repair-cursor --from <源备份名> --to <目标名> [--to <目标名2> ...] [--apply]
//   ./repair-cursor --sys <系统光标ID> --to <目标名> [--to ...] [--apply]
//       ★--sys 从**系统内置光标图**恢复（CoreCursorCopyImages，按 ID 取）。
//         ID→名字对照（实测 macOS 27）：
//            2 = IBeamXOR   3 = Alias   4 = Wait   5 = Copy   7 = ArrowCtx
//         适用于"连备份都被污染"的情形（备份里存的就是坏值）。
// 例（恢复 I 型光标，同时覆盖新旧两个名字）：
//   ./repair-cursor --from com.alexzielenski.mousecape.com.apple.coregraphics.IBeam \
//                   --to com.apple.coregraphics.IBeam \
//                   --to com.apple.coregraphics.IBeamS
//
// ★默认只做检查（--dry 行为）；要真正写入必须显式加 --apply。
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <unistd.h>

typedef int MCConnID;
typedef MCConnID (*FnMainConn)(void);
typedef int (*FnCopyReg)(MCConnID, char *, CGSize *, CGPoint *, NSUInteger *, CGFloat *, CFArrayRef *);
typedef int (*FnRegister)(MCConnID, char *, bool, bool, CGSize, CGPoint, NSUInteger, CGFloat, CFArrayRef, int *);
typedef int (*FnCoreCopy)(MCConnID, int, CFArrayRef *, CGSize *, CGPoint *, NSUInteger *, CGFloat *);

static FnMainConn   gMainConn;
static FnCopyReg    gCopyReg;
static FnRegister   gRegister;
static FnCoreCopy   gCoreCopy;

static BOOL LoadSkyLight(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (!h) { fprintf(stderr, "  无法加载 SkyLight\n"); return NO; }
    gMainConn  = (FnMainConn)dlsym(h, "CGSMainConnectionID");
    gCopyReg   = (FnCopyReg)dlsym(h, "CGSCopyRegisteredCursorImages");
    gRegister  = (FnRegister)dlsym(h, "CGSRegisterCursorWithImages");
    /* CoreCursor* 在 ApplicationServices（不在 SkyLight！）—— 实测过这个坑 */
    void *ah = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY);
    if (ah) gCoreCopy = (FnCoreCopy)dlsym(ah, "CoreCursorCopyImages");
    if (!gMainConn || !gCopyReg || !gRegister) { fprintf(stderr, "  SkyLight 缺符号\n"); return NO; }
    return YES;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (!LoadSkyLight()) return 2;

        NSString *from = nil;
        NSMutableArray<NSString *> *tos = [NSMutableArray array];
        BOOL apply = NO;
        int sysID = -1;
        for (int i = 1; i < argc; i++) {
            NSString *a = @(argv[i]);
            if ([a isEqualToString:@"--from"] && i + 1 < argc) from = @(argv[++i]);
            else if ([a isEqualToString:@"--to"] && i + 1 < argc) [tos addObject:@(argv[++i])];
            else if ([a isEqualToString:@"--sys"] && i + 1 < argc) sysID = atoi(argv[++i]);
            else if ([a isEqualToString:@"--apply"]) apply = YES;
            else if ([a isEqualToString:@"--dry"]) apply = NO;
        }
        if ((!from && sysID < 0) || !tos.count) {
            fprintf(stderr, "  用法: repair-cursor --from <源备份> --to <目标> [--to ...] [--apply]\n");
            fprintf(stderr, "        repair-cursor --sys <系统ID>  --to <目标> [--to ...] [--apply]\n");
            return 2;
        }

        /* 读源：--sys 取系统内置图，否则读备份指针 */
        CGSize size = CGSizeZero; CGPoint hotSpot = CGPointZero;
        NSUInteger frames = 0; CGFloat dur = 0; CFArrayRef images = NULL;
        if (sysID >= 0) {
            if (!gCoreCopy) { fprintf(stderr, "  ✗ CoreCursorCopyImages 不可用\n"); return 2; }
            int e = gCoreCopy(gMainConn(), sysID, &images, &size, &hotSpot, &frames, &dur);
            if (e != 0 || !images || CFArrayGetCount(images) == 0) {
                fprintf(stderr, "  ✗ 系统光标 ID %d 读不到 (err=%d)\n", sysID, e);
                return 3;
            }
            printf("  源: 系统内置光标 ID %d\n    几何 %.0fx%.0f 热点=(%.0f,%.0f) 帧=%lu\n",
                   sysID, size.width, size.height, hotSpot.x, hotSpot.y, (unsigned long)frames);
        } else {
            int err = gCopyReg(gMainConn(), (char *)from.UTF8String, &size, &hotSpot, &frames, &dur, &images);
            if (err != 0 || !images || CFArrayGetCount(images) == 0) {
                fprintf(stderr, "  ✗ 源备份读不到：%s (err=%d)\n", from.UTF8String, err);
                return 3;
            }
            printf("  源备份 %s\n    几何 %.0fx%.0f 热点=(%.0f,%.0f) 帧=%lu\n",
                   from.UTF8String, size.width, size.height, hotSpot.x, hotSpot.y, (unsigned long)frames);
        }
        printf("  %s\n", apply ? "模式：写入（--apply）" : "模式：演练（加 --apply 才写入）");

        int failed = 0;
        for (NSString *to in tos) {
            /* 记录目标当前值，便于回滚与对比 */
            CGSize bs = CGSizeZero; CGPoint bh = CGPointZero; NSUInteger bf = 0; CGFloat bd = 0; CFArrayRef before = NULL;
            BOOL hadBefore = (gCopyReg(gMainConn(), (char *)to.UTF8String, &bs, &bh, &bf, &bd, &before) == 0 && before);
            printf("\n  目标 %s\n    当前 %.0fx%.0f 热点=(%.0f,%.0f) 帧=%lu\n",
                   to.UTF8String, bs.width, bs.height, bh.x, bh.y, (unsigned long)bf);

            if (!apply) {
                printf("    [演练] 将把源备份的图注册到此名字\n");
                if (before) CFRelease(before);
                continue;
            }
            int seed = 0;
            int rerr = gRegister(gMainConn(), (char *)to.UTF8String, true, true,
                                 size, hotSpot, frames, dur, images, &seed);
            if (rerr != 0) { printf("    ✗ 注册失败 err=%d\n", rerr); failed++; if (before) CFRelease(before); continue; }

            /* 回读校验：成功码不等于生效，必须读回来比几何。
               ★★别名有**传播延迟**：注册 `ArrowS` 后立刻回读 `Arrow` 仍可能拿到旧值
                 （实测：注册 IBeamS 成功后马上读 IBeam 还是 8x8，稍后即为 23x22）。
                 这里先等 0.3s 再读，避免把"还没传播到"误报成失败。 */
            usleep(300000);
            CGSize as = CGSizeZero; CGPoint ah = CGPointZero; NSUInteger af = 0; CGFloat ad = 0; CFArrayRef after = NULL;
            BOOL ok = NO;
            if (gCopyReg(gMainConn(), (char *)to.UTF8String, &as, &ah, &af, &ad, &after) == 0 && after) {
                ok = fabs(as.width - size.width) < 0.5 && fabs(as.height - size.height) < 0.5 &&
                     fabs(ah.x - hotSpot.x) < 0.5 && fabs(ah.y - hotSpot.y) < 0.5 && af == frames;
                CFRelease(after);
            }
            printf("    %s 读回 %.0fx%.0f 热点=(%.0f,%.0f) 帧=%lu\n", ok ? "✅" : "✗", as.width, as.height, ah.x, ah.y, (unsigned long)af);
            if (!ok) failed++;
            if (before) CFRelease(before);
        }
        CFRelease(images);
        printf("\n  %s\n", failed ? "有目标未成功，见上。" : (apply ? "完成。" : "演练结束（未改动）。"));
        return failed ? 1 : 0;
    }
}

// audit-cursors.m —— 全面审计当前注册的鼠标指针，找出"显示不正常"的
// ---------------------------------------------------------------------------
// 【为什么需要】用户报告过 I 型光标变成一个实心色块（"红点"），
//   根因是探测/应用流程把测试图或坏值留在了系统里，且**坏值会被当成原始值备份**，形成自锁。
//   ⇒ 需要一个能一次性扫出"所有异常指针"的工具，而不是逐个目视。
//
// 【判定口径（可量化，不靠肉眼）】
//   对每个指针取首帧，转成 RGBA 后计算：
//     · 填充率 fill = 不透明像素 / 外接矩形面积
//       —— 光标图形通常是笔画/轮廓，填充率低；**实心色块接近 1.0 ⇒ 异常**
//     · 颜色数 colors = 不透明像素里不同的 RGB 组合数
//       —— 实心块 colors==1 ⇒ 异常；正常图形（含抗锯齿）通常远大于 1
//     · 尺寸 size、热点 hotspot、帧数 frames
//   异常判据：`fill ≥ 0.97 且 colors ≤ 2`（实心单色块）。
//   ★同时列出**备份**（com.alexzielenski.mousecape.*）：
//     活动值与备份值**不同**的 ⇒ 被主题改过（正常，cape 就是这样工作的）；
//     备份值**本身是实心块** ⇒ ★危险：说明备份被污染，`--reset` 会把坏值装回来。
//
// 【用法】
//   ./audit-cursors                 # 审计内置指针 + 它们的备份
//   ./audit-cursors --dump <目录>   # 同时把每个指针导出成 PNG 便于目视
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <dlfcn.h>

typedef int MCConnID;
typedef MCConnID (*FnMainConn)(void);
typedef int (*FnCopyReg)(MCConnID, char *, CGSize *, CGPoint *, NSUInteger *, CGFloat *, CFArrayRef *);

static FnMainConn gMainConn;
static FnCopyReg  gCopyReg;

static BOOL LoadSkyLight(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (!h) return NO;
    gMainConn = (FnMainConn)dlsym(h, "CGSMainConnectionID");
    gCopyReg  = (FnCopyReg)dlsym(h, "CGSCopyRegisteredCursorImages");
    return gMainConn && gCopyReg;
}

/* 内置指针（系统定义）名 —— 与 --probe 的枚举一致 */
static NSArray<NSString *> *BuiltinNames(void) {
    return @[ @"com.apple.coregraphics.Arrow", @"com.apple.coregraphics.IBeam",
              @"com.apple.coregraphics.IBeamXOR", @"com.apple.coregraphics.Alias",
              @"com.apple.coregraphics.Copy", @"com.apple.coregraphics.Move",
              @"com.apple.coregraphics.ArrowCtx", @"com.apple.coregraphics.Wait",
              @"com.apple.coregraphics.Empty",
              @"com.apple.coregraphics.ArrowS", @"com.apple.coregraphics.IBeamS" ];
}

typedef struct { BOOL ok; CGSize size; CGPoint hot; NSUInteger frames; CGFloat dur;
                 long opaque, bboxArea, colors; double fill; } CursorStats;

static BOOL ReadStats(NSString *name, CursorStats *out, CGImageRef *firstImage) {
    memset(out, 0, sizeof(*out));
    CGSize size = CGSizeZero; CGPoint hot = CGPointZero; NSUInteger frames = 0; CGFloat dur = 0;
    CFArrayRef arr = NULL;
    if (gCopyReg(gMainConn(), (char *)name.UTF8String, &size, &hot, &frames, &dur, &arr) != 0 || !arr) {
        if (arr) CFRelease(arr);
        return NO;
    }
    CGImageRef img = (CGImageRef)CFArrayGetValueAtIndex(arr, 0);
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    out->ok = YES; out->size = size; out->hot = hot; out->frames = frames; out->dur = dur;
    if (firstImage) *firstImage = CGImageRetain(img);

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 4 * w, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    unsigned char *d = CGBitmapContextGetData(ctx);

    long op = 0;
    long minx = (long)w, maxx = -1, miny = (long)h, maxy = -1;
    NSMutableSet *seen = [NSMutableSet set];
    for (size_t y = 0; y < h; y++) {
        for (size_t x = 0; x < w; x++) {
            unsigned char *p = d + (y * w + x) * 4;
            if (p[3] > 16) {
                op++;
                if ((long)x < minx) minx = x; if ((long)x > maxx) maxx = x;
                if ((long)y < miny) miny = y; if ((long)y > maxy) maxy = y;
                /* 量化到 5 位，避免抗锯齿噪声把颜色数抬得过高 */
                unsigned key = ((p[0] >> 3) << 10) | ((p[1] >> 3) << 5) | (p[2] >> 3);
                [seen addObject:@(key)];
            }
        }
    }
    out->opaque = op;
    out->colors = (long)seen.count;
    out->bboxArea = (maxx >= minx && maxy >= miny) ? (maxx - minx + 1) * (maxy - miny + 1) : 0;
    out->fill = out->bboxArea > 0 ? (double)op / (double)out->bboxArea : 0.0;
    CGContextRelease(ctx); CGColorSpaceRelease(cs); CFRelease(arr);
    return YES;
}

static void DumpPNG(NSString *dir, NSString *name, CGImageRef img) {
    if (!img) return;
    NSString *safe = [name stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString *path = [dir stringByAppendingPathComponent:[safe stringByAppendingString:@".png"]];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:path atomically:YES];
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (!LoadSkyLight()) { fprintf(stderr, "  无法加载 SkyLight\n"); return 2; }
        NSString *dumpDir = nil;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--dump") == 0 && i + 1 < argc) dumpDir = @(argv[++i]);
        }
        if (dumpDir) [[NSFileManager defaultManager] createDirectoryAtPath:dumpDir
                          withIntermediateDirectories:YES attributes:nil error:NULL];

        NSString *prefix = @"com.alexzielenski.mousecape.";
        int anomalies = 0, poisonedBackups = 0, overrides = 0;

        printf("  %-44s %9s %4s %8s %7s %6s  %s\n", "指针名", "尺寸", "帧", "填充率", "颜色数", "状态", "说明");
        printf("  %s\n", "-------------------------------------------------------------------------------------------------");

        /* ★也审计 com.apple.cursor.N 族：cape 会直接改这些名字（实测 cape 用了 3 与 5），
           且实测它与系统内置光标 ID 有映射（cursor.3↔Alias 28x40/44色、cursor.5↔Copy）。
           漏掉这一族就会"审计全绿但屏幕上仍是坏指针"。 */
        NSMutableArray<NSString *> *all = [NSMutableArray arrayWithArray:BuiltinNames()];
        for (int i = 0; i <= 45; i++) [all addObject:[NSString stringWithFormat:@"com.apple.cursor.%d", i]];

        for (NSString *name in all) {
            CursorStats st; CGImageRef img = NULL;
            if (!ReadStats(name, &st, &img)) {
                /* 未注册的名字静默跳过（com.apple.cursor.N 里多数未注册） */
                if ([name hasPrefix:@"com.apple.coregraphics."])
                    printf("  %-44s %9s %4s %8s %7s %6s  %s\n", name.UTF8String, "-", "-", "-", "-", "未注册", "");
                continue;
            }
            BOOL solid = (st.fill >= 0.97 && st.colors <= 2);
            if (solid) anomalies++;
            printf("  %-44s %4.0fx%-4.0f %4lu %8.3f %7ld %6s  %s\n",
                   name.UTF8String, st.size.width, st.size.height, (unsigned long)st.frames,
                   st.fill, st.colors, solid ? "★异常" : "正常",
                   solid ? "实心单色块（疑似残留/坏值）" : "");
            if (dumpDir) DumpPNG(dumpDir, name, img);
            if (img) CGImageRelease(img);

            /* 备份值 */
            NSString *bak = [prefix stringByAppendingString:name];
            CursorStats bs; CGImageRef bimg = NULL;
            if (ReadStats(bak, &bs, &bimg)) {
                BOOL bsolid = (bs.fill >= 0.97 && bs.colors <= 2);
                BOOL same = (fabs(bs.size.width - st.size.width) < 0.5 &&
                             fabs(bs.size.height - st.size.height) < 0.5 && bs.frames == st.frames);
                if (!same) overrides++;
                if (bsolid) poisonedBackups++;
                printf("  %-44s %4.0fx%-4.0f %4lu %8.3f %7ld %6s  %s\n",
                       [@"  └ 备份" stringByAppendingString:@""].UTF8String,
                       bs.size.width, bs.size.height, (unsigned long)bs.frames, bs.fill, bs.colors,
                       bsolid ? "★坏备份" : "正常",
                       same ? "与活动值相同（未被主题改动）"
                            : (bsolid ? "★备份本身是实心块 ⇒ --reset 会把坏值装回来"
                                      : "与活动值不同（被主题改动，正常）"));
            }
            if (bimg) CGImageRelease(bimg);
        }

        printf("\n  ── 汇总 ──\n");
        printf("    异常活动指针（实心块）: %d\n", anomalies);
        printf("    ★被污染的备份（实心块）: %d%s\n", poisonedBackups,
               poisonedBackups ? "  ⇒ 必须修复，否则 --reset 会把坏值装回来" : "");
        printf("    被主题覆盖的指针（活动值≠备份）: %d\n", overrides);
        if (dumpDir) printf("    已导出 PNG 到: %s\n", dumpDir.UTF8String);
        printf("\n  判据：fill≥0.97 且 colors≤2 ⇒ 实心单色块（异常）。\n");
        printf("        正常光标是笔画/轮廓，填充率低、颜色数多（含抗锯齿）。\n");
        return (anomalies || poisonedBackups) ? 1 : 0;
    }
}

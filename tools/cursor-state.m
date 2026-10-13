// cursor-state.m —— 读取并比对 macOS 当前注册的指针（只读工具，不改系统）
// ---------------------------------------------------------------------------
// 【为什么需要】macOS 26/27 上 `CGSRegisterCursorWithImages` 对某些名字会**返回成功但静默忽略**
//   （实测：`com.apple.coregraphics.Arrow` / `.IBeam` 在 macOS 27 上就是这样）。
//   ⇒ "返回 kCGErrorSuccess" **不能**证明指针真的换了。
//   唯一可靠的做法是：注册后用 `CGSCopyRegisteredCursorImages` 把指针**读回来**，与期望比对。
//
// 【用法】
//   ./cursor-state.m 直接由 run-verify.sh 调起；也可手动：
//     clang -fobjc-arc -framework Foundation -framework AppKit -o cursor-state cursor-state.m
//     ./cursor-state                                  # 列出内置指针当前状态
//     ./cursor-state --compare <cape 文件>            # 与 cape 定义逐像素比对
//     ./cursor-state --name com.apple.coregraphics.ArrowS   # 只查一个名字
//
// 【判据口径】cape 里的 `Representations` 是 NSData（PNG/TIFF）或 CGImage；
//   本工具取**第一帧**转成 RGBA 位图后做字节级比对。
//   ★只比第一帧：动画指针（如 Wait 是 15 帧竖排 28x600）在系统里也以首帧注册，
//     比首帧足以判断"是不是 cape 的图"。
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <dlfcn.h>

typedef int MCConnID;
typedef MCConnID (*FnMainConn)(void);
typedef int (*FnCopyRegistered)(MCConnID, char *, CGSize *, CGPoint *, NSUInteger *, CGFloat *, CFArrayRef *);

static FnMainConn        gMainConn;
static FnCopyRegistered  gCopyRegistered;

static BOOL MCLoadSkyLight(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (!h) { fprintf(stderr, "  无法加载 SkyLight: %s\n", dlerror()); return NO; }
    gMainConn       = (FnMainConn)dlsym(h, "CGSMainConnectionID");
    gCopyRegistered = (FnCopyRegistered)dlsym(h, "CGSCopyRegisteredCursorImages");
    if (!gMainConn || !gCopyRegistered) {
        fprintf(stderr, "  SkyLight 缺少所需符号（CGSMainConnectionID / CGSCopyRegisteredCursorImages）\n");
        return NO;
    }
    return YES;
}

/* CGImage → RGBA 字节（统一色彩空间，保证可比） */
static NSData *PixelsOfImage(CGImageRef img) {
    if (!img) return nil;
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    if (!w || !h) return nil;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 4 * w, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    if (!ctx) { CGColorSpaceRelease(cs); return nil; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    NSData *d = [NSData dataWithBytes:CGBitmapContextGetData(ctx) length:w * h * 4];
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return d;
}

/* 读回某个名字当前注册的指针；返回 YES 表示读到了 */
static BOOL ReadRegistered(NSString *name, CGSize *size, CGPoint *hotSpot, NSUInteger *frames, NSData **firstFramePixels) {
    CGSize s = CGSizeZero; CGPoint hp = CGPointZero; NSUInteger fc = 0; CGFloat fd = 0;
    CFArrayRef arr = NULL;
    int err = gCopyRegistered(gMainConn(), (char *)name.UTF8String, &s, &hp, &fc, &fd, &arr);
    if (err != 0 || !arr || CFArrayGetCount(arr) == 0) { if (arr) CFRelease(arr); return NO; }
    if (size) *size = s;
    if (hotSpot) *hotSpot = hp;
    if (frames) *frames = fc;
    if (firstFramePixels) *firstFramePixels = PixelsOfImage((CGImageRef)CFArrayGetValueAtIndex(arr, 0));
    CFRelease(arr);
    return YES;
}

/* 内置指针（与 mousecloak 的 MCDefs 口径一致），带 26+ 的新名字 */
static NSArray<NSString *> *BuiltinCursorNames(void) {
    return @[ @"com.apple.coregraphics.Arrow", @"com.apple.coregraphics.ArrowS",
              @"com.apple.coregraphics.IBeam", @"com.apple.coregraphics.IBeamS",
              @"com.apple.coregraphics.IBeamXOR", @"com.apple.coregraphics.Alias",
              @"com.apple.coregraphics.Copy", @"com.apple.coregraphics.Move",
              @"com.apple.coregraphics.ArrowCtx", @"com.apple.coregraphics.Wait",
              @"com.apple.coregraphics.Empty" ];
}

static CGImageRef ImageFromRepresentation(id rep) {
    if (!rep) return NULL;
    if (CFGetTypeID((__bridge CFTypeRef)rep) == CGImageGetTypeID()) return (__bridge CGImageRef)rep;
    NSBitmapImageRep *b = [[NSBitmapImageRep alloc] initWithData:rep];
    return [b CGImage];
}

static int DoCompare(NSString *capePath) {
    NSDictionary *cape = [NSDictionary dictionaryWithContentsOfFile:capePath];
    if (!cape) { fprintf(stderr, "  ✗ 无法读取 cape: %s\n", capePath.UTF8String); return 2; }
    NSDictionary *cursors = cape[@"Cursors"];
    printf("  cape: %s   定义指针 %lu 个\n\n",
           [(cape[@"CapeName"] ?: @"(未命名)") UTF8String], (unsigned long)cursors.count);

    int same = 0, diff = 0, skipped = 0;
    for (NSString *key in [cursors.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *c = cursors[key];
        NSArray *reps = c[@"Representations"];
        if (!reps.count) { skipped++; continue; }
        CGImageRef capeImg = ImageFromRepresentation(reps[0]);
        NSData *capePixels = PixelsOfImage(capeImg);
        CGSize sysSize = CGSizeZero; NSData *sysPixels = nil;
        BOOL got = ReadRegistered(key, &sysSize, NULL, NULL, &sysPixels);
        if (!capePixels || !got || !sysPixels) {
            skipped++;
            printf("  %-40s %s\n", key.UTF8String, got ? "（无法比对）" : "✗ 系统未注册");
            continue;
        }
        BOOL equal = [capePixels isEqualToData:sysPixels];
        equal ? same++ : diff++;
        printf("  %-40s cape=%2zux%-3zu sys=%2.0fx%-3.0f  %s\n",
               key.UTF8String,
               CGImageGetWidth(capeImg), CGImageGetHeight(capeImg),
               sysSize.width, sysSize.height,
               equal ? "✅ 一致（已生效）" : "✗ 不同（未生效）");
    }
    printf("\n  一致 %d / 不同 %d / 跳过 %d\n", same, diff, skipped);
    printf("  %s\n", diff == 0 ? "⇒ 所有可比对的指针都已按 cape 生效。" : "⇒ 有指针未生效（macOS 可能改了名字，见 README）。");
    return diff == 0 ? 0 : 1;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (!MCLoadSkyLight()) return 2;

        NSString *capePath = nil, *onlyName = nil;
        for (int i = 1; i < argc; i++) {
            NSString *a = @(argv[i]);
            if ([a isEqualToString:@"--compare"] && i + 1 < argc) capePath = @(argv[++i]);
            else if ([a isEqualToString:@"--name"] && i + 1 < argc) onlyName = @(argv[++i]);
        }

        if (capePath) return DoCompare(capePath);

        NSArray<NSString *> *names = onlyName ? @[ onlyName ] : BuiltinCursorNames();
        printf("== 当前 WindowServer 里注册的指针 ==\n");
        for (NSString *n in names) {
            CGSize s = CGSizeZero; CGPoint hp = CGPointZero; NSUInteger fc = 0;
            if (ReadRegistered(n, &s, &hp, &fc, NULL))
                printf("  %-40s %3.0fx%-3.0f  热点=(%.0f,%.0f)  帧=%lu\n",
                       n.UTF8String, s.width, s.height, hp.x, hp.y, (unsigned long)fc);
            else
                printf("  %-40s （未注册）\n", n.UTF8String);
        }
        printf("\n  提示：macOS 26+ 上 Arrow 与 ArrowS 会返回**同一份**数据（系统实际按 ArrowS 绘制）。\n");
        printf("        因此只注册 Arrow 而不注册 ArrowS 时，屏幕上的箭头不会改变。\n");
    }
    return 0;
}

//
//  apply.m
//  Mousecape
//
//  Created by Alex Zielenski on 2/1/14.
//  Copyright (c) 2014 Alex Zielenski. All rights reserved.
//

#import "apply.h"
#import "create.h"
#import "backup.h"
#import "restore.h"
#import "MCPrefs.h"
#import "NSBitmapImageRep+ColorSpace.h"

static BOOL cursorGeometryMatches(CGSize a, CGPoint aHotSpot, NSUInteger aFrames, CGSize b, CGPoint bHotSpot, NSUInteger bFrames) {
    return fabs(a.width - b.width) < 0.5 && fabs(a.height - b.height) < 0.5 &&
        fabs(aHotSpot.x - bHotSpot.x) < 0.5 && fabs(aHotSpot.y - bHotSpot.y) < 0.5 &&
        aFrames == bFrames;
}

// Reads the cursor back to check the WindowServer took it; if it can't be read, assume it applied as older systems always did
static MCApplyResult verifyRegisteredCursor(char *identifier, CGSize size, CGPoint hotSpot, NSUInteger frameCount) {
    CGSize registeredSize = CGSizeZero;
    CGPoint registeredHotSpot = CGPointZero;
    NSUInteger registeredFrameCount = 0;
    CGFloat registeredFrameDuration = 0;
    CFArrayRef registeredImages = NULL;
    CGError err = CGSCopyRegisteredCursorImages(CGSMainConnectionID(), identifier, &registeredSize, &registeredHotSpot, &registeredFrameCount, &registeredFrameDuration, &registeredImages);
    if (registeredImages)
        CFRelease(registeredImages);

    if (err != kCGErrorSuccess)
        return MCApplyResultApplied;

    return cursorGeometryMatches(size, hotSpot, frameCount, registeredSize, registeredHotSpot, registeredFrameCount) ? MCApplyResultApplied : MCApplyResultIgnoredBySystem;
}

MCApplyResult applyCursorForIdentifier(NSUInteger frameCount, CGFloat frameDuration, CGPoint hotSpot, CGSize size, NSArray *images, NSString *ident, NSUInteger repeatCount) {
    if (frameCount > 24 || frameCount < 1) {
        MMLog(BOLD RED "Frame count of %s out of range [1...24]", ident.UTF8String);
        return MCApplyResultFailed;
    }

    char *idenfifier = (char *)ident.UTF8String;
    // Since macOS 27 the seed is never written, so it is only passed because the call requires it
    int seed = 0;
    CGError err = CGSRegisterCursorWithImages(CGSMainConnectionID(),
                                              idenfifier,
                                              true,
                                              true,
                                              size,
                                              hotSpot,
                                              frameCount,
                                              frameDuration,
                                              (__bridge CFArrayRef)images,
                                              &seed);
    
    if (err != kCGErrorSuccess)
        return MCApplyResultFailed;

    // A success code no longer means the cursor changed, so check what the WindowServer holds
    return verifyRegisteredCursor(idenfifier, size, hotSpot, frameCount);
}

MCApplyResult applyCapeForIdentifier(NSDictionary *cursor, NSString *identifier, BOOL restore) {
    if (!cursor || !identifier) {
        NSLog(@"bad seed");
        return MCApplyResultFailed;
    }

    BOOL lefty = MCFlag(MCPreferencesHandednessKey);
    BOOL pointer = MCCursorIsPointer(identifier);
    NSNumber *frameCount    = cursor[MCCursorDictionaryFrameCountKey];
    NSNumber *frameDuration = cursor[MCCursorDictionaryFrameDuratiomKey];
    //    NSNumber *repeatCount   = cursor[MCCursorDictionaryRepeatCountKey];
    
    CGPoint hotSpot         = CGPointMake([cursor[MCCursorDictionaryHotSpotXKey] doubleValue],
                                          [cursor[MCCursorDictionaryHotSpotYKey] doubleValue]);
    CGSize size             = CGSizeMake([cursor[MCCursorDictionaryPointsWideKey] doubleValue],
                                         [cursor[MCCursorDictionaryPointsHighKey] doubleValue]);
    NSArray *reps           = cursor[MCCursorDictionaryRepresentationsKey];
    NSMutableArray *images  = [NSMutableArray array];

    if (lefty && !restore && pointer) {
        MMLog("Lefty mode for %s", identifier.UTF8String);
        hotSpot.x = size.width - hotSpot.x - 1;
    }

    for (id object in reps) {
        CFTypeID type = CFGetTypeID((__bridge CFTypeRef)object);
        NSBitmapImageRep *rep;
        if (type == CGImageGetTypeID()) {
            rep = [[[NSBitmapImageRep alloc] initWithCGImage:(__bridge CGImageRef)object] autorelease];
        } else {
            rep = [[[NSBitmapImageRep alloc] initWithData:object] autorelease];
        }
        rep = rep.retaggedSRGBSpace;

        if (!lefty || restore || !pointer) {
            // special case if array has a type of CGImage already there is no need to convert it
            if (type == CGImageGetTypeID()) {
                images[images.count] = object;
                continue;
            }
            
            images[images.count] = (__bridge id)[rep CGImage];
            
        } else {
            NSBitmapImageRep *newRep = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                               pixelsWide:rep.pixelsWide
                                                                               pixelsHigh:rep.pixelsHigh
                                                                            bitsPerSample:8
                                                                          samplesPerPixel:4
                                                                                 hasAlpha:YES
                                                                                 isPlanar:NO
                                                                           colorSpaceName:NSCalibratedRGBColorSpace
                                                                              bytesPerRow:4 * rep.pixelsWide
                                                                             bitsPerPixel:32] autorelease];
            NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:newRep];
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext setCurrentContext:ctx];
            NSAffineTransform *transform = [NSAffineTransform transform];
            [transform translateXBy:rep.pixelsWide yBy:0];
            [transform scaleXBy:-1 yBy:1];
            [transform concat];

            [rep drawInRect:NSMakeRect(0, 0, rep.pixelsWide, rep.pixelsHigh)
                   fromRect:NSZeroRect
                  operation:NSCompositingOperationSourceOver
                   fraction:1.0
             respectFlipped:NO
                      hints:nil];
            [NSGraphicsContext restoreGraphicsState];
            images[images.count] = (__bridge id)[newRep CGImage];
        }
    }
    
    return applyCursorForIdentifier(frameCount.unsignedIntegerValue, frameDuration.doubleValue, hotSpot, size, images, identifier, 0);
}

// ignoredIdentifiers, if given, receives the cursors the system kept its own images for
BOOL applyCapeReportingIgnored(NSDictionary *dictionary, NSMutableArray *ignoredIdentifiers) {
    @autoreleasepool {
        NSDictionary *cursors = dictionary[MCCursorDictionaryCursorsKey];
        NSString *name = dictionary[MCCursorDictionaryCapeNameKey];
        NSNumber *version = dictionary[MCCursorDictionaryCapeVersionKey];
        
        resetAllCursors();
        backupAllCursors();
        
        MMLog("Applying cape: %s %.02f", name.UTF8String, version.floatValue);
        
        NSMutableArray *ignored = [NSMutableArray array];
        for (NSString *key in cursors) {
            NSDictionary *cape = cursors[key];
            MMLog("Hooking for %s", key.UTF8String);
            
            MCApplyResult result = applyCapeForIdentifier(cape, key, NO);
            if (result == MCApplyResultFailed) {
                MMLog(BOLD RED "Failed to hook identifier %s for some unknown reason. Bailing out..." RESET, key.UTF8String);
                return NO;
            }

            // Newer systems draw some cursors from another name, so apply the cursor there too unless the cape has its own
            NSString *alias = cursorAliases()[key];
            bool aliasRegistered = false;
            if (alias && cursors[alias] == nil)
                MCIsCursorRegistered(CGSMainConnectionID(), (char *)alias.UTF8String, &aliasRegistered);

            if (aliasRegistered) {
                MMLog("Hooking for %s", alias.UTF8String);
                MCApplyResult aliasResult = applyCapeForIdentifier(cape, alias, NO);
                if (aliasResult == MCApplyResultApplied)
                    result = MCApplyResultApplied;
                else
                    MMLog(YELLOW "Could not also apply %s as %s" RESET, key.UTF8String, alias.UTF8String);
            }

            if (result == MCApplyResultIgnoredBySystem) {
                MMLog(YELLOW "The system kept its own cursor for %s" RESET, key.UTF8String);
                [ignored addObject:nameForCursorIdentifier(key)];
                [ignoredIdentifiers addObject:key];
            }
        }
        
        MCSetDefault(dictionary[MCCursorDictionaryIdentifierKey], MCPreferencesAppliedCursorKey);
        
        if (ignored.count == 0) {
            MMLog(BOLD GREEN "Applied %s successfully!" RESET, name.UTF8String);
        } else {
            [ignored sortUsingSelector:@selector(compare:)];
            MMLog(BOLD YELLOW "Applied %lu of %lu cursors from %s. This version of macOS does not allow replacing: %s" RESET,
                  (unsigned long)(cursors.count - ignored.count), (unsigned long)cursors.count, name.UTF8String,
                  [ignored componentsJoinedByString:@", "].UTF8String);
        }
        
        return YES;
    }
}

BOOL applyCape(NSDictionary *dictionary) {
    return applyCapeReportingIgnored(dictionary, nil);
}

BOOL applyCapeAtPathReportingIgnored(NSString *path, NSMutableArray *ignoredIdentifiers) {
    NSDictionary *cape = [NSDictionary dictionaryWithContentsOfFile:path];
    if (cape)
        return applyCapeReportingIgnored(cape, ignoredIdentifiers);
    MMLog(BOLD RED "Could not find valid file at %s to apply" RESET, path.UTF8String);
    return NO;
}

BOOL applyCapeAtPath(NSString *path) {
    return applyCapeAtPathReportingIgnored(path, nil);
}

static CGImageRef createProbeImage(size_t pixels) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, pixels, pixels, 8, 4 * pixels, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetRGBFillColor(ctx, 1, 0, 1, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, pixels, pixels));
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(space);
    return image;
}

// Registers a test image for one cursor, reads it back, then puts the original back; returns -1 if it isn't registered
static NSInteger probeCursor(NSString *key, NSArray *probeImages) {
    char *identifier = (char *)key.UTF8String;
    CGSize size = CGSizeZero;
    CGPoint hotSpot = CGPointZero;
    NSUInteger frameCount = 0;
    CGFloat frameDuration = 0;
    CFArrayRef images = NULL;
    CGError err = CGSCopyRegisteredCursorImages(CGSMainConnectionID(), identifier, &size, &hotSpot, &frameCount, &frameDuration, &images);

    // Without the original there would be nothing to put back, so leave the cursor alone
    if (err != kCGErrorSuccess || !images || CFArrayGetCount(images) == 0) {
        if (images)
            CFRelease(images);
        return -1;
    }

    CGSize probeSize = CGSizeMake(32, 32);
    CGPoint probeHotSpot = CGPointMake(7, 9);
    if (cursorGeometryMatches(size, hotSpot, frameCount, probeSize, probeHotSpot, 1))
        probeHotSpot = CGPointMake(9, 7);

    MCApplyResult result = applyCursorForIdentifier(1, 0, probeHotSpot, probeSize, probeImages, key, 0);

    /* ★★恢复原指针必须**回读校验**（成功码不代表生效），并在失败时重试几次。
       ★为什么重要：`--probe` 会先把一张测试图（纯洋红）注册到该名字上。
         若恢复失败又没被察觉，**测试图就会留在系统里** ——
         实测出现过 I 型光标停在 8x8 实心色块（悬停在文字上显示成一个色点）。
         而且更糟的是：只要这个坏值还在，之后 `backupCursorForIdentifier` 会把**坏值当原始值备份**，
         于是"重置"只会把坏值再装回去，形成自锁。
       ⇒ 恢复后回读；不一致就重试（别名传播有延迟）；仍失败则明确报错并给出修复命令。 */
    int seed = 0;
    BOOL restored = NO;
    for (int attempt = 0; attempt < 3 && !restored; attempt++) {
        CGSRegisterCursorWithImages(CGSMainConnectionID(), identifier, true, true, size, hotSpot, frameCount, frameDuration, images, &seed);
        if (attempt > 0) usleep(200000);   /* 别名传播有延迟，等一下再读 */
        restored = (verifyRegisteredCursor(identifier, size, hotSpot, frameCount) == MCApplyResultApplied);
    }
    if (!restored)
        MMLog(BOLD RED "  Could not put the original %s back after 3 tries. "
              "Run `mousecloak --reset`, or `repair-cursor` from the macos27 project, "
              "otherwise the probe image may stay on screen until logout." RESET, key.UTF8String);
    CFRelease(images);

    return result;
}

// Reports which built-in cursors this system lets Mousecape replace, under their original or newer names
void probeCursorOverrides(void) {
    @autoreleasepool {
        CGImageRef probeImage = createProbeImage(64);
        NSArray *probeImages = @[ (__bridge id)probeImage ];
        NSUInteger blockedCount = 0;

        MMLog(BOLD "Probing which cursors this version of macOS lets Mousecape replace..." RESET);

        NSUInteger i = 0;
        NSString *key = nil;
        while ((key = defaultCursors[i++]) != nil) {
            NSInteger result = probeCursor(key, probeImages);
            NSString *alias = cursorAliases()[key];
            NSInteger aliasResult = alias ? probeCursor(alias, probeImages) : -1;

            const char *outcome;
            if (result == -1) {
                outcome = "not registered, skipped";
            } else if (result == MCApplyResultApplied) {
                outcome = GREEN "replaceable" RESET;
            } else if (aliasResult == MCApplyResultApplied) {
                outcome = GREEN "replaceable" RESET " (the system draws it from its newer name)";
            } else {
                outcome = result == MCApplyResultIgnoredBySystem ? YELLOW "kept by the system" RESET : RED "failed to register" RESET;
                blockedCount++;
            }
            MMLog("  %-12s %s", key.pathExtension.UTF8String, outcome);

            if (aliasResult != -1) {
                const char *aliasOutcome = aliasResult == MCApplyResultApplied ? GREEN "replaceable" RESET :
                    aliasResult == MCApplyResultIgnoredBySystem ? YELLOW "kept by the system" RESET : RED "failed to register" RESET;
                MMLog("    %-10s %s", alias.pathExtension.UTF8String, aliasOutcome);
            }
        }

        CGImageRelease(probeImage);
        if (blockedCount == 0)
            MMLog(BOLD GREEN "Every built-in cursor can be replaced on this system." RESET);
        else
            MMLog(BOLD "%lu built-in cursor(s) cannot be replaced on this system." RESET, (unsigned long)blockedCount);
    }
}

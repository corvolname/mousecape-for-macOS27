//
//  MCLibraryController.m
//  Mousecape
//
//  Created by Alex Zielenski on 2/2/14.
//  Copyright (c) 2014 Alex Zielenski. All rights reserved.
//

#import "MCLibraryController.h"
#import "NSOrderedSet+AZSortedInsert.h"
#import "apply.h"
#import "restore.h"
#import "create.h"
/* ★2026-10-16：应用主题后确保"登录时自动恢复"的登录项已装（与 GUI/mousecloak 共用实现） */
#import "loginitem.h"

static NSString *const MCSuppressIgnoredCursorsNoticeKey = @"MCSuppressIgnoredCursorsNotice";

@interface MCLibraryController ()
@property (nonatomic, readwrite, strong) NSUndoManager *undoManager;
@property (nonatomic, retain) NSMutableSet *capes;
@property (readwrite, copy) NSURL *libraryURL;
@property (readwrite, weak) MCCursorLibrary *appliedCape;
- (void)loadLibrary;
- (void)willSaveNotification:(NSNotification *)note;
@end

@implementation MCLibraryController

- (NSURL *)URLForCape:(MCCursorLibrary *)cape {
    return [NSURL fileURLWithPathComponents:@[ self.libraryURL.path, [cape.identifier stringByAppendingPathExtension:@"cape"] ]];;
}

- (instancetype)initWithURL:(NSURL *)url {
    if ((self = [self init])) {
        self.libraryURL = url;
        self.undoManager = [[NSUndoManager alloc] init];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willSaveNotification:) name:MCLibraryWillSaveNotificationName object:nil];
        [self loadLibrary];
    }
    
    return self;
}

- (void)loadLibrary {
    [self.undoManager disableUndoRegistration];
    
    self.capes = [NSMutableSet set];
    NSString *capesPath = self.libraryURL.path;
    NSArray  *contents  = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:capesPath error:NULL];
    NSString *applied   = [NSUserDefaults.standardUserDefaults stringForKey:MCPreferencesAppliedCursorKey];

    for (NSString *filename in contents) {
        // Ignore hidden files like .DS_Store
        if ([filename hasPrefix:@"."])
            continue;

        NSURL *fileURL = [NSURL fileURLWithPathComponents:@[ capesPath, filename ]];
        MCCursorLibrary *library = [MCCursorLibrary cursorLibraryWithContentsOfURL:fileURL];
        
        if ([library.identifier isEqualToString:applied]) {
            self.appliedCape = library;
        }
        
        [self addCape:library];
    }
    
    [self.undoManager enableUndoRegistration];
}

- (void)importCapeAtURL:(NSURL *)url {
    [self importCape:[MCCursorLibrary cursorLibraryWithContentsOfURL:url]];
}

- (void)importCape:(MCCursorLibrary *)lib {
    if ([[self.capes valueForKeyPath:@"identifier"] containsObject:lib.identifier]) {
        lib.identifier = [lib.identifier stringByAppendingFormat:@".%@", UUID()];
    }

    lib.fileURL = [self URLForCape:lib];
    [lib writeToFile:lib.fileURL.path atomically:NO];
    
    [self addCape:lib];
}


- (void)addCape:(MCCursorLibrary *)cape {
    if ([self.capes containsObject:cape] || [[self.capes valueForKeyPath:@"identifier"] containsObject:cape.identifier]) {
        NSLog(@"Not adding %@ to the library because an object with that identifier already exists", cape.identifier);
        return;
    }
        
    if (!cape) {
        NSLog(@"Cannot add nil cape");
        return;
    }

    NSSet *change = [NSSet setWithObject:cape];
    [self willChangeValueForKey:@"capes" withSetMutation:NSKeyValueUnionSetMutation usingObjects:change];

    cape.library = self;
    [self.capes addObject:cape];

    [[self.undoManager prepareWithInvocationTarget:self] removeCape:cape];
    if (!self.undoManager.isUndoing) {
        [self.undoManager setActionName:[@"Add " stringByAppendingString:cape.name]];
    }
    
    [self didChangeValueForKey:@"capes" withSetMutation:NSKeyValueUnionSetMutation usingObjects:change];

    [cape.undoManager removeAllActions];
}


- (void)removeCape:(MCCursorLibrary *)cape {
    NSSet *change = [NSSet setWithObject:cape];
    
    [self willChangeValueForKey:@"capes" withSetMutation:NSKeyValueMinusSetMutation usingObjects:change];
    if (cape == self.appliedCape)
        [self restoreCape];

    if (cape.library == self)
        cape.library = nil;
    
    [self.capes removeObject:cape];
    
    // Move the file to the trash
    NSFileManager *manager = [NSFileManager defaultManager];
    NSURL *destinationURL = [NSURL fileURLWithPath:[[@"~/.Trash" stringByExpandingTildeInPath] stringByAppendingPathComponent:cape.fileURL.lastPathComponent] isDirectory:NO];
    
    [manager removeItemAtURL:destinationURL error:NULL];
    [manager moveItemAtURL:cape.fileURL toURL:destinationURL error:NULL];

    [[self.undoManager prepareWithInvocationTarget:self] importCapeAtURL:destinationURL];
    if (!self.undoManager.isUndoing) {
        [self.undoManager setActionName:[@"Remove " stringByAppendingString:cape.name]];
    }
    
    [self didChangeValueForKey:@"capes" withSetMutation:NSKeyValueMinusSetMutation usingObjects:change];
}

- (void)applyCape:(MCCursorLibrary *)cape {
    NSMutableArray *ignored = [NSMutableArray array];
    if (applyCapeAtPathReportingIgnored(cape.fileURL.path, ignored)) {
        self.appliedCape = cape;
        [self showIgnoredCursorsNotice:ignored forCape:cape];
        /* ★★2026-10-16：应用成功后再确保"登录时自动恢复"的登录项已装。
           为什么放在这里（而不只放在 App 启动时）：
             · 用户可能"先装 app、之后才导入并应用主题" ⇒ 启动那一刻还没有 cape，装不了；
             · 此刻 `applyCapeAtPath` 已把偏好 MCAppliedCursor 写好 ⇒ 路径必然可解析。
           ★幂等：已装则直接返回，不重复写 plist / 不重复 bootstrap。
           ★失败不打扰用户：它只是"重启后是否能自动恢复"的增强，不该阻塞"应用主题"本身。 */
        [self ensureLoginPersistenceInstalled];
    }
}

- (void)reapplyCape:(MCCursorLibrary *)cape {
    if (applyCapeAtPath(cape.fileURL.path)) {
        self.appliedCape = cape;
        [self ensureLoginPersistenceInstalled];   /* 同上：幂等地确保登录项在位 */
    }
}

/* ★2026-10-16：确保"登录时自动恢复游标"的登录项已装（幂等）。
   登录项执行的是 app 内的 mousecloak（不是 GUI 自己）。 */
- (void)ensureLoginPersistenceInstalled {
    if (MCLoginPersistenceInstalled()) return;
    NSString *exe = NSBundle.mainBundle.executablePath;
    if (exe.length == 0) return;
    exe = [exe.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"mousecloak"];
    NSError *e = nil;
    if (MCSetLoginPersistenceEnabled(YES, exe, &e)) {
        NSLog(@"[Mousecape] login persistence installed after applying a cape");
    } else {
        NSLog(@"[Mousecape] login persistence install failed: %@", e.localizedDescription);
    }
}

// If the system kept its own image for a cursor, say so rather than let the cape look like it didn't apply
- (void)showIgnoredCursorsNotice:(NSArray *)identifiers forCape:(MCCursorLibrary *)cape {
    if (identifiers.count == 0 || [[NSUserDefaults standardUserDefaults] boolForKey:MCSuppressIgnoredCursorsNoticeKey])
        return;

    NSMutableArray *names = [NSMutableArray array];
    for (NSString *identifier in identifiers) {
        [names addObject:nameForCursorIdentifier(identifier)];
    }
    [names sortUsingSelector:@selector(compare:)];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = NSLocalizedString(@"Some cursors weren't replaced", @"Ignored cursors notice title");
    alert.informativeText = [NSString stringWithFormat:NSLocalizedString(@"This version of macOS doesn't let apps replace these cursors: %@. The rest of “%@” was applied.", @"Ignored cursors notice description"),
                             [names componentsJoinedByString:@", "], cape.name];
    alert.showsSuppressionButton = YES;
    [alert addButtonWithTitle:NSLocalizedString(@"OK", @"Ignored cursors notice dismiss button")];

    void (^handler)(NSModalResponse) = ^(NSModalResponse response) {
        if (alert.suppressionButton.state == NSControlStateValueOn)
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:MCSuppressIgnoredCursorsNoticeKey];
    };

    NSWindow *window = NSApp.mainWindow ?: NSApp.keyWindow;
    if (window) {
        [alert beginSheetModalForWindow:window completionHandler:handler];
    } else {
        handler([alert runModal]);
    }
}

- (void)restoreCape {
    resetAllCursors();
    self.appliedCape = nil;
}

- (NSSet *)capesWithIdentifier:(NSString *)identifier {
    NSPredicate *pred = [NSPredicate predicateWithFormat:@"identifier == %@", identifier];
    return [self.capes filteredSetUsingPredicate:pred];
}

- (void)willSaveNotification:(NSNotification *)note {
    MCCursorLibrary *cape = note.object;
    NSURL *oldURL = cape.fileURL;
    [cape setFileURL:[self URLForCape:cape]];
    NSError *error = nil;
    [[NSFileManager defaultManager] removeItemAtURL:oldURL error:&error];

    if (error) {
        NSLog(@"error removing cape after rename: %@", error);
    }

}

- (BOOL)dumpCursorsWithProgressBlock:(BOOL (^)(NSUInteger current, NSUInteger total))block {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat: @"%@ (%f).cape",
                       NSLocalizedString(@"Mousecape Dump", @"Mousecape dump cursor file name"),
                       NSDate.date.timeIntervalSince1970]];
    if (dumpCursorsToFile(path, block)) {
        __weak MCLibraryController *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf importCapeAtURL:[NSURL fileURLWithPath:path]];
        });
        return YES;
    }

    return NO;
}

@end

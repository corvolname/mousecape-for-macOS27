//
//  MCLbraryWindowController.m
//  Mousecape
//
//  Created by Alex Zielenski on 2/2/14.
//  Copyright (c) 2014 Alex Zielenski. All rights reserved.
//

#import "MCLibraryWindowController.h"

@interface MCLibraryWindowController ()
- (void)composeAccessory;
@end

@implementation MCLibraryWindowController

- (void)awakeFromNib {
    [self composeAccessory];
}

- (id)initWithWindow:(NSWindow *)window {
    if ((self = [super initWithWindow:window])) {
        
    }
    return self;
}

- (void)windowDidLoad {
    NSLog(@"window load");
    [super windowDidLoad];
    [self composeAccessory];
}

- (NSString *)windowNibName {
    return @"Library";
}

- (void)composeAccessory {
    /* ★★2026-10-16 修正「顶部错位」（用户反馈："mousecape 在顶部都是错位的"）。
       原实现：把 accessory 加到 **themeFrame**（＝整个窗口框，**含标题栏**）上，
       并用 `V:|-(0)-[accessory(20)]-(>=22)-|` 钉在**最顶端**
       ⇒ 落在标题栏里，把标题栏标题压住/裁掉。
       中间试过"放进 contentView"：标题栏恢复正常了，但 accessory 会**压在 cape 卡片上**。
       ⇒ 最终做法（也是这个视图本来的用途，nib 里它的 autoresizing 就是"贴右上"）：
         交给 **NSTitlebarAccessoryViewController**，由 AppKit 放进**标题栏右侧**。
         这样标题栏与内容区都不受影响，也随窗口缩放自动停在右上角。
       ★幂等：awakeFromNib 与 windowDidLoad 都会调它，重复调用时先摘掉旧的。 */
    NSWindow *window = self.window;
    NSView *accessory = self.appliedAccessory;
    if (!window || !accessory) return;

    for (NSTitlebarAccessoryViewController *vc in window.titlebarAccessoryViewControllers) {
        if (vc.view == accessory) return;          /* 已就位 */
    }
    if (accessory.superview) [accessory removeFromSuperview];

    NSTitlebarAccessoryViewController *tavc = [[NSTitlebarAccessoryViewController alloc] init];
    tavc.view = accessory;
    tavc.layoutAttribute = NSLayoutAttributeRight;   /* 停标题栏右侧 */
    [window addTitlebarAccessoryViewController:tavc];
}



- (NSUndoManager *)windowWillReturnUndoManager:(NSWindow *)window {
    return self.libraryViewController.libraryController.undoManager;
}

#pragma mark - Menu Actions

- (IBAction)applyCapeAction:(NSMenuItem *)sender {
    MCCursorLibrary *cape = nil;
    if (sender.tag == -1)
        cape = self.libraryViewController.clickedCape;
    else
        cape = self.libraryViewController.selectedCape;
    
    [self.libraryViewController.libraryController applyCape:cape];
}

- (IBAction)editCapeAction:(NSMenuItem *)sender {
    MCCursorLibrary *cape = nil;
    if (sender.tag == -1)
        cape = self.libraryViewController.clickedCape;
    else
        cape = self.libraryViewController.selectedCape;
    
    [self.libraryViewController editCape:cape];
}

- (IBAction)removeCapeAction:(NSMenuItem *)sender {
    MCCursorLibrary *cape = nil;
    if (sender.tag == -1)
        cape = self.libraryViewController.clickedCape;
    else
        cape = self.libraryViewController.selectedCape;
    
    if (cape != self.libraryViewController.editingCape) {
        [self.libraryViewController.libraryController removeCape:cape];
    } else {
        [[NSSound soundNamed:@"Funk"] play];
        [self.libraryViewController editCape:self.libraryViewController.editingCape];
    }
}

- (IBAction)duplicateCapeAction:(NSMenuItem *)sender {
    MCCursorLibrary *cape = nil;
    if (sender.tag == -1)
        cape = self.libraryViewController.clickedCape;
    else
        cape = self.libraryViewController.selectedCape;
    
    [self.libraryViewController.libraryController importCape:cape.copy];
}

- (IBAction)checkCapeAction:(NSMenuItem *)sender {
    
}

- (IBAction)showCapeAction:(NSMenuItem *)sender {
    MCCursorLibrary *cape = nil;
    if (sender.tag == -1)
        cape = self.libraryViewController.clickedCape;
    else
        cape = self.libraryViewController.selectedCape;
    
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ cape.fileURL ]];
}

- (IBAction)dumpCapeAction:(NSMenuItem *)sender {
    [self.window beginSheet:self.progressBar.window completionHandler:nil];
    __weak MCLibraryWindowController *weakSelf = self;
    self.progressBar.doubleValue = 0.0;
    [self.progressBar setIndeterminate:NO];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        [weakSelf.libraryViewController.libraryController dumpCursorsWithProgressBlock:^BOOL (NSUInteger current, NSUInteger total) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                weakSelf.progressField.stringValue = [NSString stringWithFormat:@"%lu %@ %lu", (unsigned long)current, NSLocalizedString(@"of", @"Dump cursor progress separator (eg: 5 of 129)"), (unsigned long)total];
                weakSelf.progressBar.minValue = 0;
                weakSelf.progressBar.maxValue = total;
                weakSelf.progressBar.doubleValue = current;
            });
            return YES;
        }];

        dispatch_sync(dispatch_get_main_queue(), ^{
            [weakSelf.window endSheet:self.progressBar.window];
            [[NSCursor arrowCursor] set];
        });
    });

}

@end

@implementation MCAppliedCapeValueTransformer

+ (Class)transformedValueClass {
    return [NSString class];
}

- (id)transformedValue:(id)value {
    return [
            NSLocalizedString(@"Applied Cape: ", @"Accessory label for applied cape")
            stringByAppendingString:value ? value : NSLocalizedString(@"None", @"Window Titlebar Accessory label for when no cape is applied")];
}

@end

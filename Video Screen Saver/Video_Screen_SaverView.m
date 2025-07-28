//
//  Video_Screen_SaverView.m
//  Video Screen Saver
//
//  Created by sim on 28.07.25.
//

#import "Video_Screen_SaverView.h"
#import <Cocoa/Cocoa.h>
#import <ScreenSaver/ScreenSaver.h>

@interface Video_Screen_SaverView ()
@property (strong) NSWindow *configSheet;
@property (strong) NSTextField *folderLabel;
@end

@implementation Video_Screen_SaverView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview
{
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        [self setAnimationTimeInterval:1/30.0];
    }
    return self;
}

- (void)startAnimation
{
    [super startAnimation];
}

- (void)stopAnimation
{
    [super stopAnimation];
}

- (void)drawRect:(NSRect)rect
{
    [super drawRect:rect];
}

- (void)animateOneFrame
{
    return;
}

- (BOOL)hasConfigureSheet
{
    return YES;
}

- (NSWindow*)configureSheet
{
    if (!self.configSheet) {
        NSRect frame = NSMakeRect(0, 0, 400, 140);
        self.configSheet = [[NSWindow alloc] initWithContentRect:frame
                                                       styleMask:(NSWindowStyleMaskTitled)
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        self.configSheet.title = @"Select Video Folder";
        NSView *contentView = self.configSheet.contentView;
        // Folder label
        self.folderLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 90, 360, 24)];
        self.folderLabel.editable = NO;
        self.folderLabel.bezeled = NO;
        self.folderLabel.drawsBackground = NO;
        self.folderLabel.selectable = NO;
        [contentView addSubview:self.folderLabel];
        // Choose Folder button
        NSButton *chooseButton = [[NSButton alloc] initWithFrame:NSMakeRect(20, 50, 120, 32)];
        chooseButton.title = @"Choose Folder…";
        chooseButton.bezelStyle = NSBezelStyleRounded;
        chooseButton.target = self;
        chooseButton.action = @selector(chooseFolderClicked:);
        [contentView addSubview:chooseButton];
        // OK button
        NSButton *okButton = [[NSButton alloc] initWithFrame:NSMakeRect(300, 10, 80, 32)];
        okButton.title = @"OK";
        okButton.bezelStyle = NSBezelStyleRounded;
        okButton.target = self;
        okButton.action = @selector(closeConfigSheet:);
        [contentView addSubview:okButton];
    }
    [self updateFolderLabel];
    return self.configSheet;
}

- (void)chooseFolderClicked:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"Select";
    [panel beginSheetModalForWindow:self.configSheet completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            NSURL *url = panel.URL;
            if (url) {
                ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
                [defaults setObject:url.path forKey:@"videoFolderPath"];
                [defaults synchronize];
                [self updateFolderLabel];
            }
        }
    }];
}

- (void)closeConfigSheet:(id)sender {
    [NSApp endSheet:self.configSheet];
}

- (void)updateFolderLabel {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    NSString *folder = [defaults stringForKey:@"videoFolderPath"];
    if (folder && folder.length > 0) {
        self.folderLabel.stringValue = [NSString stringWithFormat:@"Selected folder: %@", folder];
    } else {
        self.folderLabel.stringValue = @"No folder selected.";
    }
}

@end

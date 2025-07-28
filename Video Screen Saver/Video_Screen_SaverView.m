//
//  Video_Screen_SaverView.m
//  Video Screen Saver
//
//  Created by sim on 28.07.25.
//

#import "Video_Screen_SaverView.h"
#import <Cocoa/Cocoa.h>
#import <ScreenSaver/ScreenSaver.h>
#import <AVFoundation/AVFoundation.h>
#import <os/log.h>

@interface Video_Screen_SaverView ()
@property (strong) NSWindow *configSheet;
@property (strong) NSTextField *folderLabel;

// Video playback properties
@property (strong) AVPlayer *player;
@property (strong) AVPlayerLayer *playerLayer;
@property (strong) NSArray<NSURL *> *videoURLs;
@property (assign) NSUInteger currentVideoIndex;
@end

@implementation Video_Screen_SaverView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview
{
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        [self setAnimationTimeInterval:1/30.0];
        self.wantsLayer = YES;
        os_log(OS_LOG_DEFAULT, "Video Screen Saver: Initializing screensaver view");
        // Do not call loadVideosAndPreparePlayer here!
    }
    return self;
}

- (void)startAnimation
{
    [super startAnimation];
    [self loadVideosAndPreparePlayer]; // Only load videos when animation starts!
    if (self.player) {
        os_log(OS_LOG_DEFAULT, "Video Screen Saver: Starting playback");
        [self.player play];
    }
}

- (void)stopAnimation
{
    [super stopAnimation];
    if (self.player) {
        os_log(OS_LOG_DEFAULT, "Video Screen Saver: Stopping playback");
        [self.player pause];
    }
}

- (void)drawRect:(NSRect)rect
{
    [super drawRect:rect];
    // AVPlayerLayer will handle drawing the video
}

- (void)animateOneFrame
{
    // No-op: AVPlayer handles playback
}

- (BOOL)checkFolderPermission:(NSString *)folderPath
{
    BOOL isDir = NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:folderPath isDirectory:&isDir];
    if (!exists || !isDir) {
        os_log(OS_LOG_DEFAULT, "Video Screen Saver: Folder does not exist or is not a directory: %{public}@", folderPath);
        return NO;
    }

    // Check if readable
    BOOL canRead = [[NSFileManager defaultManager] isReadableFileAtPath:folderPath];
    if (!canRead) {
        os_log(OS_LOG_DEFAULT, "Video Screen Saver: No read permission for folder: %{public}@", folderPath);
        return NO;
    }
    return YES;
}

- (void)loadVideosAndPreparePlayer {
    // Remove existing layer/player if any
    if (self.playerLayer) {
        [self.playerLayer removeFromSuperlayer];
        self.playerLayer = nil;
    }
    self.player = nil;
    self.videoURLs = nil;
    self.currentVideoIndex = 0;

    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    NSString *folder = [defaults stringForKey:@"videoFolderPath"];
    if (!folder || folder.length == 0) {
        os_log(OS_LOG_DEFAULT, "Video Screen Saver: No folder selected");
        return;
    }
    os_log(OS_LOG_DEFAULT, "Video Screen Saver: Selected folder: %{public}@", folder);

    if (![self checkFolderPermission:folder]) {
        os_log(OS_LOG_DEFAULT, "Video Screen Saver: Permission check failed for folder: %{public}@", folder);
        return;
    }
    NSURL *folderURL = [NSURL fileURLWithPath:folder];

    // Find all mp4, mov, m4v video files in the folder
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *dirError = nil;
    NSArray *files = [fm contentsOfDirectoryAtURL:folderURL includingPropertiesForKeys:nil options:0 error:&dirError];
    if (dirError) {
        os_log(OS_LOG_DEFAULT, "Video Screen Saver: Failed to enumerate folder: %{public}@", dirError.localizedDescription);
        return;
    }
    NSPredicate *videoPredicate = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
        NSString *ext = url.pathExtension.lowercaseString;
        return [@[@"mp4", @"mov", @"m4v"] containsObject:ext];
    }];
    self.videoURLs = [files filteredArrayUsingPredicate:videoPredicate];
    os_log(OS_LOG_DEFAULT, "Video Screen Saver: Found %lu supported video(s) in folder", (unsigned long)self.videoURLs.count);
    for (NSURL *url in self.videoURLs) {
        os_log(OS_LOG_DEFAULT, "Video Screen Saver: Video file: %{public}@", url.path);
    }
    if (self.videoURLs.count == 0) {
        os_log(OS_LOG_DEFAULT, "Video Screen Saver: No supported video files found in folder");
        return;
    }

    // Play the first video
    [self playVideoAtIndex:0];
}

- (void)playVideoAtIndex:(NSUInteger)index {
    if (self.videoURLs.count == 0) return;
    NSURL *url = self.videoURLs[index];
    os_log(OS_LOG_DEFAULT, "Video Screen Saver: Playing video at index %lu: %{public}@", (unsigned long)index, url.path);

    self.player = [AVPlayer playerWithURL:url];
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;

    // Remove previous playerLayer if any
    if (self.playerLayer) {
        [self.playerLayer removeFromSuperlayer];
    }
    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.frame = self.bounds;
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.layer addSublayer:self.playerLayer];
    });

    // Loop video and move to next when finished
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerItemDidReachEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:self.player.currentItem];

    // Check if player is ready and can play
    [self.player.currentItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:nil];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context
{
    if ([keyPath isEqualToString:@"status"]) {
        AVPlayerItem *item = (AVPlayerItem *)object;
        if (item.status == AVPlayerItemStatusFailed) {
            os_log(OS_LOG_DEFAULT, "Video Screen Saver: AVPlayerItem failed: %{public}@", item.error.localizedDescription);
        } else if (item.status == AVPlayerItemStatusReadyToPlay) {
            os_log(OS_LOG_DEFAULT, "Video Screen Saver: AVPlayerItem ready to play");
            [self.player play];
        } else {
            os_log(OS_LOG_DEFAULT, "Video Screen Saver: AVPlayerItem status unknown");
        }
        [item removeObserver:self forKeyPath:@"status"];
    }
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    // Play next video, or loop to first
    self.currentVideoIndex = (self.currentVideoIndex + 1) % self.videoURLs.count;
    os_log(OS_LOG_DEFAULT, "Video Screen Saver: Video finished, moving to index %lu", (unsigned long)self.currentVideoIndex);
    [self playVideoAtIndex:self.currentVideoIndex];
    [self.player play];
}

- (void)layout {
    [super layout];
    if (self.playerLayer) {
        self.playerLayer.frame = self.bounds;
    }
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
                // Reload videos after folder is changed
                // Only reload if animating, let animation handle reload otherwise
                if ([self isAnimating]) {
                    [self loadVideosAndPreparePlayer];
                }
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

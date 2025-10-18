#import "Video_Screen_SaverView.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>

#define kVideoFolderDefaultsKey @"VideoScreenSaverFolderPath"

@interface Video_Screen_SaverView () {
    AVPlayerView *_playerView;
    AVQueuePlayer *_queuePlayer;
    NSArray<NSURL *> *_videoURLs;
    id _itemEndObserver;
}
@end

@implementation Video_Screen_SaverView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        [self setAnimationTimeInterval:1/30.0];
        [self setupPlayerView];
        [self loadVideosAndPlay];
    }
    return self;
}

- (void)setupPlayerView {
    _playerView = [[AVPlayerView alloc] initWithFrame:self.bounds];
    _playerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _playerView.controlsStyle = AVPlayerViewControlsStyleNone;
    _playerView.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _queuePlayer = [[AVQueuePlayer alloc] init];
    _queuePlayer.actionAtItemEnd = AVPlayerActionAtItemEndAdvance;
    _playerView.player = _queuePlayer;
    [self addSubview:_playerView];

    // Observer to automatically queue next video
    __weak typeof(self) weakSelf = self;
    _itemEndObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                                          object:nil
                                                                           queue:[NSOperationQueue mainQueue]
                                                                      usingBlock:^(NSNotification *note) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_videoURLs.count > 0) {
            // Queue the next video
            NSURL *nextURL = strongSelf->_videoURLs[arc4random_uniform((uint32_t)strongSelf->_videoURLs.count)];
            AVPlayerItem *nextItem = [AVPlayerItem playerItemWithURL:nextURL];
            [strongSelf->_queuePlayer insertItem:nextItem afterItem:nil];
        }
    }];
}

- (void)loadVideosAndPlay {
    NSString *folderPath = [[NSUserDefaults standardUserDefaults] stringForKey:kVideoFolderDefaultsKey];
    if (!folderPath) return;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folderPath error:nil];
    NSMutableArray<NSURL *> *videoURLs = [NSMutableArray array];
    for (NSString *file in files) {
        if ([file.pathExtension.lowercaseString isEqualToString:@"mp4"] ||
            [file.pathExtension.lowercaseString isEqualToString:@"mov"] ||
            [file.pathExtension.lowercaseString isEqualToString:@"m4v"]) {
            NSURL *url = [NSURL fileURLWithPath:[folderPath stringByAppendingPathComponent:file]];
            [videoURLs addObject:url];
        }
    }
    _videoURLs = videoURLs;

    if (_videoURLs.count == 0) return;

    [_queuePlayer removeAllItems];

    // Queue initial videos - start with 2 to enable smooth transitions
    for (int i = 0; i < MIN(2, (int)_videoURLs.count); i++) {
        NSURL *url = _videoURLs[arc4random_uniform((uint32_t)_videoURLs.count)];
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
        [_queuePlayer insertItem:item afterItem:nil];
    }

    [_queuePlayer play];
}

- (void)stopAnimation {
    [super stopAnimation];
    [_queuePlayer pause];
    [_queuePlayer removeAllItems];
}

- (void)dealloc {
    if (_itemEndObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_itemEndObserver];
        _itemEndObserver = nil;
    }
    [_queuePlayer pause];
    [_queuePlayer removeAllItems];
    _queuePlayer = nil;
    _playerView.player = nil;
}

#pragma mark - Config Sheet

- (NSWindow *)configureSheet {
    if (!self.configureSheet) {
        NSView *contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 120)];

        NSButton *chooseButton = [[NSButton alloc] initWithFrame:NSMakeRect(20, 60, 200, 32)];
        [chooseButton setTitle:@"Choose Video Folder..."];
        [chooseButton setButtonType:NSButtonTypeMomentaryPushIn];
        [chooseButton setBezelStyle:NSBezelStyleRounded];
        [chooseButton setTarget:self];
        [chooseButton setAction:@selector(chooseFolderClicked:)];
        [contentView addSubview:chooseButton];

        NSButton *okButton = [[NSButton alloc] initWithFrame:NSMakeRect(140, 20, 80, 32)];
        [okButton setTitle:@"OK"];
        [okButton setButtonType:NSButtonTypeMomentaryPushIn];
        [okButton setBezelStyle:NSBezelStyleRounded];
        [okButton setTarget:self];
        [okButton setAction:@selector(okClicked:)];
        [contentView addSubview:okButton];

        NSButton *cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(50, 20, 80, 32)];
        [cancelButton setTitle:@"Cancel"];
        [cancelButton setButtonType:NSButtonTypeMomentaryPushIn];
        [cancelButton setBezelStyle:NSBezelStyleRounded];
        [cancelButton setTarget:self];
        [cancelButton setAction:@selector(cancelClicked:)];
        [contentView addSubview:cancelButton];

        self.configureSheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 240, 120)
                                                          styleMask:NSWindowStyleMaskTitled
                                                            backing:NSBackingStoreBuffered
                                                              defer:NO];
        [self.configureSheet setContentView:contentView];
        [self.configureSheet setTitle:@"Video Screen Saver Settings"];
    }
    return self.configureSheet;
}

- (void)okClicked:(id)sender {
    [NSApp endSheet:self.configureSheet];
}

- (void)cancelClicked:(id)sender {
    [NSApp endSheet:self.configureSheet];
}

- (void)chooseFolderClicked:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.allowsMultipleSelection = NO;
    panel.directoryURL = [NSURL fileURLWithPath:@"/Users/Shared/"];
    [panel beginSheetModalForWindow:self.configureSheet completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            NSString *selectedPath = panel.URL.path;
            [[NSUserDefaults standardUserDefaults] setObject:selectedPath forKey:kVideoFolderDefaultsKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self loadVideosAndPlay];
        }
    }];
}

@end

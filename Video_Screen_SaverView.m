#import "Video_Screen_SaverView.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>

#define kVideoFolderDefaultsKey @"VideoScreenSaverFolderPath"

@interface Video_Screen_SaverView () {
    AVPlayerView *_playerView;
    NSArray<NSURL *> *_videoURLs;
    NSUInteger _currentVideoIndex;
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
    [self addSubview:_playerView];
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
    _currentVideoIndex = 0;
    [self playCurrentVideo];
}

- (void)playCurrentVideo {
    if (_videoURLs.count == 0) return;
    AVPlayer *player = [AVPlayer playerWithURL:_videoURLs[_currentVideoIndex]];
    _playerView.player = player;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerItemDidReachEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:player.currentItem];
    [player play];
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:notification.object];
    _currentVideoIndex = (_currentVideoIndex + 1) % _videoURLs.count;
    [self playCurrentVideo];
}

#pragma mark - Config Sheet

- (NSWindow *)configureSheet {
    NSButton *chooseButton = [[NSButton alloc] initWithFrame:NSMakeRect(20, 20, 200, 32)];
    [chooseButton setTitle:@"Choose Video Folder..."];
    [chooseButton setButtonType:NSButtonTypeMomentaryPushIn];
    [chooseButton setBezelStyle:NSBezelStyleRounded];
    [chooseButton setTarget:self];
    [chooseButton setAction:@selector(chooseFolderClicked:)];

    NSView *contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 72)];
    [contentView addSubview:chooseButton];

    NSWindow *sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 240, 72)
                                                  styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    [sheet setContentView:contentView];
    [sheet setTitle:@"Video Screen Saver Settings"];
    return sheet;
}

- (void)chooseFolderClicked:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.allowsMultipleSelection = NO;
    panel.directoryURL = [NSURL fileURLWithPath:@"/Users/Shared/"];
    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            NSString *selectedPath = panel.URL.path;
            [[NSUserDefaults standardUserDefaults] setObject:selectedPath forKey:kVideoFolderDefaultsKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self loadVideosAndPlay];
        }
    }];
}

@end

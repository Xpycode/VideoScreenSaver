//
//  Video_Screen_SaverView.m
//  Video Screen Saver
//
//  Created by sim on 28.07.25.
//
//  Core implementation containing lifecycle methods and shared utilities.
//  Playback logic is in Video_Screen_SaverView+Playback.m
//  Configuration UI is in Video_Screen_SaverView+ConfigSheet.m
//

#import "Video_Screen_SaverView_Private.h"
#import "Video_Screen_SaverView+Playback.h"
#import "Video_Screen_SaverView+ConfigSheet.h"
#import <Cocoa/Cocoa.h>
#import <ScreenSaver/ScreenSaver.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <os/log.h>

#pragma mark - Constants

// UserDefaults Keys
NSString * const kVideoFolderBookmarkKey = @"videoFolderBookmark";
NSString * const kVideoFoldersBookmarksKey = @"videoFoldersBookmarks";
NSString * const kShuffleKey = @"shuffle";
NSString * const kLoopKey = @"loop";
NSString * const kTransitionTypeKey = @"transitionType";
NSString * const kTransitionDurationKey = @"transitionDuration";
NSString * const kVideoScalingKey = @"videoScaling";
NSString * const kRecursiveScanKey = @"recursiveScan";

// KVO context
void * const kPlayerItemStatusContext = (void*)&kPlayerItemStatusContext;

// Animation and Performance Constants
const NSTimeInterval kAnimationInterval = 1.0;
const NSInteger kPreviewConcurrentLoadLimit = 2;
const NSInteger kNormalConcurrentLoadLimit = 4;

// UI Constants
const CGFloat kFolderTableHeight = 115.0;
const double kMinTransitionDuration = 0.5;
const double kMaxTransitionDuration = 5.0;

// Custom logging subsystem for better Console.app filtering
os_log_t VideoScreenSaverLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.lucesumbrarum.VideoScreenSaver", "playback");
    });
    return log;
}

#pragma mark - Implementation

@implementation Video_Screen_SaverView

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview
{
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        // AVPlayer handles its own rendering - we only need occasional checks
        // Reduce from 30fps to 1fps to minimize CPU overhead
        [self setAnimationTimeInterval:kAnimationInterval];
        self.wantsLayer = YES;

        // Initialize observer tracking
        self.observedItems = [NSMutableSet set];

        // Initialize security-scoped resource tracking
        self.accessedFolderURLs = [NSMutableSet set];

        ScreenSaverDefaults *defaults = [self screenSaverDefaults];
        [defaults registerDefaults:@{
            kShuffleKey: @NO,
            kLoopKey: @YES,
            kTransitionTypeKey: @(TransitionTypeCrossDissolve),
            kTransitionDurationKey: @1.5,
            kVideoScalingKey: @(VideoScalingFill),
            kRecursiveScanKey: @NO
        }];
    }
    return self;
}

- (void)dealloc {
    // Ensure everything is cleaned up
    [self stopAnimation];

    // Clean up configuration sheet if it exists
    if (self.configSheet) {
        [self.configSheet orderOut:nil];
        self.configSheet = nil;
    }
    self.folderBookmarks = nil;

    // Final cleanup - release player objects
    self.playerA = nil;
    self.playerB = nil;
    self.playerLayerA = nil;
    self.playerLayerB = nil;
}

- (void)startAnimation
{
    [super startAnimation];
    self.isPreparingNextVideo = NO;

    // --- Create Player Infrastructure ---
    ScreenSaverDefaults *defaults = [self screenSaverDefaults];

    self.playerA = [[AVPlayer alloc] init];
    self.playerB = [[AVPlayer alloc] init];
    // Force mute all players unconditionally to solve audio issues.
    self.playerA.muted = YES;
    self.playerB.muted = YES;
    self.playerA.preventsDisplaySleepDuringVideoPlayback = NO;
    self.playerB.preventsDisplaySleepDuringVideoPlayback = NO;
    self.playerA.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    self.playerB.actionAtItemEnd = AVPlayerActionAtItemEndNone;

    self.playerLayerA = [AVPlayerLayer playerLayerWithPlayer:self.playerA];
    self.playerLayerB = [AVPlayerLayer playerLayerWithPlayer:self.playerB];

    // Set black background to prevent previous video from showing through
    self.playerLayerA.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    self.playerLayerB.backgroundColor = CGColorGetConstantColor(kCGColorBlack);

    self.playerViewA = [[NSView alloc] initWithFrame:self.bounds];
    self.playerViewA.wantsLayer = YES;
    self.playerViewA.layer = self.playerLayerA;
    self.playerViewA.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    self.playerViewB = [[NSView alloc] initWithFrame:self.bounds];
    self.playerViewB.wantsLayer = YES;
    self.playerViewB.layer = self.playerLayerB;
    self.playerViewB.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSString *videoGravity = [self videoGravityFromScaling:(VideoScaling)[defaults integerForKey:kVideoScalingKey]];
    self.playerLayerA.videoGravity = videoGravity;
    self.playerLayerB.videoGravity = videoGravity;

    self.playerLayerA.contentsScale = [self currentBackingScaleFactor];
    self.playerLayerB.contentsScale = [self currentBackingScaleFactor];

    // Ensure at least one player view is visible from the start
    if (!self.playerViewA.superview && !self.playerViewB.superview) {
        [self addSubview:self.playerViewA];
        self.activePlayerView = self.playerViewA;
        self.activePlayer = self.playerA;
    }

    [self loadPlaylistAndStartPlayback];
}

- (void)stopAnimation
{
    [super stopAnimation];

    // --- Full Player Teardown ---
    // 1. Pause players to stop all playback immediately.
    [self.playerA pause];
    [self.playerB pause];
    self.playerA.muted = YES;
    self.playerB.muted = YES;

    // 2. Remove all notification observers associated with this object.
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    // 3. Remove the boundary time observer if it exists.
    if (self.timeObserverToken) {
        AVPlayer *playerForToken = self.activePlayer ?: (self.playerA ?: self.playerB);
        if (playerForToken) {
            [playerForToken removeTimeObserver:self.timeObserverToken];
        }
        self.timeObserverToken = nil;
    }

    // 4. Safely remove all KVO observers.
    @synchronized(self.observedItems) {
        NSSet<AVPlayerItem *> *itemsToRemove = [self.observedItems copy];
        for (AVPlayerItem *item in itemsToRemove) {
            @try {
                [item removeObserver:self forKeyPath:@"status" context:kPlayerItemStatusContext];
            } @catch (NSException *exception) {
                // Ignore errors if observer isn't registered.
            }
        }
        [self.observedItems removeAllObjects];
    }

    // 5. Detach player items from players.
    [self.playerA replaceCurrentItemWithPlayerItem:nil];
    [self.playerB replaceCurrentItemWithPlayerItem:nil];

    // 6. Detach players from layers.
    self.playerLayerA.player = nil;
    self.playerLayerB.player = nil;

    // 7. Remove views from the hierarchy.
    [self.playerViewA removeFromSuperview];
    [self.playerViewB removeFromSuperview];

    // 8. Nil out all properties to deallocate the objects.
    self.playerA = nil;
    self.playerB = nil;
    self.playerLayerA = nil;
    self.playerLayerB = nil;
    self.playerViewA = nil;
    self.playerViewB = nil;
    self.playerItemA = nil;
    self.playerItemB = nil;
    self.activePlayer = nil;
    self.activePlayerView = nil;
    self.videoURLs = nil;
    self.videoDurations = nil;
    self.isPreparingNextVideo = NO;

    // 9. Release security-scoped folder access
    for (NSURL *folderURL in self.accessedFolderURLs) {
        [folderURL stopAccessingSecurityScopedResource];
    }
    [self.accessedFolderURLs removeAllObjects];

    // 10. Remove message text layer if present
    [self removeMessageTextLayer];
}

- (void)animateOneFrame {
    // Intentionally empty.
    // AVPlayer and AVPlayerLayer handle all video rendering automatically.
}

- (void)layout {
    [super layout];
    // Player view frames are managed by autoresizing masks.
}

#pragma mark - Helper Methods

- (ScreenSaverDefaults *)screenSaverDefaults {
    static ScreenSaverDefaults *_defaults;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    });
    return _defaults;
}

- (UTType *)typeFromContentTypeValue:(id)contentType {
    if ([contentType isKindOfClass:[UTType class]]) {
        return (UTType *)contentType;
    } else if ([contentType isKindOfClass:[NSString class]]) {
        return [UTType typeWithIdentifier:(NSString *)contentType];
    }
    return nil;
}

- (CGFloat)currentBackingScaleFactor {
    if (self.isPreview) {
        return 1.0;
    }
    NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
    return screen.backingScaleFactor;
}

- (NSString *)videoGravityFromScaling:(VideoScaling)scaling {
    switch (scaling) {
        case VideoScalingFit:
            return AVLayerVideoGravityResizeAspect;
        case VideoScalingStretch:
            return AVLayerVideoGravityResize;
        case VideoScalingFill:
        default:
            return AVLayerVideoGravityResizeAspectFill;
    }
}

- (void)removeMessageTextLayer {
    if (self.messageTextLayer) {
        [self.messageTextLayer removeFromSuperlayer];
        self.messageTextLayer = nil;
    }
}

- (void)restartAnimationWithDelay {
    [self stopAnimation];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self startAnimation];
    });
}

@end

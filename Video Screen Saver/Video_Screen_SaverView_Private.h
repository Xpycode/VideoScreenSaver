//
//  Video_Screen_SaverView_Private.h
//  Video Screen Saver
//
//  Private header for internal use by category implementations.
//  DO NOT import this header from external code.
//

#import "Video_Screen_SaverView.h"
#import <AVFoundation/AVFoundation.h>
#import <os/log.h>

// UserDefaults Keys
extern NSString * const kVideoFolderBookmarkKey;
extern NSString * const kVideoFoldersBookmarksKey;
extern NSString * const kShuffleKey;
extern NSString * const kLoopKey;
extern NSString * const kTransitionTypeKey;
extern NSString * const kTransitionDurationKey;
extern NSString * const kVideoScalingKey;
extern NSString * const kRecursiveScanKey;

// KVO context
extern void * const kPlayerItemStatusContext;

// Animation and Performance Constants
extern const NSTimeInterval kAnimationInterval;
extern const NSInteger kPreviewConcurrentLoadLimit;
extern const NSInteger kNormalConcurrentLoadLimit;

// UI Constants
extern const CGFloat kFolderTableHeight;
extern const double kMinTransitionDuration;
extern const double kMaxTransitionDuration;

// Custom logging
os_log_t VideoScreenSaverLog(void);

typedef NS_ENUM(NSInteger, TransitionType) {
    TransitionTypeNone,
    TransitionTypeFade,
    TransitionTypeCrossDissolve
};

typedef NS_ENUM(NSInteger, VideoScaling) {
    VideoScalingFill,
    VideoScalingFit,
    VideoScalingStretch
};

@interface Video_Screen_SaverView () <NSTableViewDelegate, NSTableViewDataSource>

// Configuration Sheet Properties
@property (strong) NSWindow *configSheet;
@property (strong) NSButton *shuffleCheckbox;
@property (strong) NSButton *loopCheckbox;
@property (strong) NSPopUpButton *transitionPopUpButton;
@property (strong) NSSlider *durationSlider;
@property (strong) NSTextField *durationLabel;
@property (strong) NSPopUpButton *scalingPopUpButton;
@property (strong) NSButton *recursiveScanCheckbox;

// Single-pane UI Properties
@property (strong) NSTableView *foldersTableView;
@property (strong) NSMutableArray<NSData *> *folderBookmarks;
@property (strong) NSTextField *emptyStateLabel;
@property (strong) NSTextField *statsLabel;

// Video playback properties
@property (strong) NSArray<NSURL *> *videoURLs;
@property (strong) NSDictionary<NSURL *, NSValue *> *videoDurations;
@property (assign) NSInteger currentVideoIndex;
@property (assign) BOOL isPreparingNextVideo;
@property (assign) NSInteger consecutiveFailures;

// Dual Player System for seamless transitions
@property (strong) AVPlayer *playerA;
@property (strong) AVPlayerLayer *playerLayerA;
@property (strong) NSView *playerViewA;
@property (strong) AVPlayerItem *playerItemA;
@property (strong) AVPlayer *playerB;
@property (strong) AVPlayerLayer *playerLayerB;
@property (strong) NSView *playerViewB;
@property (strong) AVPlayerItem *playerItemB;
@property (weak) AVPlayer *activePlayer;
@property (weak) NSView *activePlayerView;

// Timeline Observer
@property (strong) id timeObserverToken;

// KVO tracking
@property (strong) NSMutableSet<AVPlayerItem *> *observedItems;

// Security-scoped resource tracking
@property (strong) NSMutableSet<NSURL *> *accessedFolderURLs;

// Message text layer tracking
@property (strong) CATextLayer *messageTextLayer;

// Internal methods exposed for categories
- (ScreenSaverDefaults *)screenSaverDefaults;
- (UTType *)typeFromContentTypeValue:(id)contentType;
- (CGFloat)currentBackingScaleFactor;
- (NSString *)videoGravityFromScaling:(VideoScaling)scaling;
- (void)removeMessageTextLayer;
- (void)restartAnimationWithDelay;

@end

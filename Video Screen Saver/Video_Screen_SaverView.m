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
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <os/log.h>

// UserDefaults Keys
static NSString * const kVideoFolderBookmarkKey = @"videoFolderBookmark";
static NSString * const kVideoFoldersBookmarksKey = @"videoFoldersBookmarks"; // Array of bookmarks
static NSString * const kEnableAudioKey = @"enableAudio";
static NSString * const kShuffleKey = @"shuffle";
static NSString * const kLoopKey = @"loop";
static NSString * const kTransitionTypeKey = @"transitionType";
static NSString * const kTransitionDurationKey = @"transitionDuration";
static NSString * const kVideoScalingKey = @"videoScaling";
static NSString * const kRecursiveScanKey = @"recursiveScan";

// KVO context
static void * const kPlayerItemStatusContext = (void*)&kPlayerItemStatusContext;

typedef NS_ENUM(NSInteger, TransitionType) {
    TransitionTypeNone,
    TransitionTypeFade,
    TransitionTypeCrossDissolve
};

typedef NS_ENUM(NSInteger, VideoScaling) {
    VideoScalingFill,       // AVLayerVideoGravityResizeAspectFill - Fill screen, crop if needed
    VideoScalingFit,        // AVLayerVideoGravityResizeAspect - Fit with letterboxing
    VideoScalingStretch     // AVLayerVideoGravityResize - Stretch to fill (distorts aspect)
};

@interface Video_Screen_SaverView () <NSTableViewDelegate, NSTableViewDataSource>

// Configuration Sheet Properties
@property (strong) NSWindow *configSheet;
@property (strong) NSTextField *folderLabel;
@property (strong) NSButton *enableAudioCheckbox;
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

// Video playback properties
@property (strong) NSArray<NSURL *> *videoURLs;
@property (strong) NSDictionary<NSURL *, NSValue *> *videoDurations;
@property (assign) NSInteger currentVideoIndex;
@property (assign) BOOL isPreparingNextVideo; // Race condition guard

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

// KVO tracking - use a set to track all observed items
@property (strong) NSMutableSet<AVPlayerItem *> *observedItems;

@end

@implementation Video_Screen_SaverView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview
{
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        // AVPlayer handles its own rendering - we only need occasional checks
        // Reduce from 30fps to 1fps to minimize CPU overhead
        [self setAnimationTimeInterval:1.0];
        self.wantsLayer = YES;

        // Initialize observer tracking
        self.observedItems = [NSMutableSet set];

        ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
        [defaults registerDefaults:@{
            kEnableAudioKey: @YES,
            kShuffleKey: @NO,
            kLoopKey: @YES,
            kTransitionTypeKey: @(TransitionTypeCrossDissolve),
            kTransitionDurationKey: @1.5,
            kVideoScalingKey: @(VideoScalingFill),
            kRecursiveScanKey: @NO
        }];
        
        self.playerA = [[AVPlayer alloc] init];
        self.playerB = [[AVPlayer alloc] init];

        // Optimize player for screen saver use
        self.playerA.preventsDisplaySleepDuringVideoPlayback = NO;
        self.playerB.preventsDisplaySleepDuringVideoPlayback = NO;
        self.playerA.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        self.playerB.actionAtItemEnd = AVPlayerActionAtItemEndNone;

        self.playerLayerA = [AVPlayerLayer playerLayerWithPlayer:self.playerA];
        self.playerLayerB = [AVPlayerLayer playerLayerWithPlayer:self.playerB];

        // Create views to host the player layers
        self.playerViewA = [[NSView alloc] initWithFrame:self.bounds];
        self.playerViewA.wantsLayer = YES;
        self.playerViewA.layer = self.playerLayerA;
        self.playerViewA.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        self.playerViewB = [[NSView alloc] initWithFrame:self.bounds];
        self.playerViewB.wantsLayer = YES;
        self.playerViewB.layer = self.playerLayerB;
        self.playerViewB.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        // Apply saved video scaling preference
        NSString *videoGravity = [self videoGravityFromScaling:(VideoScaling)[defaults integerForKey:kVideoScalingKey]];
        self.playerLayerA.videoGravity = videoGravity;
        self.playerLayerB.videoGravity = videoGravity;

        // Frame is managed by the view's autoresizing mask
        // self.playerLayerA.frame = self.bounds;
        // self.playerLayerB.frame = self.bounds;

        // Optimize rendering performance
        self.playerLayerA.contentsScale = isPreview ? 1.0 : [[NSScreen mainScreen] backingScaleFactor];
        self.playerLayerB.contentsScale = isPreview ? 1.0 : [[NSScreen mainScreen] backingScaleFactor];
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

    // Ensure at least one player view is visible from the start
    if (!self.playerViewA.superview && !self.playerViewB.superview) {
        [self addSubview:self.playerViewA];
        self.activePlayerView = self.playerViewA;
        self.activePlayer = self.playerA;
    }

    // The view's autoresizing mask handles frame changes, so manual frame setting is not needed here.

    [self loadPlaylistAndStartPlayback];
}

- (void)stopAnimation
{
    [super stopAnimation];

    // Remove all notification observers first
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    // Remove time observer
    if (self.timeObserverToken) {
        if (self.activePlayer) {
            [self.activePlayer removeTimeObserver:self.timeObserverToken];
        }
        self.timeObserverToken = nil;
    }

    // Pause and clear players immediately
    [self.playerA pause];
    [self.playerB pause];

    // Safely remove all KVO observers
    for (AVPlayerItem *item in [self.observedItems copy]) {
        @try {
            [item removeObserver:self forKeyPath:@"status" context:kPlayerItemStatusContext];
        } @catch (NSException *exception) {
            // Item was already deallocated or observer wasn't registered
        }
    }
    [self.observedItems removeAllObjects];

    // Clear player items
    [self.playerA replaceCurrentItemWithPlayerItem:nil];
    [self.playerB replaceCurrentItemWithPlayerItem:nil];
    self.playerItemA = nil;
    self.playerItemB = nil;

    // Remove views from hierarchy
    [self.playerViewA removeFromSuperview];
    [self.playerViewB removeFromSuperview];

    // Clear references
    self.activePlayerView = nil;
    self.activePlayer = nil;
    self.isPreparingNextVideo = NO;
    self.videoURLs = nil;
    self.videoDurations = nil;
}

- (void)animateOneFrame { }

- (void)loadPlaylistAndStartPlayback {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];

    // Try new multiple folders format first
    NSArray *bookmarksArray = [defaults objectForKey:kVideoFoldersBookmarksKey];
    NSMutableArray<NSURL *> *allVideoURLs = [NSMutableArray array];

    if (bookmarksArray != nil) {
        // New format exists (even if empty array) - use it
        if ([bookmarksArray isKindOfClass:[NSArray class]] && bookmarksArray.count > 0) {
            // Multiple folders mode
            for (id bookmarkObject in bookmarksArray) {
                if (![bookmarkObject isKindOfClass:[NSData class]]) continue;

                NSURL *folderURL = [NSURL URLByResolvingBookmarkData:bookmarkObject
                                                             options:NSURLBookmarkResolutionWithSecurityScope
                                                       relativeToURL:nil
                                                 bookmarkDataIsStale:NULL
                                                               error:NULL];
                if (!folderURL) continue;

                if ([folderURL startAccessingSecurityScopedResource]) {
                    NSArray<NSURL *> *folderVideos = [self getVideoURLsFromFolder:folderURL];
                    [allVideoURLs addObjectsFromArray:folderVideos];
                    [folderURL stopAccessingSecurityScopedResource];
                }
            }
        }
        // else: empty array means user removed all folders - don't migrate!
    } else {
        // New format doesn't exist at all - try migration from legacy single folder
        id bookmarkObject = [defaults objectForKey:kVideoFolderBookmarkKey];
        if (bookmarkObject && [bookmarkObject isKindOfClass:[NSData class]]) {
            NSURL *folderURL = [NSURL URLByResolvingBookmarkData:bookmarkObject
                                                         options:NSURLBookmarkResolutionWithSecurityScope
                                                   relativeToURL:nil
                                             bookmarkDataIsStale:NULL
                                                           error:NULL];
            if (folderURL && [folderURL startAccessingSecurityScopedResource]) {
                allVideoURLs = [[self getVideoURLsFromFolder:folderURL] mutableCopy];
                [folderURL stopAccessingSecurityScopedResource];

                // Migrate to new format
                [defaults setObject:@[bookmarkObject] forKey:kVideoFoldersBookmarksKey];
                [defaults synchronize];
            }
        }
    }

    self.videoURLs = [allVideoURLs copy];

    if ([defaults boolForKey:kShuffleKey] && self.videoURLs.count > 1) {
        self.videoURLs = [self shuffledArrayFromArray:self.videoURLs];
    }

    if (self.videoURLs.count > 0) {
        [self loadVideoDurationsWithCompletion:^{
            self.currentVideoIndex = -1;
            [self prepareNextVideo];
        }];
    }
}

- (void)prepareNextVideo {
    // Guard against being called multiple times in quick succession.
    if (self.isPreparingNextVideo) {
        return;
    }
    self.isPreparingNextVideo = YES;
    
    NSInteger nextVideoIndex = self.currentVideoIndex + 1;
    if (nextVideoIndex >= self.videoURLs.count) {
        if ([[ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"] boolForKey:kLoopKey]) {
            nextVideoIndex = 0;
        } else {
            // Let the last video finish. We're not preparing another.
            self.isPreparingNextVideo = NO;
            return;
        }
    }
    
    self.currentVideoIndex = nextVideoIndex;
    NSURL *url = self.videoURLs[self.currentVideoIndex];
    AVPlayerItem *playerItem = [AVPlayerItem playerItemWithURL:url];

    if (self.activePlayer == self.playerA || self.activePlayer == nil) {
        // Player B is inactive, prepare it.
        // Remove observer from old item if it exists
        if (self.playerItemB && [self.observedItems containsObject:self.playerItemB]) {
            @try {
                [self.playerItemB removeObserver:self forKeyPath:@"status" context:kPlayerItemStatusContext];
                [self.observedItems removeObject:self.playerItemB];
            } @catch (NSException *exception) {}
        }
        self.playerItemB = playerItem;
        [self.playerB replaceCurrentItemWithPlayerItem:self.playerItemB];
        [self.playerItemB addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:kPlayerItemStatusContext];
        [self.observedItems addObject:self.playerItemB];
    } else {
        // Player A is inactive, prepare it.
        // Remove observer from old item if it exists
        if (self.playerItemA && [self.observedItems containsObject:self.playerItemA]) {
            @try {
                [self.playerItemA removeObserver:self forKeyPath:@"status" context:kPlayerItemStatusContext];
                [self.observedItems removeObject:self.playerItemA];
            } @catch (NSException *exception) {}
        }
        self.playerItemA = playerItem;
        [self.playerA replaceCurrentItemWithPlayerItem:self.playerItemA];
        [self.playerItemA addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:kPlayerItemStatusContext];
        [self.observedItems addObject:self.playerItemA];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (context == kPlayerItemStatusContext) {
        AVPlayerItem *playerItem = (AVPlayerItem *)object;
        if (playerItem.status == AVPlayerItemStatusReadyToPlay) {
            // The item is buffered and ready. We can now transition.
            // Remove the observer now that we've handled the status change
            if ([self.observedItems containsObject:playerItem]) {
                @try {
                    [playerItem removeObserver:self forKeyPath:@"status" context:kPlayerItemStatusContext];
                    [self.observedItems removeObject:playerItem];
                } @catch (NSException *exception) {}
            }

            BOOL isPlayerA = (playerItem == self.playerItemA);
            AVPlayer *newPlayer = isPlayerA ? self.playerA : self.playerB;
            NSView *newView = isPlayerA ? self.playerViewA : self.playerViewB;
            
            // Perform the transition, now guaranteed to have a frame to show.
            [self performTransitionFrom:self.activePlayerView to:newView];
            
            // Update the active player references.
            AVPlayer *oldPlayer = self.activePlayer;
            self.activePlayer = newPlayer;
            self.activePlayerView = newView;

            // Clean up the old player's time observer.
            if (self.timeObserverToken && oldPlayer) {
                [oldPlayer removeTimeObserver:self.timeObserverToken];
                self.timeObserverToken = nil;
            }
            
            // Configure and start the new player.
            ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
            self.activePlayer.muted = ![defaults boolForKey:kEnableAudioKey];
            [self.activePlayer play];

            // Set up observers to prepare the *next* video.
            [self setupBoundaryTimeObserverForURL:((AVURLAsset *)playerItem.asset).URL];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerItemDidReachEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:playerItem];

            // Unlock to allow the next video to be prepared.
            self.isPreparingNextVideo = NO;
            
        } else if (playerItem.status == AVPlayerItemStatusFailed) {
            // Handle failure. Log error and try the next video.
            os_log(OS_LOG_DEFAULT, "VideoScreenSaver: Player item failed to load with error: %@", playerItem.error);

            // Remove the observer for the failed item
            if ([self.observedItems containsObject:playerItem]) {
                @try {
                    [playerItem removeObserver:self forKeyPath:@"status" context:kPlayerItemStatusContext];
                    [self.observedItems removeObject:playerItem];
                } @catch (NSException *exception) {}
            }

            // Unlock and immediately try to prepare the next video in the playlist.
            self.isPreparingNextVideo = NO;
            [self prepareNextVideo];
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)setupBoundaryTimeObserverForURL:(NSURL *)url {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    TransitionType transition = (TransitionType)[defaults integerForKey:kTransitionTypeKey];
    if (transition == TransitionTypeNone || self.videoURLs.count < 2) {
        return; // No need for an observer if there's no transition or only one video
    }
    
    NSValue *durationValue = self.videoDurations[url];
    if (!durationValue) return;

    CMTime videoDuration = [durationValue CMTimeValue];
    double transitionDuration = [defaults doubleForKey:kTransitionDurationKey];
    CMTime transitionTime = CMTimeMakeWithSeconds(transitionDuration, videoDuration.timescale);
    CMTime boundaryTime = CMTimeSubtract(videoDuration, transitionTime);
    
    if (CMTIME_IS_INVALID(boundaryTime) || CMTimeCompare(boundaryTime, kCMTimeZero) < 0) {
        return; // Video is shorter than the transition
    }
    
    __weak typeof(self) weakSelf = self;
    self.timeObserverToken = [self.activePlayer addBoundaryTimeObserverForTimes:@[[NSValue valueWithCMTime:boundaryTime]] queue:dispatch_get_main_queue() usingBlock:^{
        // This block will be executed only once.
        if (weakSelf.timeObserverToken) {
            [weakSelf.activePlayer removeTimeObserver:weakSelf.timeObserverToken];
            weakSelf.timeObserverToken = nil;
        }
        [weakSelf prepareNextVideo];
    }];
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:notification.object];
    
    BOOL isLastVideo = (self.currentVideoIndex == self.videoURLs.count - 1);
    BOOL isLooping = [[ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"] boolForKey:kLoopKey];

    if (isLastVideo && !isLooping) {
        [self stopAnimation]; // Or let it sit on the last frame. Stopping seems cleaner.
    } else {
        [self prepareNextVideo];
    }
}

- (void)performTransitionFrom:(NSView *)oldView to:(NSView *)newView {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    TransitionType transition = (TransitionType)[defaults integerForKey:kTransitionTypeKey];
    double duration = [defaults doubleForKey:kTransitionDurationKey];
    
    if (transition == TransitionTypeNone || oldView == nil) {
        if (oldView) [oldView removeFromSuperview];
        [self addSubview:newView];
        return;
    }

    if (transition == TransitionTypeCrossDissolve) {
        newView.alphaValue = 0.0;
        [self addSubview:newView];
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
            context.duration = duration;
            newView.animator.alphaValue = 1.0;
            if (oldView) {
                oldView.animator.alphaValue = 0.0;
            }
        } completionHandler:^{
            if (oldView) {
                [oldView removeFromSuperview];
                oldView.alphaValue = 1.0; // Reset for next use
            }
        }];
    } else if (transition == TransitionTypeFade) {
        [self addSubview:newView positioned:NSWindowBelow relativeTo:oldView];
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
            context.duration = duration;
            if (oldView) {
                oldView.animator.alphaValue = 0.0;
            }
        } completionHandler:^{
            if (oldView) {
                [oldView removeFromSuperview];
                oldView.alphaValue = 1.0; // Reset for next use
            }
        }];
    }
}

- (void)layout {
    [super layout];
    // Player view frames are managed by autoresizing masks.
}

#pragma mark - Helper Methods

- (NSArray<NSURL *> *)getVideoURLsFromFolder:(NSURL *)folderURL {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    BOOL recursiveScan = [defaults boolForKey:kRecursiveScanKey];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSURL *> *videoURLs = [NSMutableArray array];

    if (recursiveScan) {
        // Recursive enumeration - scans all subdirectories
        NSDirectoryEnumerator<NSURL *> *enumerator = [fm enumeratorAtURL:folderURL
                                              includingPropertiesForKeys:@[NSURLContentTypeKey, NSURLIsDirectoryKey]
                                                                 options:NSDirectoryEnumerationSkipsHiddenFiles
                                                            errorHandler:^BOOL(NSURL *url, NSError *error) {
            os_log(OS_LOG_DEFAULT, "VideoScreenSaver: Error reading %@: %@", url, error);
            return YES; // Continue enumeration
        }];

        for (NSURL *fileURL in enumerator) {
            NSNumber *isDirectory = nil;
            [fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];

            // Skip directories, we only want files
            if ([isDirectory boolValue]) {
                continue;
            }

            id contentType = nil;
            NSError *utiError = nil;
            [fileURL getResourceValue:&contentType forKey:NSURLContentTypeKey error:&utiError];

            if (contentType && !utiError) {
                UTType *type = nil;
                // macOS 26 returns UTType directly, older versions return NSString
                if ([contentType isKindOfClass:[UTType class]]) {
                    type = (UTType *)contentType;
                } else if ([contentType isKindOfClass:[NSString class]]) {
                    type = [UTType typeWithIdentifier:(NSString *)contentType];
                }

                if (type && [type conformsToType:UTTypeMovie]) {
                    [videoURLs addObject:fileURL];
                }
            }
        }
    } else {
        // Non-recursive - only scan top level
        NSError *dirError = nil;
        NSArray<NSURL *> *files = [fm contentsOfDirectoryAtURL:folderURL
                                  includingPropertiesForKeys:@[NSURLContentTypeKey]
                                                     options:NSDirectoryEnumerationSkipsHiddenFiles
                                                       error:&dirError];
        if (dirError) {
            os_log(OS_LOG_DEFAULT, "VideoScreenSaver: Error reading directory: %@", dirError);
            return @[];
        }

        for (NSURL *fileURL in files) {
            id contentType = nil;
            NSError *utiError = nil;
            [fileURL getResourceValue:&contentType forKey:NSURLContentTypeKey error:&utiError];

            if (contentType && !utiError) {
                UTType *type = nil;
                // macOS 26 returns UTType directly, older versions return NSString
                if ([contentType isKindOfClass:[UTType class]]) {
                    type = (UTType *)contentType;
                } else if ([contentType isKindOfClass:[NSString class]]) {
                    type = [UTType typeWithIdentifier:(NSString *)contentType];
                }

                if (type && [type conformsToType:UTTypeMovie]) {
                    [videoURLs addObject:fileURL];
                }
            }
        }
    }

    return [videoURLs copy];
}

- (NSArray<NSURL *> *)shuffledArrayFromArray:(NSArray<NSURL *> *)array {
    NSMutableArray *shuffled = [array mutableCopy];
    for (NSUInteger i = shuffled.count - 1; i > 0; i--) {
        [shuffled exchangeObjectAtIndex:i withObjectAtIndex:arc4random_uniform((uint32_t)i + 1)];
    }
    return [shuffled copy];
}

- (void)loadVideoDurationsWithCompletion:(void (^)(void))completion {
    NSMutableDictionary<NSURL *, NSValue *> *durations = [NSMutableDictionary dictionary];
    dispatch_group_t group = dispatch_group_create();

    // In preview mode or with many videos, limit the number of concurrent loads
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(self.isPreview ? 2 : 4);

    for (NSURL *url in self.videoURLs) {
        dispatch_group_enter(group);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

            AVAsset *asset = [AVAsset assetWithURL:url];
            [asset loadValuesAsynchronouslyForKeys:@[@"duration"] completionHandler:^{
                NSError *error = nil;
                AVKeyValueStatus status = [asset statusOfValueForKey:@"duration" error:&error];
                if (status == AVKeyValueStatusLoaded) {
                    @synchronized (durations) {
                        durations[url] = [NSValue valueWithCMTime:asset.duration];
                    }
                }
                dispatch_semaphore_signal(semaphore);
                dispatch_group_leave(group);
            }];
        });
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        self.videoDurations = [durations copy];
        if (completion) {
            completion();
        }
    });
}


#pragma mark - Configuration Sheet
- (BOOL)hasConfigureSheet {
    return YES;
}

- (NSWindow*)configureSheet {
    // ⚠️ CRITICAL: DO NOT MODIFY THIS PATTERN UNLESS ABSOLUTELY NECESSARY ⚠️
    // This method MUST create a fresh window every time to avoid intermittent modal sheet failures.
    if (self.configSheet) {
        [self.configSheet orderOut:nil];
        self.configSheet = nil;
    }

    // ALWAYS reload from UserDefaults to ensure we have the latest data
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    NSArray *savedBookmarks = [defaults objectForKey:kVideoFoldersBookmarksKey];
    self.folderBookmarks = savedBookmarks ? [savedBookmarks mutableCopy] : [NSMutableArray array];

    // Create window (480x580)
    NSRect frame = NSMakeRect(0, 0, 480, 580);
    self.configSheet = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    self.configSheet.title = @"Video Screen Saver Settings";
    NSView *contentView = self.configSheet.contentView;

    // Setup all UI elements in a single pane
    [self setupSinglePaneUI:contentView];

    // OK button
    NSButton *okButton = [[NSButton alloc] initWithFrame:NSMakeRect(frame.size.width - 90, 20, 80, 32)];
    okButton.title = @"OK";
    okButton.bezelStyle = NSBezelStyleRounded;
    okButton.keyEquivalent = @"\r";
    okButton.target = self;
    okButton.action = @selector(closeConfigSheet:);
    [contentView addSubview:okButton];

    // Update UI with current values
    [self refreshUIFromDefaults];

    return self.configSheet;
}

#pragma mark - UI Setup

- (void)setupSinglePaneUI:(NSView *)contentView {
    CGFloat currentY = contentView.frame.size.height - 20;
    CGFloat contentWidth = contentView.frame.size.width - 40;

    // --- Source Folders Group ---
    NSBox *foldersBox = [[NSBox alloc] initWithFrame:NSMakeRect(20, currentY - 220, contentWidth, 220)];
    foldersBox.title = @"Source Folders";
    foldersBox.boxType = NSBoxPrimary;
    [contentView addSubview:foldersBox];
    NSView *foldersContentView = foldersBox.contentView;

    // Folders table view (Height for ~5 rows: 5 * 22 = 110)
    CGFloat tableHeight = 115;
    NSScrollView *foldersScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 50, foldersContentView.frame.size.width - 20, tableHeight)];
    foldersScrollView.hasVerticalScroller = YES;
    foldersScrollView.borderType = NSBezelBorder;

    self.foldersTableView = [[NSTableView alloc] initWithFrame:foldersScrollView.bounds];
    NSTableColumn *folderColumn = [[NSTableColumn alloc] initWithIdentifier:@"folder"];
    folderColumn.width = foldersScrollView.frame.size.width - 4; // Account for scroller
    [self.foldersTableView addTableColumn:folderColumn];
    self.foldersTableView.headerView = nil;
    self.foldersTableView.delegate = self;
    self.foldersTableView.dataSource = self;
    foldersScrollView.documentView = self.foldersTableView;
    [foldersContentView addSubview:foldersScrollView];

    // Empty state label
    self.emptyStateLabel = [[NSTextField alloc] initWithFrame:foldersScrollView.frame];
    self.emptyStateLabel.stringValue = @"No video folders configured.\nClick + to add one.";
    self.emptyStateLabel.alignment = NSTextAlignmentCenter;
    self.emptyStateLabel.textColor = [NSColor secondaryLabelColor];
    self.emptyStateLabel.editable = NO;
    self.emptyStateLabel.bordered = NO;
    self.emptyStateLabel.backgroundColor = [NSColor clearColor];
    [foldersContentView addSubview:self.emptyStateLabel];

    // Add/Remove buttons
    NSButton *addButton = [[NSButton alloc] initWithFrame:NSMakeRect(10, 10, 32, 32)];
    [addButton setTitle:@"+"];
    [addButton setBezelStyle:NSBezelStyleRounded];
    [addButton setTarget:self action:@selector(addFolderClicked:)];
    [foldersContentView addSubview:addButton];

    NSButton *removeButton = [[NSButton alloc] initWithFrame:NSMakeRect(50, 10, 32, 32)];
    [removeButton setTitle:@"-"];
    [removeButton setBezelStyle:NSBezelStyleRounded];
    [removeButton setTarget:self action:@selector(removeFolderClicked:)];
    [foldersContentView addSubview:removeButton];

    // Recursive scan checkbox
    self.recursiveScanCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(foldersContentView.frame.size.width - 180, 15, 170, 24)];
    [self.recursiveScanCheckbox setButtonType:NSButtonTypeSwitch];
    self.recursiveScanCheckbox.title = @"Search Subfolders";
    self.recursiveScanCheckbox.target = self;
    self.recursiveScanCheckbox.action = @selector(recursiveScanCheckboxClicked:);
    [foldersContentView addSubview:self.recursiveScanCheckbox];

    currentY -= foldersBox.frame.size.height + 20;

    // --- Playback Group ---
    NSBox *playbackBox = [[NSBox alloc] initWithFrame:NSMakeRect(20, currentY - 120, contentWidth, 120)];
    playbackBox.title = @"Playback";
    playbackBox.boxType = NSBoxPrimary;
    [contentView addSubview:playbackBox];
    NSView *playbackContentView = playbackBox.contentView;

    self.enableAudioCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(10, 70, 200, 24)];
    [self.enableAudioCheckbox setButtonType:NSButtonTypeSwitch];
    self.enableAudioCheckbox.title = @"Enable Audio";
    self.enableAudioCheckbox.target = self;
    self.enableAudioCheckbox.action = @selector(settingCheckboxClicked:);
    [playbackContentView addSubview:self.enableAudioCheckbox];

    self.shuffleCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(10, 40, 200, 24)];
    [self.shuffleCheckbox setButtonType:NSButtonTypeSwitch];
    self.shuffleCheckbox.title = @"Shuffle Videos";
    self.shuffleCheckbox.target = self;
    self.shuffleCheckbox.action = @selector(settingCheckboxClicked:);
    [playbackContentView addSubview:self.shuffleCheckbox];

    self.loopCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(10, 10, 200, 24)];
    [self.loopCheckbox setButtonType:NSButtonTypeSwitch];
    self.loopCheckbox.title = @"Loop Playlist";
    self.loopCheckbox.target = self;
    self.loopCheckbox.action = @selector(settingCheckboxClicked:);
    [playbackContentView addSubview:self.loopCheckbox];

    currentY -= playbackBox.frame.size.height + 20;

    // --- Display Group ---
    NSBox *displayBox = [[NSBox alloc] initWithFrame:NSMakeRect(20, currentY - 120, contentWidth, 120)];
    displayBox.title = @"Display";
    displayBox.boxType = NSBoxPrimary;
    [contentView addSubview:displayBox];
    NSView *displayContentView = displayBox.contentView;

    NSTextField *scalingLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 70, 100, 24)];
    scalingLabel.stringValue = @"Video Scaling:";
    scalingLabel.editable = NO; scalingLabel.bezeled = NO; scalingLabel.drawsBackground = NO;
    [displayContentView addSubview:scalingLabel];

    self.scalingPopUpButton = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(110, 70, 200, 24)];
    [self.scalingPopUpButton addItemsWithTitles:@[@"Fill Screen", @"Fit to Screen", @"Stretch"]];
    self.scalingPopUpButton.target = self;
    self.scalingPopUpButton.action = @selector(scalingChanged:);
    [displayContentView addSubview:self.scalingPopUpButton];

    NSTextField *transitionLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 40, 100, 24)];
    transitionLabel.stringValue = @"Transition:";
    transitionLabel.editable = NO; transitionLabel.bezeled = NO; transitionLabel.drawsBackground = NO;
    [displayContentView addSubview:transitionLabel];

    self.transitionPopUpButton = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(110, 40, 200, 24)];
    [self.transitionPopUpButton addItemsWithTitles:@[@"None", @"Fade", @"Cross Dissolve"]];
    self.transitionPopUpButton.target = self;
    self.transitionPopUpButton.action = @selector(transitionChanged:);
    [displayContentView addSubview:self.transitionPopUpButton];

    NSTextField *durationTitleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 10, 100, 24)];
    durationTitleLabel.stringValue = @"Duration:";
    durationTitleLabel.editable = NO; durationTitleLabel.bezeled = NO; durationTitleLabel.drawsBackground = NO;
    [displayContentView addSubview:durationTitleLabel];

    self.durationSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(110, 10, 200, 24)];
    self.durationSlider.minValue = 0.5; self.durationSlider.maxValue = 5.0;
    self.durationSlider.target = self; self.durationSlider.action = @selector(sliderValueChanged:);
    [displayContentView addSubview:self.durationSlider];

    self.durationLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(320, 10, 100, 24)];
    self.durationLabel.editable = NO; self.durationLabel.bezeled = NO; self.durationLabel.drawsBackground = NO;
    [displayContentView addSubview:self.durationLabel];
}

- (void)refreshUIFromDefaults {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];

    // Update checkboxes if they exist
    if (self.enableAudioCheckbox) {
        self.enableAudioCheckbox.state = [defaults boolForKey:kEnableAudioKey] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (self.shuffleCheckbox) {
        self.shuffleCheckbox.state = [defaults boolForKey:kShuffleKey] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (self.loopCheckbox) {
        self.loopCheckbox.state = [defaults boolForKey:kLoopKey] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (self.recursiveScanCheckbox) {
        self.recursiveScanCheckbox.state = [defaults boolForKey:kRecursiveScanKey] ? NSControlStateValueOn : NSControlStateValueOff;
    }

    // Update scaling popup if it exists
    if (self.scalingPopUpButton) {
        [self.scalingPopUpButton selectItemAtIndex:[defaults integerForKey:kVideoScalingKey]];
    }

    // Update transition controls if they exist
    if (self.transitionPopUpButton) {
        [self.transitionPopUpButton selectItemAtIndex:[defaults integerForKey:kTransitionTypeKey]];
        [self transitionChanged:self.transitionPopUpButton];
    }
    if (self.durationSlider) {
        self.durationSlider.doubleValue = [defaults doubleForKey:kTransitionDurationKey];
        [self updateDurationLabel];
    }

    // Reload folder table
    if (self.foldersTableView) {
        [self.foldersTableView reloadData];
        self.emptyStateLabel.hidden = (self.folderBookmarks.count > 0);
    }
}

#pragma mark - Action Handlers

- (IBAction)addFolderClicked:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"Add";
    panel.directoryURL = [NSURL fileURLWithPath:NSHomeDirectory()];

    [panel beginSheetModalForWindow:self.configSheet completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            NSURL *url = panel.URL;
            if (url) {
                NSError *error = nil;
                NSData *bookmarkData = [url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                                         includingResourceValuesForKeys:nil
                                                          relativeToURL:nil
                                                                  error:&error];
                if (!error && bookmarkData) {
                    // Check for duplicates
                    BOOL isDuplicate = NO;
                    for (NSData *existingBookmark in self.folderBookmarks) {
                        NSURL *existingURL = [NSURL URLByResolvingBookmarkData:existingBookmark
                                                                       options:0
                                                                 relativeToURL:nil
                                                           bookmarkDataIsStale:NULL
                                                                         error:NULL];
                        if ([existingURL.path isEqualToString:url.path]) {
                            isDuplicate = YES;
                            break;
                        }
                    }

                    if (!isDuplicate) {
                        [self.folderBookmarks addObject:bookmarkData];
                        [self saveFolderBookmarks];
                        [self.foldersTableView reloadData];
                        self.emptyStateLabel.hidden = YES;

                        // Reload videos if in preview
                        if (self.isPreview) {
                            [self stopAnimation];
                            [self startAnimation];
                        }
                    }
                }
            }
        }
    }];
}

- (IBAction)removeFolderClicked:(id)sender {
    NSInteger selectedRow = self.foldersTableView.selectedRow;
    if (selectedRow < 0 || selectedRow >= self.folderBookmarks.count) return;

    NSData *bookmarkData = self.folderBookmarks[selectedRow];
    NSURL *folderURL = [NSURL URLByResolvingBookmarkData:bookmarkData
                                                 options:0
                                           relativeToURL:nil
                                     bookmarkDataIsStale:NULL
                                                   error:NULL];
    NSString *folderName = folderURL.lastPathComponent ?: @"this folder";

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Remove Folder";
    alert.informativeText = [NSString stringWithFormat:@"Remove '%@' from source folders?", folderName];
    [alert addButtonWithTitle:@"Remove"];
    [alert addButtonWithTitle:@"Cancel"];

    [alert beginSheetModalForWindow:self.configSheet completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSAlertFirstButtonReturn) {
            [self.folderBookmarks removeObjectAtIndex:selectedRow];
            [self saveFolderBookmarks];
            [self.foldersTableView reloadData];
            self.emptyStateLabel.hidden = (self.folderBookmarks.count > 0);

            // If screensaver is currently running, reload the playlist immediately
            // Otherwise, it will pick up the new folder list on next start
            if (self.videoURLs && self.videoURLs.count > 0) {
                [self stopAnimation];
                [self startAnimation];
            }
        }
    }];
}

- (void)saveFolderBookmarks {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    [defaults setObject:self.folderBookmarks forKey:kVideoFoldersBookmarksKey];
    [defaults synchronize];
}


- (IBAction)settingCheckboxClicked:(NSButton *)sender {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    NSString *key = nil;
    if (sender == self.enableAudioCheckbox) key = kEnableAudioKey;
    else if (sender == self.shuffleCheckbox) key = kShuffleKey;
    else if (sender == self.loopCheckbox) key = kLoopKey;
    
    if (key) {
        [defaults setBool:(sender.state == NSControlStateValueOn) forKey:key];
        [defaults synchronize];
        if (self.isPreview && [key isEqualToString:kShuffleKey]) {
            [self stopAnimation];
            [self startAnimation];
        }
    }
}

- (IBAction)recursiveScanCheckboxClicked:(NSButton *)sender {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    BOOL isEnabled = (sender.state == NSControlStateValueOn);
    [defaults setBool:isEnabled forKey:kRecursiveScanKey];
    [defaults synchronize];

    // Reload playlist if screensaver is running to apply the change immediately
    if (self.videoURLs && self.videoURLs.count > 0) {
        [self stopAnimation];
        [self startAnimation];
    }
}

- (IBAction)transitionChanged:(NSPopUpButton *)sender {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    NSInteger selectedTransition = sender.indexOfSelectedItem;
    [defaults setInteger:selectedTransition forKey:kTransitionTypeKey];
    [defaults synchronize];

    self.durationSlider.enabled = (selectedTransition != TransitionTypeNone);
    self.durationLabel.textColor = (selectedTransition != TransitionTypeNone) ? [NSColor labelColor] : [NSColor disabledControlTextColor];
}

- (IBAction)sliderValueChanged:(NSSlider *)sender {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    [defaults setDouble:sender.doubleValue forKey:kTransitionDurationKey];
    [defaults synchronize];
    [self updateDurationLabel];
}

- (void)updateDurationLabel {
    self.durationLabel.stringValue = [NSString stringWithFormat:@"%.1f s", self.durationSlider.doubleValue];
}

- (IBAction)closeConfigSheet:(id)sender {
    NSWindow *sheet = self.configSheet;

    // macOS 26 (Sequoia) compatibility: properly dismiss the sheet
    if (sheet.sheetParent) {
        // If presented as a sheet, end it properly
        [sheet.sheetParent endSheet:sheet];
    } else {
        // Fallback for older macOS versions or if not presented as sheet
        [NSApp endSheet:sheet];
    }

    [sheet orderOut:self];  // Explicitly order out the window

    // Clear references AFTER dismissing
    self.configSheet = nil;
    self.folderBookmarks = nil;  // Reset so it reloads from UserDefaults next time
}

#pragma mark - Helper Methods

- (NSString *)videoGravityFromScaling:(VideoScaling)scaling {
    switch (scaling) {
        case VideoScalingFit:
            return AVLayerVideoGravityResizeAspect;  // Fit entire video, letterbox if needed
        case VideoScalingStretch:
            return AVLayerVideoGravityResize;  // Stretch to fill, distorts aspect ratio
        case VideoScalingFill:
        default:
            return AVLayerVideoGravityResizeAspectFill;  // Fill screen, crop if needed
    }
}

- (IBAction)scalingChanged:(NSPopUpButton *)sender {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    NSInteger selectedScaling = sender.indexOfSelectedItem;
    [defaults setInteger:selectedScaling forKey:kVideoScalingKey];
    [defaults synchronize];

    // Apply to player layers immediately
    NSString *videoGravity = [self videoGravityFromScaling:(VideoScaling)selectedScaling];
    self.playerLayerA.videoGravity = videoGravity;
    self.playerLayerB.videoGravity = videoGravity;

    // Reload videos if in preview to see the change
    if (self.isPreview) {
        [self stopAnimation];
        [self startAnimation];
    }
}

#pragma mark - NSTableView DataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.folderBookmarks.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSData *bookmarkData = self.folderBookmarks[row];
    NSURL *folderURL = [NSURL URLByResolvingBookmarkData:bookmarkData
                                                 options:0
                                           relativeToURL:nil
                                     bookmarkDataIsStale:NULL
                                                   error:NULL];
    return folderURL.lastPathComponent ?: @"Unknown Folder";
}

#pragma mark - NSTableView Delegate

- (NSString *)tableView:(NSTableView *)tableView toolTipForCell:(NSCell *)cell rect:(NSRectPointer)rect tableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row mouseLocation:(NSPoint)mouseLocation {
    if (row < self.folderBookmarks.count) {
        NSData *bookmarkData = self.folderBookmarks[row];
        NSURL *folderURL = [NSURL URLByResolvingBookmarkData:bookmarkData
                                                     options:0
                                               relativeToURL:nil
                                         bookmarkDataIsStale:NULL
                                                       error:NULL];
        return [folderURL.path stringByAbbreviatingWithTildeInPath];
    }
    return nil;
}

@end

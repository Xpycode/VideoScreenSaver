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
static NSString * const kShowFilenameKey = @"showFilename";
static NSString * const kFilenamePositionKey = @"filenamePosition";
static NSString * const kFilenameFontSizeKey = @"filenameFontSize";

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

typedef NS_ENUM(NSInteger, FilenamePosition) {
    FilenamePositionBottomLeft,
    FilenamePositionBottomRight,
    FilenamePositionTopLeft,
    FilenamePositionTopRight
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
@property (strong) NSButton *showFilenameCheckbox;
@property (strong) NSPopUpButton *filenamePositionPopUpButton;
@property (strong) NSSlider *filenameFontSizeSlider;
@property (strong) NSTextField *filenameFontSizeLabel;

// Two-pane UI Properties
@property (strong) NSTableView *categoryTableView;
@property (strong) NSTableView *foldersTableView;
@property (strong) NSMutableArray<NSData *> *folderBookmarks;
@property (strong) NSTextField *emptyStateLabel;
@property (strong) NSView *rightPaneView;

// Video playback properties
@property (strong) NSArray<NSURL *> *videoURLs;
@property (strong) NSDictionary<NSURL *, NSValue *> *videoDurations;
@property (assign) NSInteger currentVideoIndex;
@property (assign) BOOL isPreparingNextVideo; // Race condition guard

// Dual Player System for seamless transitions
@property (strong) AVPlayer *playerA;
@property (strong) AVPlayerLayer *playerLayerA;
@property (strong) AVPlayerItem *playerItemA;
@property (strong) AVPlayer *playerB;
@property (strong) AVPlayerLayer *playerLayerB;
@property (strong) AVPlayerItem *playerItemB;
@property (weak) AVPlayer *activePlayer;
@property (weak) AVPlayerLayer *activePlayerLayer;

// Timeline Observer
@property (strong) id timeObserverToken;

// KVO tracking - use a set to track all observed items
@property (strong) NSMutableSet<AVPlayerItem *> *observedItems;

// Filename overlay
@property (strong) CATextLayer *filenameOverlayLayer;

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
            kRecursiveScanKey: @NO,
            kShowFilenameKey: @NO,
            kFilenamePositionKey: @(FilenamePositionBottomLeft),
            kFilenameFontSizeKey: @18.0
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

        // Apply saved video scaling preference
        NSString *videoGravity = [self videoGravityFromScaling:(VideoScaling)[defaults integerForKey:kVideoScalingKey]];
        self.playerLayerA.videoGravity = videoGravity;
        self.playerLayerB.videoGravity = videoGravity;

        self.playerLayerA.frame = self.bounds;
        self.playerLayerB.frame = self.bounds;

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

    // Ensure at least one player layer is visible from the start
    if (!self.playerLayerA.superlayer && !self.playerLayerB.superlayer) {
        [self.layer addSublayer:self.playerLayerA];
        self.activePlayerLayer = self.playerLayerA;
        self.activePlayer = self.playerA;
    }

    // Disable implicit animations to reduce CPU usage
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.playerLayerA.frame = self.bounds;
    self.playerLayerB.frame = self.bounds;
    [CATransaction commit];

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

    // Remove layers from hierarchy
    [self.playerLayerA removeFromSuperlayer];
    [self.playerLayerB removeFromSuperlayer];

    // Clear references
    self.activePlayerLayer = nil;
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
            AVPlayerLayer *newLayer = isPlayerA ? self.playerLayerA : self.playerLayerB;
            
            // Perform the transition, now guaranteed to have a frame to show.
            [self performTransitionFrom:self.activePlayerLayer to:newLayer];
            
            // Update the active player references.
            AVPlayer *oldPlayer = self.activePlayer;
            self.activePlayer = newPlayer;
            self.activePlayerLayer = newLayer;

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

            // Update filename overlay for the new video
            NSURL *videoURL = ((AVURLAsset *)playerItem.asset).URL;
            [self updateFilenameOverlayForVideo:videoURL];

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

- (void)performTransitionFrom:(AVPlayerLayer *)oldLayer to:(AVPlayerLayer *)newLayer {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    TransitionType transition = (TransitionType)[defaults integerForKey:kTransitionTypeKey];
    double duration = [defaults doubleForKey:kTransitionDurationKey];
    
    if (transition == TransitionTypeNone || oldLayer == nil) {
        if (oldLayer) [oldLayer removeFromSuperlayer];
        [self.layer addSublayer:newLayer];
        return;
    }

    if (transition == TransitionTypeCrossDissolve) {
        newLayer.opacity = 0.0;
        [self.layer addSublayer:newLayer];
        [CATransaction begin];
        [CATransaction setAnimationDuration:duration];
        [CATransaction setCompletionBlock:^{ [oldLayer removeFromSuperlayer]; oldLayer.opacity = 1.0; }];
        newLayer.opacity = 1.0;
        oldLayer.opacity = 0.0;
        [CATransaction commit];
    } else if (transition == TransitionTypeFade) {
        [self.layer insertSublayer:newLayer below:oldLayer];
        [CATransaction begin];
        [CATransaction setAnimationDuration:duration];
        [CATransaction setCompletionBlock:^{ [oldLayer removeFromSuperlayer]; oldLayer.opacity = 1.0; }];
        oldLayer.opacity = 0.0;
        [CATransaction commit];
    }
}

- (void)layout {
    [super layout];
    self.playerLayerA.frame = self.bounds;
    self.playerLayerB.frame = self.bounds;
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
    // Reusing the window causes the sheet to stop appearing after working for a while.
    // The pattern of checking for existing window, ordering it out, and nilifying is intentional.

    // Always create fresh - don't reuse old window
    if (self.configSheet) {
        [self.configSheet orderOut:nil];
        self.configSheet = nil;
    }

    // ALWAYS reload from UserDefaults to ensure we have the latest data
    // System Settings creates multiple instances of ScreenSaverView, so we can't rely on cached data
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    NSArray *savedBookmarks = [defaults objectForKey:kVideoFoldersBookmarksKey];
    self.folderBookmarks = savedBookmarks ? [savedBookmarks mutableCopy] : [NSMutableArray array];

    // Create window (600x350)
    NSRect frame = NSMakeRect(0, 0, 600, 350);
    self.configSheet = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    self.configSheet.title = @"Video Screen Saver Settings";
    NSView *contentView = self.configSheet.contentView;

    // Left pane - Category list (150x260, 20px margins)
    NSScrollView *categoryScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 70, 150, 260)];
    categoryScrollView.hasVerticalScroller = YES;
    categoryScrollView.borderType = NSBezelBorder;

    self.categoryTableView = [[NSTableView alloc] initWithFrame:categoryScrollView.bounds];
    NSTableColumn *categoryColumn = [[NSTableColumn alloc] initWithIdentifier:@"category"];
    categoryColumn.width = 148;
    [self.categoryTableView addTableColumn:categoryColumn];
    self.categoryTableView.headerView = nil;
    self.categoryTableView.delegate = self;
    self.categoryTableView.dataSource = self;
    categoryScrollView.documentView = self.categoryTableView;
    [contentView addSubview:categoryScrollView];

    // Right pane container (390x260)
    self.rightPaneView = [[NSView alloc] initWithFrame:NSMakeRect(190, 70, 390, 260)];
    [contentView addSubview:self.rightPaneView];

    // OK button
    NSButton *okButton = [[NSButton alloc] initWithFrame:NSMakeRect(500, 20, 80, 32)];
    okButton.title = @"OK";
    okButton.bezelStyle = NSBezelStyleRounded;
    okButton.keyEquivalent = @"\r";
    okButton.target = self;
    okButton.action = @selector(closeConfigSheet:);
    [contentView addSubview:okButton];

    // Select Source Folders by default
    [self.categoryTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    [self setupSourceFoldersPane];

    // Update UI with current values
    [self refreshUIFromDefaults];

    return self.configSheet;
}

#pragma mark - Pane Setup Methods

- (void)setupSourceFoldersPane {
    // Clear right pane
    for (NSView *subview in self.rightPaneView.subviews) {
        [subview removeFromSuperview];
    }

    // Folders table view (full width, leave 50px at bottom for buttons)
    NSScrollView *foldersScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 50, 390, 210)];
    foldersScrollView.hasVerticalScroller = YES;
    foldersScrollView.borderType = NSBezelBorder;

    self.foldersTableView = [[NSTableView alloc] initWithFrame:foldersScrollView.bounds];
    NSTableColumn *folderColumn = [[NSTableColumn alloc] initWithIdentifier:@"folder"];
    folderColumn.title = @"Video Folders";
    folderColumn.width = 370;
    [self.foldersTableView addTableColumn:folderColumn];
    self.foldersTableView.delegate = self;
    self.foldersTableView.dataSource = self;
    foldersScrollView.documentView = self.foldersTableView;
    [self.rightPaneView addSubview:foldersScrollView];

    // Empty state label (hidden when folders exist)
    self.emptyStateLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 100, 390, 60)];
    self.emptyStateLabel.stringValue = @"No video folders configured.\n\nClick + to add a video folder";
    self.emptyStateLabel.alignment = NSTextAlignmentCenter;
    self.emptyStateLabel.textColor = [NSColor secondaryLabelColor];
    self.emptyStateLabel.editable = NO;
    self.emptyStateLabel.bordered = NO;
    self.emptyStateLabel.backgroundColor = [NSColor clearColor];
    self.emptyStateLabel.font = [NSFont systemFontOfSize:13];
    self.emptyStateLabel.hidden = (self.folderBookmarks.count > 0);
    [self.rightPaneView addSubview:self.emptyStateLabel];

    // Add folder button (+)
    NSButton *addButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 10, 32, 32)];
    [addButton setTitle:@"+"];
    [addButton setButtonType:NSButtonTypeMomentaryPushIn];
    [addButton setBezelStyle:NSBezelStyleRounded];
    [addButton setTarget:self];
    [addButton setAction:@selector(addFolderClicked:)];
    [addButton setFont:[NSFont systemFontOfSize:18]];
    [self.rightPaneView addSubview:addButton];

    // Remove folder button (-)
    NSButton *removeButton = [[NSButton alloc] initWithFrame:NSMakeRect(40, 10, 32, 32)];
    [removeButton setTitle:@"-"];
    [removeButton setButtonType:NSButtonTypeMomentaryPushIn];
    [removeButton setBezelStyle:NSBezelStyleRounded];
    [removeButton setTarget:self];
    [removeButton setAction:@selector(removeFolderClicked:)];
    [removeButton setFont:[NSFont systemFontOfSize:18]];
    [self.rightPaneView addSubview:removeButton];

    // Search Subfolders checkbox (positioned on the right side)
    self.recursiveScanCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(200, 10, 190, 24)];
    [self.recursiveScanCheckbox setButtonType:NSButtonTypeSwitch];
    self.recursiveScanCheckbox.title = @"Search Subfolders";
    self.recursiveScanCheckbox.target = self;
    self.recursiveScanCheckbox.action = @selector(recursiveScanCheckboxClicked:);
    [self.rightPaneView addSubview:self.recursiveScanCheckbox];
}

- (void)setupPlaybackPane {
    // Clear right pane
    for (NSView *subview in self.rightPaneView.subviews) {
        [subview removeFromSuperview];
    }

    int yPos = 200;

    // Enable Audio checkbox
    self.enableAudioCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, yPos, 200, 24)];
    [self.enableAudioCheckbox setButtonType:NSButtonTypeSwitch];
    self.enableAudioCheckbox.title = @"Enable Audio";
    self.enableAudioCheckbox.target = self;
    self.enableAudioCheckbox.action = @selector(settingCheckboxClicked:);
    [self.rightPaneView addSubview:self.enableAudioCheckbox];

    yPos -= 40;

    // Shuffle Videos checkbox
    self.shuffleCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, yPos, 200, 24)];
    [self.shuffleCheckbox setButtonType:NSButtonTypeSwitch];
    self.shuffleCheckbox.title = @"Shuffle Videos";
    self.shuffleCheckbox.target = self;
    self.shuffleCheckbox.action = @selector(settingCheckboxClicked:);
    [self.rightPaneView addSubview:self.shuffleCheckbox];

    yPos -= 40;

    // Loop Playlist checkbox
    self.loopCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, yPos, 200, 24)];
    [self.loopCheckbox setButtonType:NSButtonTypeSwitch];
    self.loopCheckbox.title = @"Loop Playlist";
    self.loopCheckbox.target = self;
    self.loopCheckbox.action = @selector(settingCheckboxClicked:);
    [self.rightPaneView addSubview:self.loopCheckbox];
}

- (void)setupDisplayPane {
    // Clear right pane
    for (NSView *subview in self.rightPaneView.subviews) {
        [subview removeFromSuperview];
    }

    int yPos = 200;

    // Video Scaling label and popup
    NSTextField *scalingLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, yPos, 100, 24)];
    scalingLabel.stringValue = @"Video Scaling:";
    scalingLabel.editable = NO;
    scalingLabel.bezeled = NO;
    scalingLabel.drawsBackground = NO;
    [self.rightPaneView addSubview:scalingLabel];

    self.scalingPopUpButton = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(120, yPos, 200, 24)];
    [self.scalingPopUpButton addItemsWithTitles:@[@"Fill Screen", @"Fit to Screen", @"Stretch"]];
    self.scalingPopUpButton.target = self;
    self.scalingPopUpButton.action = @selector(scalingChanged:);
    [self.rightPaneView addSubview:self.scalingPopUpButton];

    yPos -= 40;

    // Transition label and popup
    NSTextField *transitionLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, yPos, 100, 24)];
    transitionLabel.stringValue = @"Transition:";
    transitionLabel.editable = NO;
    transitionLabel.bezeled = NO;
    transitionLabel.drawsBackground = NO;
    [self.rightPaneView addSubview:transitionLabel];

    self.transitionPopUpButton = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(120, yPos, 200, 24)];
    [self.transitionPopUpButton addItemsWithTitles:@[@"None", @"Fade", @"Cross Dissolve"]];
    self.transitionPopUpButton.target = self;
    self.transitionPopUpButton.action = @selector(transitionChanged:);
    [self.rightPaneView addSubview:self.transitionPopUpButton];

    yPos -= 40;

    // Duration label and slider
    NSTextField *durationTitleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, yPos + 10, 100, 24)];
    durationTitleLabel.stringValue = @"Duration:";
    durationTitleLabel.editable = NO;
    durationTitleLabel.bezeled = NO;
    durationTitleLabel.drawsBackground = NO;
    [self.rightPaneView addSubview:durationTitleLabel];

    self.durationLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(120, yPos + 10, 100, 24)];
    self.durationLabel.editable = NO;
    self.durationLabel.bezeled = NO;
    self.durationLabel.drawsBackground = NO;
    [self.rightPaneView addSubview:self.durationLabel];

    self.durationSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(20, yPos - 15, 300, 24)];
    self.durationSlider.minValue = 0.5;
    self.durationSlider.maxValue = 5.0;
    self.durationSlider.target = self;
    self.durationSlider.action = @selector(sliderValueChanged:);
    [self.rightPaneView addSubview:self.durationSlider];

    yPos -= 70;

    // Show Filename checkbox
    self.showFilenameCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, yPos, 200, 24)];
    [self.showFilenameCheckbox setButtonType:NSButtonTypeSwitch];
    self.showFilenameCheckbox.title = @"Show Filename";
    self.showFilenameCheckbox.target = self;
    self.showFilenameCheckbox.action = @selector(showFilenameCheckboxClicked:);
    [self.rightPaneView addSubview:self.showFilenameCheckbox];

    yPos -= 30;

    // Filename Position label and popup
    NSTextField *positionLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(40, yPos, 80, 24)];
    positionLabel.stringValue = @"Position:";
    positionLabel.editable = NO;
    positionLabel.bezeled = NO;
    positionLabel.drawsBackground = NO;
    [self.rightPaneView addSubview:positionLabel];

    self.filenamePositionPopUpButton = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(120, yPos, 200, 24)];
    [self.filenamePositionPopUpButton addItemsWithTitles:@[@"Bottom Left", @"Bottom Right", @"Top Left", @"Top Right"]];
    self.filenamePositionPopUpButton.target = self;
    self.filenamePositionPopUpButton.action = @selector(filenamePositionChanged:);
    [self.rightPaneView addSubview:self.filenamePositionPopUpButton];

    yPos -= 30;

    // Font Size label and slider
    NSTextField *fontSizeTitleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(40, yPos + 10, 80, 24)];
    fontSizeTitleLabel.stringValue = @"Font Size:";
    fontSizeTitleLabel.editable = NO;
    fontSizeTitleLabel.bezeled = NO;
    fontSizeTitleLabel.drawsBackground = NO;
    [self.rightPaneView addSubview:fontSizeTitleLabel];

    self.filenameFontSizeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(120, yPos + 10, 50, 24)];
    self.filenameFontSizeLabel.editable = NO;
    self.filenameFontSizeLabel.bezeled = NO;
    self.filenameFontSizeLabel.drawsBackground = NO;
    [self.rightPaneView addSubview:self.filenameFontSizeLabel];

    self.filenameFontSizeSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(40, yPos - 15, 280, 24)];
    self.filenameFontSizeSlider.minValue = 12.0;
    self.filenameFontSizeSlider.maxValue = 48.0;
    self.filenameFontSizeSlider.target = self;
    self.filenameFontSizeSlider.action = @selector(filenameFontSizeChanged:);
    [self.rightPaneView addSubview:self.filenameFontSizeSlider];
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
    if (self.showFilenameCheckbox) {
        self.showFilenameCheckbox.state = [defaults boolForKey:kShowFilenameKey] ? NSControlStateValueOn : NSControlStateValueOff;
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

    // Update filename overlay controls if they exist
    if (self.filenamePositionPopUpButton) {
        [self.filenamePositionPopUpButton selectItemAtIndex:[defaults integerForKey:kFilenamePositionKey]];
    }
    if (self.filenameFontSizeSlider) {
        self.filenameFontSizeSlider.doubleValue = [defaults doubleForKey:kFilenameFontSizeKey];
        [self updateFilenameFontSizeLabel];
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

- (void)updateFilenameFontSizeLabel {
    self.filenameFontSizeLabel.stringValue = [NSString stringWithFormat:@"%.0f pt", self.filenameFontSizeSlider.doubleValue];
}

- (IBAction)showFilenameCheckboxClicked:(NSButton *)sender {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    BOOL isEnabled = (sender.state == NSControlStateValueOn);
    [defaults setBool:isEnabled forKey:kShowFilenameKey];
    [defaults synchronize];

    // Update the overlay immediately
    [self updateFilenameOverlay];
}

- (IBAction)filenamePositionChanged:(NSPopUpButton *)sender {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    [defaults setInteger:sender.indexOfSelectedItem forKey:kFilenamePositionKey];
    [defaults synchronize];

    // Update the overlay immediately
    [self updateFilenameOverlay];
}

- (IBAction)filenameFontSizeChanged:(NSSlider *)sender {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    [defaults setDouble:sender.doubleValue forKey:kFilenameFontSizeKey];
    [defaults synchronize];
    [self updateFilenameFontSizeLabel];

    // Update the overlay immediately
    [self updateFilenameOverlay];
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

#pragma mark - Filename Overlay Methods

- (void)updateFilenameOverlay {
    // Called when settings change (without video URL)
    if (self.currentVideoIndex >= 0 && self.currentVideoIndex < self.videoURLs.count) {
        NSURL *currentURL = self.videoURLs[self.currentVideoIndex];
        [self updateFilenameOverlayForVideo:currentURL];
    }
}

- (void)updateFilenameOverlayForVideo:(NSURL *)videoURL {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    BOOL showFilename = [defaults boolForKey:kShowFilenameKey];

    // Remove existing overlay if present
    if (self.filenameOverlayLayer) {
        [self.filenameOverlayLayer removeFromSuperlayer];
        self.filenameOverlayLayer = nil;
    }

    // Don't create overlay if disabled
    if (!showFilename || !videoURL) {
        return;
    }

    // Create text layer for filename
    self.filenameOverlayLayer = [CATextLayer layer];
    self.filenameOverlayLayer.string = videoURL.lastPathComponent.stringByDeletingPathExtension;

    // Configure appearance
    CGFloat fontSize = [defaults doubleForKey:kFilenameFontSizeKey];
    self.filenameOverlayLayer.fontSize = fontSize;
    self.filenameOverlayLayer.font = (__bridge CFTypeRef)[NSFont systemFontOfSize:fontSize];
    self.filenameOverlayLayer.foregroundColor = [[NSColor whiteColor] CGColor];

    // Add shadow for better visibility
    self.filenameOverlayLayer.shadowColor = [[NSColor blackColor] CGColor];
    self.filenameOverlayLayer.shadowOpacity = 0.8;
    self.filenameOverlayLayer.shadowOffset = CGSizeMake(2, -2);
    self.filenameOverlayLayer.shadowRadius = 4.0;

    // Calculate size
    NSString *filename = videoURL.lastPathComponent.stringByDeletingPathExtension;
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:fontSize]};
    CGSize textSize = [filename sizeWithAttributes:attributes];
    CGFloat padding = 20.0;
    CGFloat width = textSize.width + (padding * 2);
    CGFloat height = textSize.height + (padding * 2);

    // Position based on user preference
    FilenamePosition position = (FilenamePosition)[defaults integerForKey:kFilenamePositionKey];
    CGRect bounds = self.bounds;
    CGFloat xPos, yPos;

    switch (position) {
        case FilenamePositionBottomLeft:
            xPos = padding;
            yPos = padding;
            break;
        case FilenamePositionBottomRight:
            xPos = bounds.size.width - width - padding;
            yPos = padding;
            break;
        case FilenamePositionTopLeft:
            xPos = padding;
            yPos = bounds.size.height - height - padding;
            break;
        case FilenamePositionTopRight:
            xPos = bounds.size.width - width - padding;
            yPos = bounds.size.height - height - padding;
            break;
    }

    self.filenameOverlayLayer.frame = CGRectMake(xPos, yPos, width, height);
    self.filenameOverlayLayer.contentsScale = [[NSScreen mainScreen] backingScaleFactor];

    // Add to layer hierarchy on top of everything
    [self.layer addSublayer:self.filenameOverlayLayer];
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
    if (tableView == self.categoryTableView) {
        return 3; // Source Folders, Playback, Display
    } else if (tableView == self.foldersTableView) {
        return self.folderBookmarks.count;
    }
    return 0;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (tableView == self.categoryTableView) {
        NSArray *categories = @[@"Source Folders", @"Playback", @"Display"];
        return categories[row];
    } else if (tableView == self.foldersTableView) {
        NSData *bookmarkData = self.folderBookmarks[row];
        NSURL *folderURL = [NSURL URLByResolvingBookmarkData:bookmarkData
                                                     options:0
                                               relativeToURL:nil
                                         bookmarkDataIsStale:NULL
                                                       error:NULL];
        return folderURL.lastPathComponent ?: @"Unknown Folder";
    }
    return nil;
}

#pragma mark - NSTableView Delegate

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSTableView *tableView = notification.object;
    if (tableView == self.categoryTableView) {
        NSInteger selectedRow = tableView.selectedRow;
        if (selectedRow == 0) {
            [self setupSourceFoldersPane];
        } else if (selectedRow == 1) {
            [self setupPlaybackPane];
        } else if (selectedRow == 2) {
            [self setupDisplayPane];
        }
        [self refreshUIFromDefaults];
    }
}

- (NSString *)tableView:(NSTableView *)tableView toolTipForCell:(NSCell *)cell rect:(NSRectPointer)rect tableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row mouseLocation:(NSPoint)mouseLocation {
    if (tableView == self.foldersTableView && row < self.folderBookmarks.count) {
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

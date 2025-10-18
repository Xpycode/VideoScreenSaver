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
static NSString * const kEnableAudioKey = @"enableAudio";
static NSString * const kShuffleKey = @"shuffle";
static NSString * const kLoopKey = @"loop";
static NSString * const kTransitionTypeKey = @"transitionType";
static NSString * const kTransitionDurationKey = @"transitionDuration";

// KVO context
static void * const kPlayerItemStatusContext = (void*)&kPlayerItemStatusContext;

typedef NS_ENUM(NSInteger, TransitionType) {
    TransitionTypeNone,
    TransitionTypeFade,
    TransitionTypeCrossDissolve
};

@interface Video_Screen_SaverView ()

// Configuration Sheet Properties
@property (strong) NSWindow *configSheet;
@property (strong) NSTextField *folderLabel;
@property (strong) NSButton *enableAudioCheckbox;
@property (strong) NSButton *shuffleCheckbox;
@property (strong) NSButton *loopCheckbox;
@property (strong) NSPopUpButton *transitionPopUpButton;
@property (strong) NSSlider *durationSlider;
@property (strong) NSTextField *durationLabel;

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
            kTransitionDurationKey: @1.5
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
        self.playerLayerA.videoGravity = AVLayerVideoGravityResizeAspectFill;
        self.playerLayerB.videoGravity = AVLayerVideoGravityResizeAspectFill;
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
    // ... folder bookmark resolution ... (shortened for clarity)
    id bookmarkObject = [defaults objectForKey:kVideoFolderBookmarkKey];
    if (!bookmarkObject || ![bookmarkObject isKindOfClass:[NSData class]]) { return; }
    NSURL *folderURL = [NSURL URLByResolvingBookmarkData:bookmarkObject options:NSURLBookmarkResolutionWithSecurityScope relativeToURL:nil bookmarkDataIsStale:NULL error:NULL];
    if (!folderURL || ![folderURL startAccessingSecurityScopedResource]) { return; }
    
    self.videoURLs = [self getVideoURLsFromFolder:folderURL];
    [folderURL stopAccessingSecurityScopedResource];

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
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *dirError = nil;
    NSArray<NSURL *> *files = [fm contentsOfDirectoryAtURL:folderURL
                              includingPropertiesForKeys:@[NSURLContentTypeKey]
                                                 options:NSDirectoryEnumerationSkipsHiddenFiles
                                                   error:&dirError];
    if (dirError) {
        os_log(OS_LOG_DEFAULT, "VideoScreenSaver: Error reading directory: %@", dirError);
        return @[];
    }
    
    NSMutableArray<NSURL *> *videoURLs = [NSMutableArray array];
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


#pragma mark - Configuration Sheet (Unchanged)
- (BOOL)hasConfigureSheet { return YES; }
- (NSWindow*)configureSheet {
    if (!self.configSheet) {
        NSRect frame = NSMakeRect(0, 0, 440, 280);
        self.configSheet = [[NSWindow alloc] initWithContentRect:frame styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO];
        self.configSheet.title = @"Video Screen Saver Settings";
        NSView *contentView = self.configSheet.contentView;
        int leftX = 20;
        self.enableAudioCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(leftX, 130, 150, 24)];
        [self.enableAudioCheckbox setButtonType:NSButtonTypeSwitch]; self.enableAudioCheckbox.title = @"Enable Audio";
        self.enableAudioCheckbox.target = self; self.enableAudioCheckbox.action = @selector(settingCheckboxClicked:);
        [contentView addSubview:self.enableAudioCheckbox];
        self.shuffleCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(leftX, 100, 150, 24)];
        [self.shuffleCheckbox setButtonType:NSButtonTypeSwitch]; self.shuffleCheckbox.title = @"Shuffle Videos";
        self.shuffleCheckbox.target = self; self.shuffleCheckbox.action = @selector(settingCheckboxClicked:);
        [contentView addSubview:self.shuffleCheckbox];
        self.loopCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(leftX, 70, 150, 24)];
        [self.loopCheckbox setButtonType:NSButtonTypeSwitch]; self.loopCheckbox.title = @"Loop Playlist";
        self.loopCheckbox.target = self; self.loopCheckbox.action = @selector(settingCheckboxClicked:);
        [contentView addSubview:self.loopCheckbox];
        int rightX = 220;
        NSTextField *transitionLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(rightX, 132, 80, 24)];
        transitionLabel.stringValue = @"Transition:"; transitionLabel.editable = NO; transitionLabel.bezeled = NO; transitionLabel.drawsBackground = NO;
        [contentView addSubview:transitionLabel];
        self.transitionPopUpButton = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(rightX + 80, 130, 140, 24)];
        [self.transitionPopUpButton addItemsWithTitles:@[@"None", @"Fade", @"Cross Dissolve"]];
        self.transitionPopUpButton.target = self; self.transitionPopUpButton.action = @selector(transitionChanged:);
        [contentView addSubview:self.transitionPopUpButton];
        NSTextField *durationTitleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(rightX, 102, 80, 24)];
        durationTitleLabel.stringValue = @"Duration:"; durationTitleLabel.editable = NO; durationTitleLabel.bezeled = NO; durationTitleLabel.drawsBackground = NO;
        [contentView addSubview:durationTitleLabel];
        self.durationSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(rightX, 75, 200, 24)];
        self.durationSlider.minValue = 0.5; self.durationSlider.maxValue = 5.0;
        self.durationSlider.target = self; self.durationSlider.action = @selector(sliderValueChanged:);
        [contentView addSubview:self.durationSlider];
        self.durationLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(rightX + 90, 102, 100, 24)];
        self.durationLabel.editable = NO; self.durationLabel.bezeled = NO; self.durationLabel.drawsBackground = NO;
        [contentView addSubview:self.durationLabel];
        self.folderLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 240, 400, 24)];
        self.folderLabel.editable = NO; self.folderLabel.bezeled = NO; self.folderLabel.drawsBackground = NO; self.folderLabel.selectable = NO;
        [contentView addSubview:self.folderLabel];
        NSButton *chooseButton = [[NSButton alloc] initWithFrame:NSMakeRect(20, 200, 140, 32)];
        chooseButton.title = @"Choose Folder…"; chooseButton.bezelStyle = NSBezelStyleRounded;
        chooseButton.target = self; chooseButton.action = @selector(chooseFolderClicked:);
        [contentView addSubview:chooseButton];
        NSButton *okButton = [[NSButton alloc] initWithFrame:NSMakeRect(340, 20, 80, 32)];
        okButton.title = @"OK"; okButton.bezelStyle = NSBezelStyleRounded; okButton.keyEquivalent = @"\r";
        okButton.target = self; okButton.action = @selector(closeConfigSheet:);
        [contentView addSubview:okButton];
    }
    
    [self updateFolderLabel];
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    self.enableAudioCheckbox.state = [defaults boolForKey:kEnableAudioKey] ? NSControlStateValueOn : NSControlStateValueOff;
    self.shuffleCheckbox.state = [defaults boolForKey:kShuffleKey] ? NSControlStateValueOn : NSControlStateValueOff;
    self.loopCheckbox.state = [defaults boolForKey:kLoopKey] ? NSControlStateValueOn : NSControlStateValueOff;
    [self.transitionPopUpButton selectItemAtIndex:[defaults integerForKey:kTransitionTypeKey]];
    self.durationSlider.doubleValue = [defaults doubleForKey:kTransitionDurationKey];
    [self updateDurationLabel];
    [self transitionChanged:self.transitionPopUpButton];

    return self.configSheet;
}

- (IBAction)chooseFolderClicked:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO; panel.canChooseDirectories = YES; panel.allowsMultipleSelection = NO; panel.prompt = @"Choose";
    [panel beginSheetModalForWindow:self.configSheet completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            NSURL *url = panel.URL;
            if (url) {
                NSError *error = nil;
                NSData *bookmarkData = [url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
                if (error) { return; }
                
                ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
                [defaults setObject:bookmarkData forKey:kVideoFolderBookmarkKey];
                [defaults synchronize];
                [self updateFolderLabel];
                
                if (self.isPreview) {
                    [self stopAnimation];
                    [self startAnimation];
                }
            }
        }
    }];
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

- (void)updateDurationLabel { self.durationLabel.stringValue = [NSString stringWithFormat:@"%.1f s", self.durationSlider.doubleValue]; }
- (IBAction)closeConfigSheet:(id)sender { [NSApp endSheet:self.configSheet]; }
- (void)updateFolderLabel {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    NSData *bookmarkData = [defaults objectForKey:kVideoFolderBookmarkKey];
    if (bookmarkData && [bookmarkData isKindOfClass:[NSData class]]) {
        NSURL *folderURL = [NSURL URLByResolvingBookmarkData:bookmarkData options:0 relativeToURL:nil bookmarkDataIsStale:NULL error:NULL];
        if (folderURL.path) {
            self.folderLabel.stringValue = [NSString stringWithFormat:@"Folder: %@", [folderURL.path stringByAbbreviatingWithTildeInPath]];
        } else {
            self.folderLabel.stringValue = @"Error: Could not read folder path.";
        }
    } else {
        self.folderLabel.stringValue = @"No folder selected.";
    }
}

@end

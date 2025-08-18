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

// UserDefaults Keys
static NSString * const kVideoFolderBookmarkKey = @"videoFolderBookmark";
static NSString * const kEnableAudioKey = @"enableAudio";
static NSString * const kShuffleKey = @"shuffle";
static NSString * const kLoopKey = @"loop";
static NSString * const kTransitionTypeKey = @"transitionType";
static NSString * const kTransitionDurationKey = @"transitionDuration";

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
        os_log(OS_LOG_DEFAULT, "Video Screen Saver: Initializing screensaver view (isPreview: %d)", isPreview);
        
        // Register default values
        ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
        [defaults registerDefaults:@{
            kEnableAudioKey: @YES,
            kShuffleKey: @NO,
            kLoopKey: @YES,
            kTransitionTypeKey: @(TransitionTypeCrossDissolve),
            kTransitionDurationKey: @1.5
        }];
    }
    return self;
}

- (void)startAnimation
{
    [super startAnimation];
    [self loadVideosAndPreparePlayer];
}

- (void)stopAnimation
{
    [super stopAnimation];
    if (self.player) {
        os_log(OS_LOG_DEFAULT, "Video Screen Saver: Stopping playback");
        [self.player pause];
        self.player = nil;
    }
    if (self.playerLayer) {
        [self.playerLayer removeFromSuperlayer];
        self.playerLayer = nil;
    }
}

- (void)animateOneFrame
{
    // No-op: AVPlayer handles playback
}


- (void)loadVideosAndPreparePlayer {
    if (self.player) {
        [self stopAnimation];
    }

    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    if (!self.isPreview) {
        [defaults synchronize];
    }
    
    id bookmarkObject = [defaults objectForKey:kVideoFolderBookmarkKey];
    
    if (!bookmarkObject || ![bookmarkObject isKindOfClass:[NSData class]]) {
        os_log(OS_LOG_DEFAULT, "Video Screen Saver: No valid bookmark data found.");
        return;
    }
    NSData *bookmarkData = (NSData *)bookmarkObject;

    BOOL isStale = NO;
    NSError *error = nil;
    NSURL *folderURL = [NSURL URLByResolvingBookmarkData:bookmarkData
                                                 options:NSURLBookmarkResolutionWithSecurityScope
                                           relativeToURL:nil
                                     bookmarkDataIsStale:&isStale
                                                   error:&error];

    if (error) {
        os_log(OS_LOG_DEFAULT, "Video Screen Saver: Error resolving bookmark: %{public}@", error.localizedDescription);
        return;
    }

    if (![folderURL startAccessingSecurityScopedResource]) {
        os_log(OS_LOG_DEFAULT, "Video Screen Saver: Failed to start accessing security-scoped resource.");
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *dirError = nil;
    NSArray *files = [fm contentsOfDirectoryAtURL:folderURL
                       includingPropertiesForKeys:nil
                                          options:NSDirectoryEnumerationSkipsHiddenFiles
                                            error:&dirError];
    [folderURL stopAccessingSecurityScopedResource];

    if (dirError) {
        os_log(OS_LOG_DEFAULT, "Video Screen Saver: Failed to enumerate folder: %{public}@", dirError.localizedDescription);
        return;
    }

    NSPredicate *videoPredicate = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
        NSString *ext = url.pathExtension.lowercaseString;
        return [@[@"mp4", @"mov", @"m4v"] containsObject:ext];
    }];
    self.videoURLs = [files filteredArrayUsingPredicate:videoPredicate];
    
    BOOL shuffle = [defaults boolForKey:kShuffleKey];
    if (shuffle && self.videoURLs.count > 1) {
        NSMutableArray *shuffled = [self.videoURLs mutableCopy];
        for (NSUInteger i = shuffled.count - 1; i > 0; i--) {
            [shuffled exchangeObjectAtIndex:i withObjectAtIndex:arc4random_uniform((uint32_t)i + 1)];
        }
        self.videoURLs = [shuffled copy];
    }

    os_log(OS_LOG_DEFAULT, "Video Screen Saver: Found %lu supported video(s) in folder", (unsigned long)self.videoURLs.count);

    if (self.videoURLs.count > 0) {
        self.currentVideoIndex = 0;
        [self playVideoAtIndex:self.currentVideoIndex];
    }
}

- (void)playVideoAtIndex:(NSUInteger)index {
    if (index >= self.videoURLs.count) return;

    NSURL *url = self.videoURLs[index];
    os_log(OS_LOG_DEFAULT, "Video Screen Saver: Playing video at index %lu: %{public}@", (unsigned long)index, url.path);

    AVPlayer *newPlayer = [AVPlayer playerWithURL:url];
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    newPlayer.muted = ![defaults boolForKey:kEnableAudioKey];
    newPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;

    AVPlayerLayer *newPlayerLayer = [AVPlayerLayer playerLayerWithPlayer:newPlayer];
    newPlayerLayer.frame = self.bounds;
    newPlayerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;

    AVPlayerLayer *oldPlayerLayer = self.playerLayer;
    self.player = newPlayer;
    self.playerLayer = newPlayerLayer;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidReachEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:self.player.currentItem];

    TransitionType transition = (TransitionType)[defaults integerForKey:kTransitionTypeKey];
    double duration = [defaults doubleForKey:kTransitionDurationKey];

    if (transition != TransitionTypeNone && oldPlayerLayer) {
        [self.player play];

        if (transition == TransitionTypeCrossDissolve) {
            newPlayerLayer.opacity = 0.0;
            [self.layer addSublayer:newPlayerLayer];

            [CATransaction begin];
            [CATransaction setAnimationDuration:duration];
            [CATransaction setCompletionBlock:^{
                [oldPlayerLayer removeFromSuperlayer];
            }];

            CABasicAnimation *fadeIn = [CABasicAnimation animationWithKeyPath:@"opacity"];
            fadeIn.fromValue = @(0.0);
            fadeIn.toValue = @(1.0);
            [newPlayerLayer addAnimation:fadeIn forKey:@"fadeIn"];
            newPlayerLayer.opacity = 1.0;

            CABasicAnimation *fadeOut = [CABasicAnimation animationWithKeyPath:@"opacity"];
            fadeOut.fromValue = @(1.0);
            fadeOut.toValue = @(0.0);
            [oldPlayerLayer addAnimation:fadeOut forKey:@"fadeOut"];
            oldPlayerLayer.opacity = 0.0;

            [CATransaction commit];
        } else if (transition == TransitionTypeFade) {
            [self.layer insertSublayer:newPlayerLayer below:oldPlayerLayer];
            
            [CATransaction begin];
            [CATransaction setAnimationDuration:duration];
            [CATransaction setCompletionBlock:^{
                [oldPlayerLayer removeFromSuperlayer];
            }];

            CABasicAnimation *fadeOut = [CABasicAnimation animationWithKeyPath:@"opacity"];
            fadeOut.fromValue = @(1.0);
            fadeOut.toValue = @(0.0);
            [oldPlayerLayer addAnimation:fadeOut forKey:@"fadeOut"];
            oldPlayerLayer.opacity = 0.0;

            [CATransaction commit];
        }
    } else {
        if (oldPlayerLayer) {
            [oldPlayerLayer removeFromSuperlayer];
        }
        [self.layer addSublayer:newPlayerLayer];
        [self.player play];
    }
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:notification.object];

    self.currentVideoIndex++;
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    BOOL loop = [defaults boolForKey:kLoopKey];

    if (self.currentVideoIndex >= self.videoURLs.count) {
        if (loop) {
            self.currentVideoIndex = 0;
        } else {
            [self stopAnimation];
            return;
        }
    }
    
    [self playVideoAtIndex:self.currentVideoIndex];
}

- (void)layout {
    [super layout];
    if (self.playerLayer) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.playerLayer.frame = self.bounds;
        });
    }
}

#pragma mark - Configuration Sheet

- (BOOL)hasConfigureSheet
{
    return YES;
}

- (NSWindow*)configureSheet
{
    if (!self.configSheet) {
        // Window
        NSRect frame = NSMakeRect(0, 0, 440, 280);
        self.configSheet = [[NSWindow alloc] initWithContentRect:frame
                                                       styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        self.configSheet.title = @"Video Screen Saver Settings";
        NSView *contentView = self.configSheet.contentView;

        // --- Left Column ---
        int leftX = 20;
        self.enableAudioCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(leftX, 130, 150, 24)];
        [self.enableAudioCheckbox setButtonType:NSButtonTypeSwitch];
        self.enableAudioCheckbox.title = @"Enable Audio";
        self.enableAudioCheckbox.target = self;
        self.enableAudioCheckbox.action = @selector(settingCheckboxClicked:);
        [contentView addSubview:self.enableAudioCheckbox];

        self.shuffleCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(leftX, 100, 150, 24)];
        [self.shuffleCheckbox setButtonType:NSButtonTypeSwitch];
        self.shuffleCheckbox.title = @"Shuffle Videos";
        self.shuffleCheckbox.target = self;
        self.shuffleCheckbox.action = @selector(settingCheckboxClicked:);
        [contentView addSubview:self.shuffleCheckbox];

        self.loopCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(leftX, 70, 150, 24)];
        [self.loopCheckbox setButtonType:NSButtonTypeSwitch];
        self.loopCheckbox.title = @"Loop Playlist";
        self.loopCheckbox.target = self;
        self.loopCheckbox.action = @selector(settingCheckboxClicked:);
        [contentView addSubview:self.loopCheckbox];

        // --- Right Column ---
        int rightX = 220;
        NSTextField *transitionLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(rightX, 132, 80, 24)];
        transitionLabel.stringValue = @"Transition:";
        transitionLabel.editable = NO;
        transitionLabel.bezeled = NO;
        transitionLabel.drawsBackground = NO;
        [contentView addSubview:transitionLabel];

        self.transitionPopUpButton = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(rightX + 80, 130, 140, 24)];
        [self.transitionPopUpButton addItemsWithTitles:@[@"None", @"Fade", @"Cross Dissolve"]];
        self.transitionPopUpButton.target = self;
        self.transitionPopUpButton.action = @selector(transitionChanged:);
        [contentView addSubview:self.transitionPopUpButton];

        NSTextField *durationTitleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(rightX, 102, 80, 24)];
        durationTitleLabel.stringValue = @"Duration:";
        durationTitleLabel.editable = NO;
        durationTitleLabel.bezeled = NO;
        durationTitleLabel.drawsBackground = NO;
        [contentView addSubview:durationTitleLabel];

        self.durationSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(rightX, 75, 200, 24)];
        self.durationSlider.minValue = 0.5;
        self.durationSlider.maxValue = 5.0;
        self.durationSlider.target = self;
        self.durationSlider.action = @selector(sliderValueChanged:);
        [contentView addSubview:self.durationSlider];
        
        self.durationLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(rightX + 90, 102, 100, 24)];
        self.durationLabel.editable = NO;
        self.durationLabel.bezeled = NO;
        self.durationLabel.drawsBackground = NO;
        [contentView addSubview:self.durationLabel];

        // --- Top and Bottom ---
        self.folderLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 240, 400, 24)];
        self.folderLabel.editable = NO;
        self.folderLabel.bezeled = NO;
        self.folderLabel.drawsBackground = NO;
        self.folderLabel.selectable = NO;
        [contentView addSubview:self.folderLabel];

        NSButton *chooseButton = [[NSButton alloc] initWithFrame:NSMakeRect(20, 200, 140, 32)];
        chooseButton.title = @"Choose Folder…";
        chooseButton.bezelStyle = NSBezelStyleRounded;
        chooseButton.target = self;
        chooseButton.action = @selector(chooseFolderClicked:);
        [contentView addSubview:chooseButton];
        
        NSButton *okButton = [[NSButton alloc] initWithFrame:NSMakeRect(340, 20, 80, 32)];
        okButton.title = @"OK";
        okButton.bezelStyle = NSBezelStyleRounded;
        okButton.keyEquivalent = @"\r";
        okButton.target = self;
        okButton.action = @selector(closeConfigSheet:);
        [contentView addSubview:okButton];
    }

    // Load saved settings
    [self updateFolderLabel];
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    self.enableAudioCheckbox.state = [defaults boolForKey:kEnableAudioKey] ? NSControlStateValueOn : NSControlStateValueOff;
    self.shuffleCheckbox.state = [defaults boolForKey:kShuffleKey] ? NSControlStateValueOn : NSControlStateValueOff;
    self.loopCheckbox.state = [defaults boolForKey:kLoopKey] ? NSControlStateValueOn : NSControlStateValueOff;
    [self.transitionPopUpButton selectItemAtIndex:[defaults integerForKey:kTransitionTypeKey]];
    self.durationSlider.doubleValue = [defaults doubleForKey:kTransitionDurationKey];
    [self updateDurationLabel];
    [self transitionChanged:self.transitionPopUpButton]; // Enable/disable slider

    return self.configSheet;
}

- (IBAction)chooseFolderClicked:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"Choose";
    [panel beginSheetModalForWindow:self.configSheet completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            NSURL *url = panel.URL;
            if (url) {
                NSError *error = nil;
                NSData *bookmarkData = [url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                                      includingResourceValuesForKeys:nil
                                                       relativeToURL:nil
                                                               error:&error];
                if (error) {
                    os_log(OS_LOG_DEFAULT, "Video Screen Saver: Failed to create bookmark: %{public}@", error.localizedDescription);
                    return;
                }
                
                ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
                [defaults setObject:bookmarkData forKey:kVideoFolderBookmarkKey];
                [defaults synchronize];
                [self updateFolderLabel];
                
                if (self.isPreview) {
                    [self loadVideosAndPreparePlayer];
                }
            }
        }
    }];
}

- (IBAction)settingCheckboxClicked:(NSButton *)sender {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    NSString *key = nil;
    if (sender == self.enableAudioCheckbox) {
        key = kEnableAudioKey;
        if (self.player) {
            self.player.muted = !(sender.state == NSControlStateValueOn);
        }
    } else if (sender == self.shuffleCheckbox) {
        key = kShuffleKey;
    } else if (sender == self.loopCheckbox) {
        key = kLoopKey;
    }
    
    if (key) {
        [defaults setBool:(sender.state == NSControlStateValueOn) forKey:key];
        [defaults synchronize];
    }
}

- (IBAction)transitionChanged:(NSPopUpButton *)sender {
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"VideoScreenSaverModule"];
    NSInteger selectedTransition = sender.indexOfSelectedItem;
    [defaults setInteger:selectedTransition forKey:kTransitionTypeKey];
    [defaults synchronize];
    
    // Disable duration slider if there's no transition
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
    [NSApp endSheet:self.configSheet];
}

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

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
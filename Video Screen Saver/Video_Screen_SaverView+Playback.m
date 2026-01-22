//
//  Video_Screen_SaverView+Playback.m
//  Video Screen Saver
//
//  Category containing video playback logic including playlist management,
//  video transitions, and KVO observation.
//

#import "Video_Screen_SaverView+Playback.h"
#import "Video_Screen_SaverView_Private.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <os/log.h>

@implementation Video_Screen_SaverView (Playback)

#pragma mark - Playlist Management

- (void)loadPlaylistAndStartPlayback {
    ScreenSaverDefaults *defaults = [self screenSaverDefaults];

    // Release any previously accessed folders before starting fresh
    for (NSURL *folderURL in self.accessedFolderURLs) {
        [folderURL stopAccessingSecurityScopedResource];
    }
    [self.accessedFolderURLs removeAllObjects];

    // Try new multiple folders format first
    NSArray *bookmarksArray = [defaults objectForKey:kVideoFoldersBookmarksKey];
    NSMutableArray<NSURL *> *allVideoURLs = [NSMutableArray array];
    NSMutableArray<NSData *> *updatedBookmarks = [NSMutableArray array];
    BOOL bookmarksNeedUpdate = NO;

    if (bookmarksArray != nil) {
        // New format exists (even if empty array) - use it
        if ([bookmarksArray isKindOfClass:[NSArray class]] && bookmarksArray.count > 0) {
            // Multiple folders mode
            for (id bookmarkObject in bookmarksArray) {
                if (![bookmarkObject isKindOfClass:[NSData class]]) continue;

                BOOL isStale = NO;
                NSError *error = nil;
                NSURL *folderURL = [NSURL URLByResolvingBookmarkData:bookmarkObject
                                                             options:NSURLBookmarkResolutionWithSecurityScope
                                                       relativeToURL:nil
                                                 bookmarkDataIsStale:&isStale
                                                               error:&error];
                if (!folderURL) {
                    os_log_error(VideoScreenSaverLog(), "VideoScreenSaver: Failed to resolve bookmark: %@", error);
                    continue;
                }

                if ([folderURL startAccessingSecurityScopedResource]) {
                    // Track accessed folder for cleanup in stopAnimation
                    [self.accessedFolderURLs addObject:folderURL];

                    NSArray<NSURL *> *folderVideos = [self getVideoURLsFromFolder:folderURL];
                    [allVideoURLs addObjectsFromArray:folderVideos];
                    // NOTE: Don't stop accessing - kept open for playback, released in stopAnimation

                    // Regenerate stale bookmarks
                    if (isStale) {
                        NSData *newBookmark = [folderURL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                                                  includingResourceValuesForKeys:nil
                                                                   relativeToURL:nil
                                                                           error:&error];
                        if (newBookmark) {
                            [updatedBookmarks addObject:newBookmark];
                            bookmarksNeedUpdate = YES;
                            os_log(VideoScreenSaverLog(), "VideoScreenSaver: Regenerated stale bookmark for: %@", folderURL.path);
                        } else {
                            [updatedBookmarks addObject:bookmarkObject]; // Keep old if regeneration fails
                        }
                    } else {
                        [updatedBookmarks addObject:bookmarkObject];
                    }
                } else {
                    os_log_error(VideoScreenSaverLog(), "VideoScreenSaver: Failed to access security-scoped folder: %@", folderURL);
                    [updatedBookmarks addObject:bookmarkObject]; // Keep bookmark even if access fails
                }
            }

            // Save updated bookmarks if any were stale
            if (bookmarksNeedUpdate) {
                [defaults setObject:updatedBookmarks forKey:kVideoFoldersBookmarksKey];
                [defaults synchronize];
            }
        }
        // else: empty array means user removed all folders - don't migrate!
    } else {
        // New format doesn't exist at all - try migration from legacy single folder
        id bookmarkObject = [defaults objectForKey:kVideoFolderBookmarkKey];
        if (bookmarkObject && [bookmarkObject isKindOfClass:[NSData class]]) {
            BOOL isStale = NO;
            NSURL *folderURL = [NSURL URLByResolvingBookmarkData:bookmarkObject
                                                         options:NSURLBookmarkResolutionWithSecurityScope
                                                   relativeToURL:nil
                                             bookmarkDataIsStale:&isStale
                                                           error:NULL];
            if (folderURL && [folderURL startAccessingSecurityScopedResource]) {
                // Track accessed folder for cleanup in stopAnimation
                [self.accessedFolderURLs addObject:folderURL];

                allVideoURLs = [[self getVideoURLsFromFolder:folderURL] mutableCopy];
                // NOTE: Don't stop accessing - kept open for playback, released in stopAnimation

                // Migrate to new format (regenerate if stale)
                NSData *newBookmark = bookmarkObject;
                if (isStale) {
                    NSData *regenerated = [folderURL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                                              includingResourceValuesForKeys:nil
                                                               relativeToURL:nil
                                                                       error:NULL];
                    if (regenerated) newBookmark = regenerated;
                }
                [defaults setObject:@[newBookmark] forKey:kVideoFoldersBookmarksKey];
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
    } else {
        [self showNoVideosFoundMessage];
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
        if ([[self screenSaverDefaults] boolForKey:kLoopKey]) {
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
        // ** CRITICAL: Remove observer from the old item BEFORE replacing it to prevent a retain cycle. **
        if (self.playerItemB) {
            [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:self.playerItemB];
        }
        // Remove KVO observer from old item if it exists
        @synchronized(self.observedItems) {
            if (self.playerItemB && [self.observedItems containsObject:self.playerItemB]) {
                @try {
                    [self.playerItemB removeObserver:self forKeyPath:@"status" context:kPlayerItemStatusContext];
                    [self.observedItems removeObject:self.playerItemB];
                } @catch (NSException *exception) {}
            }
        }
        self.playerItemB = playerItem;
        [self.playerB replaceCurrentItemWithPlayerItem:self.playerItemB];
        [self.playerItemB addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:kPlayerItemStatusContext];
        @synchronized(self.observedItems) {
            [self.observedItems addObject:self.playerItemB];
        }
    } else {
        // Player A is inactive, prepare it.
        // ** CRITICAL: Remove observer from the old item BEFORE replacing it to prevent a retain cycle. **
        if (self.playerItemA) {
            [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:self.playerItemA];
        }
        // Remove KVO observer from old item if it exists
        @synchronized(self.observedItems) {
            if (self.playerItemA && [self.observedItems containsObject:self.playerItemA]) {
                @try {
                    [self.playerItemA removeObserver:self forKeyPath:@"status" context:kPlayerItemStatusContext];
                    [self.observedItems removeObject:self.playerItemA];
                } @catch (NSException *exception) {}
            }
        }
        self.playerItemA = playerItem;
        [self.playerA replaceCurrentItemWithPlayerItem:self.playerItemA];
        [self.playerItemA addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:kPlayerItemStatusContext];
        @synchronized(self.observedItems) {
            [self.observedItems addObject:self.playerItemA];
        }
    }
}

#pragma mark - KVO Observation

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (context == kPlayerItemStatusContext) {
        AVPlayerItem *playerItem = (AVPlayerItem *)object;
        if (playerItem.status == AVPlayerItemStatusReadyToPlay) {
            // The item is buffered and ready. We can now transition.
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
            [self.activePlayer play];

            // Set up observers to prepare the *next* video.
            [self setupBoundaryTimeObserverForPlayer:self.activePlayer];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerItemDidReachEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:playerItem];

            // Reset failure counter on success
            self.consecutiveFailures = 0;

            // Unlock to allow the next video to be prepared.
            self.isPreparingNextVideo = NO;

        } else if (playerItem.status == AVPlayerItemStatusFailed) {
            // Handle failure. Log error and try the next video.
            os_log(VideoScreenSaverLog(), "VideoScreenSaver: Player item failed to load with error: %@", playerItem.error);

            // Remove the observer for the failed item
            @synchronized(self.observedItems) {
                if ([self.observedItems containsObject:playerItem]) {
                    @try {
                        [playerItem removeObserver:self forKeyPath:@"status" context:kPlayerItemStatusContext];
                        [self.observedItems removeObject:playerItem];
                    } @catch (NSException *exception) {}
                }
            }

            // Track consecutive failures
            self.consecutiveFailures++;

            // If all videos have failed, show error message
            if (self.consecutiveFailures >= self.videoURLs.count) {
                self.isPreparingNextVideo = NO; // Clear flag to allow recovery if playlist changes
                [self showAllVideosFailedMessage];
                return;
            }

            // Unlock and immediately try to prepare the next video in the playlist.
            self.isPreparingNextVideo = NO;
            [self prepareNextVideo];
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - Boundary Time Observer

- (void)setupBoundaryTimeObserverForPlayer:(AVPlayer *)player {
    ScreenSaverDefaults *defaults = [self screenSaverDefaults];
    TransitionType transition = (TransitionType)[defaults integerForKey:kTransitionTypeKey];
    if (transition == TransitionTypeNone || self.videoURLs.count < 2) {
        return; // No need for an observer if there's no transition or only one video
    }

    // Use the actual player item's duration for accuracy (metadata can be wrong)
    AVPlayerItem *currentItem = player.currentItem;
    if (!currentItem) return;

    CMTime videoDuration = currentItem.duration;
    if (CMTIME_IS_INVALID(videoDuration) || CMTIME_IS_INDEFINITE(videoDuration)) {
        return; // Duration not available
    }

    double videoDurationSeconds = CMTimeGetSeconds(videoDuration);
    double transitionDuration = [defaults doubleForKey:kTransitionDurationKey];

    // Ensure video is long enough for a meaningful playback before transition
    // Minimum 2 seconds of actual content before transition starts
    static const double kMinimumPlaybackBeforeTransition = 2.0;
    if (videoDurationSeconds < transitionDuration + kMinimumPlaybackBeforeTransition) {
        os_log(VideoScreenSaverLog(), "Video too short (%.1fs) for transition (%.1fs), skipping boundary observer",
               videoDurationSeconds, transitionDuration);
        return; // Video is too short, let it play to end naturally
    }

    CMTime boundaryTime = CMTimeMakeWithSeconds(videoDurationSeconds - transitionDuration, videoDuration.timescale);

    if (CMTIME_IS_INVALID(boundaryTime) || CMTimeCompare(boundaryTime, kCMTimeZero) <= 0) {
        return; // Boundary time is invalid or at/before start
    }

    os_log(VideoScreenSaverLog(), "Setting boundary observer: video=%.1fs, transition=%.1fs, boundary=%.1fs",
           videoDurationSeconds, transitionDuration, CMTimeGetSeconds(boundaryTime));

    // Capture the player reference NOW to avoid race condition with activePlayer changing
    __weak typeof(self) weakSelf = self;
    __weak AVPlayer *weakPlayer = player;
    self.timeObserverToken = [player addBoundaryTimeObserverForTimes:@[[NSValue valueWithCMTime:boundaryTime]] queue:dispatch_get_main_queue() usingBlock:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        __strong AVPlayer *strongPlayer = weakPlayer;
        if (!strongSelf || !strongPlayer) {
            return;
        }

        // Remove observer from the CAPTURED player, not activePlayer (which may have changed)
        if (strongSelf.timeObserverToken) {
            [strongPlayer removeTimeObserver:strongSelf.timeObserverToken];
            strongSelf.timeObserverToken = nil;
        }
        [strongSelf prepareNextVideo];
    }];
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:notification.object];

    BOOL isLastVideo = (self.currentVideoIndex == self.videoURLs.count - 1);
    BOOL isLooping = [[self screenSaverDefaults] boolForKey:kLoopKey];

    if (isLastVideo && !isLooping) {
        [self stopAnimation]; // Or let it sit on the last frame. Stopping seems cleaner.
    } else {
        [self prepareNextVideo];
    }
}

#pragma mark - Transitions

- (void)performTransitionFrom:(NSView *)oldView to:(NSView *)newView {
    ScreenSaverDefaults *defaults = [self screenSaverDefaults];
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

#pragma mark - Helper Methods

- (NSArray<NSURL *> *)getVideoURLsFromFolder:(NSURL *)folderURL {
    ScreenSaverDefaults *defaults = [self screenSaverDefaults];
    BOOL recursiveScan = [defaults boolForKey:kRecursiveScanKey];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSURL *> *videoURLs = [NSMutableArray array];

    if (recursiveScan) {
        // Recursive enumeration - scans all subdirectories
        NSDirectoryEnumerator<NSURL *> *enumerator = [fm enumeratorAtURL:folderURL
                                              includingPropertiesForKeys:@[NSURLContentTypeKey, NSURLIsDirectoryKey]
                                                                 options:NSDirectoryEnumerationSkipsHiddenFiles
                                                            errorHandler:^BOOL(NSURL *url, NSError *error) {
            os_log(VideoScreenSaverLog(), "VideoScreenSaver: Error reading %@: %@", url, error);
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
                UTType *type = [self typeFromContentTypeValue:contentType];
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
            os_log(VideoScreenSaverLog(), "VideoScreenSaver: Error reading directory: %@", dirError);
            return @[];
        }

        for (NSURL *fileURL in files) {
            id contentType = nil;
            NSError *utiError = nil;
            [fileURL getResourceValue:&contentType forKey:NSURLContentTypeKey error:&utiError];

            if (contentType && !utiError) {
                UTType *type = [self typeFromContentTypeValue:contentType];
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
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(self.isPreview ? kPreviewConcurrentLoadLimit : kNormalConcurrentLoadLimit);

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

#pragma mark - Message Display

- (void)showNoVideosFoundMessage {
    [self removeMessageTextLayer]; // Remove any existing message first
    CATextLayer *textLayer = [CATextLayer layer];
    textLayer.string = @"No videos found in the selected folders.\n\nPlease open Screen Saver settings and add video folders.";
    textLayer.font = (__bridge CFTypeRef)@"Helvetica";
    textLayer.fontSize = 24.0;
    textLayer.alignmentMode = kCAAlignmentCenter;
    textLayer.foregroundColor = [NSColor whiteColor].CGColor;
    textLayer.frame = self.bounds;
    textLayer.contentsScale = [self currentBackingScaleFactor];
    [self.layer addSublayer:textLayer];
    self.messageTextLayer = textLayer; // Track for cleanup
}

- (void)showAllVideosFailedMessage {
    [self removeMessageTextLayer]; // Remove any existing message first
    CATextLayer *textLayer = [CATextLayer layer];
    textLayer.string = @"Unable to play videos.\n\nAll video files failed to load. Please check that your video files are not corrupted.";
    textLayer.font = (__bridge CFTypeRef)@"Helvetica";
    textLayer.fontSize = 24.0;
    textLayer.alignmentMode = kCAAlignmentCenter;
    textLayer.foregroundColor = [NSColor whiteColor].CGColor;
    textLayer.frame = self.bounds;
    textLayer.contentsScale = [self currentBackingScaleFactor];
    [self.layer addSublayer:textLayer];
    self.messageTextLayer = textLayer; // Track for cleanup
}

@end

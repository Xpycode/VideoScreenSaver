//
//  Video_Screen_SaverView+ConfigSheet.m
//  Video Screen Saver
//
//  Category containing configuration sheet UI setup and action handlers.
//

#import "Video_Screen_SaverView+ConfigSheet.h"
#import "Video_Screen_SaverView_Private.h"
#import "Video_Screen_SaverView+Playback.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <os/log.h>

@implementation Video_Screen_SaverView (ConfigSheet)

#pragma mark - ScreenSaver Methods

- (BOOL)hasConfigureSheet {
    return YES;
}

- (NSWindow *)configureSheet {
    // CRITICAL: DO NOT MODIFY THIS PATTERN UNLESS ABSOLUTELY NECESSARY
    if (self.configSheet) {
        [self.configSheet orderOut:nil];
        self.configSheet = nil;
    }

    // ALWAYS reload from UserDefaults
    ScreenSaverDefaults *defaults = [self screenSaverDefaults];
    NSArray *savedBookmarks = [defaults objectForKey:kVideoFoldersBookmarksKey];
    self.folderBookmarks = savedBookmarks ? [savedBookmarks mutableCopy] : [NSMutableArray array];

    // Create window - size will be determined by the stack view's fitting size
    NSRect frame = NSMakeRect(0, 0, 480, 480);
    self.configSheet = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    self.configSheet.title = @"Video Screen Saver Settings";
    NSView *contentView = self.configSheet.contentView;

    // Setup all UI elements using NSStackView
    [self setupSinglePaneUI:contentView];

    // Update UI with current values
    [self refreshUIFromDefaults];
    [self updateStatsLabels];

    return self.configSheet;
}

#pragma mark - UI Setup

- (void)setupSinglePaneUI:(NSView *)contentView {
    // --- Main Vertical StackView ---
    NSStackView *mainStack = [NSStackView new];
    mainStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    mainStack.spacing = 16;
    mainStack.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:mainStack];

    // --- Source Folders ---
    CGFloat tableHeight = kFolderTableHeight;
    NSScrollView *foldersScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 0, tableHeight)];
    foldersScrollView.hasVerticalScroller = YES;
    foldersScrollView.borderType = NSBezelBorder;
    [foldersScrollView.heightAnchor constraintEqualToConstant:tableHeight].active = YES;

    self.foldersTableView = [[NSTableView alloc] initWithFrame:foldersScrollView.bounds];
    NSTableColumn *folderColumn = [[NSTableColumn alloc] initWithIdentifier:@"folder"];

    // Configure the cell for proper vertical centering
    NSTextFieldCell *cell = [[NSTextFieldCell alloc] init];
    cell.font = [NSFont systemFontOfSize:[NSFont systemFontSize]];
    [cell setControlSize:NSControlSizeRegular];
    folderColumn.dataCell = cell;

    [self.foldersTableView addTableColumn:folderColumn];
    self.foldersTableView.headerView = nil;
    self.foldersTableView.rowHeight = 20.0;
    self.foldersTableView.delegate = self;
    self.foldersTableView.dataSource = self;
    foldersScrollView.documentView = self.foldersTableView;
    [mainStack addArrangedSubview:foldersScrollView];

    self.emptyStateLabel = [[NSTextField alloc] initWithFrame:foldersScrollView.frame];
    self.emptyStateLabel.stringValue = @"No video folders configured.\nClick + to add one.";
    self.emptyStateLabel.alignment = NSTextAlignmentCenter;
    self.emptyStateLabel.textColor = [NSColor secondaryLabelColor];
    self.emptyStateLabel.editable = NO;
    self.emptyStateLabel.bordered = NO;
    self.emptyStateLabel.backgroundColor = [NSColor clearColor];
    self.emptyStateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:self.emptyStateLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.emptyStateLabel.centerXAnchor constraintEqualToAnchor:foldersScrollView.centerXAnchor],
        [self.emptyStateLabel.centerYAnchor constraintEqualToAnchor:foldersScrollView.centerYAnchor],
        [self.emptyStateLabel.widthAnchor constraintLessThanOrEqualToAnchor:foldersScrollView.widthAnchor constant:-20]
    ]];

    // --- Folder Controls Row ---
    NSStackView *folderControlsStack = [NSStackView new];
    folderControlsStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    folderControlsStack.spacing = 8;

    NSButton *addButton = [[NSButton alloc] init];
    addButton.title = @"+";
    addButton.target = self;
    addButton.action = @selector(addFolderClicked:);
    [addButton setBezelStyle:NSBezelStyleRounded];
    [folderControlsStack addArrangedSubview:addButton];

    NSButton *removeButton = [[NSButton alloc] init];
    removeButton.title = @"-";
    removeButton.target = self;
    removeButton.action = @selector(removeFolderClicked:);
    [removeButton setBezelStyle:NSBezelStyleRounded];
    [folderControlsStack addArrangedSubview:removeButton];

    [folderControlsStack addView:[NSView new] inGravity:NSStackViewGravityCenter]; // Spacer

    self.recursiveScanCheckbox = [[NSButton alloc] init];
    [self.recursiveScanCheckbox setButtonType:NSButtonTypeSwitch];
    self.recursiveScanCheckbox.title = @"Search Subfolders";
    self.recursiveScanCheckbox.target = self;
    self.recursiveScanCheckbox.action = @selector(recursiveScanCheckboxClicked:);
    [folderControlsStack addArrangedSubview:self.recursiveScanCheckbox];
    [mainStack addArrangedSubview:folderControlsStack];

    // --- Section Separator ---
    NSBox *separator1 = [[NSBox alloc] init];
    separator1.boxType = NSBoxSeparator;
    [mainStack addArrangedSubview:separator1];

    // --- Statistics ---
    self.statsLabel = [[NSTextField alloc] init];
    self.statsLabel.stringValue = @"Calculating...";
    self.statsLabel.alignment = NSTextAlignmentLeft;
    self.statsLabel.textColor = [NSColor secondaryLabelColor];
    self.statsLabel.editable = NO;
    self.statsLabel.bordered = NO;
    self.statsLabel.drawsBackground = NO;
    [mainStack addArrangedSubview:self.statsLabel];

    // --- Section Separator ---
    NSBox *separator2 = [[NSBox alloc] init];
    separator2.boxType = NSBoxSeparator;
    [mainStack addArrangedSubview:separator2];

    // --- Playback Row ---
    NSStackView *playbackStack = [NSStackView new];
    playbackStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    playbackStack.distribution = NSStackViewDistributionFillEqually;
    self.shuffleCheckbox = [[NSButton alloc] init];
    [self.shuffleCheckbox setButtonType:NSButtonTypeSwitch];
    self.shuffleCheckbox.title = @"Shuffle Videos";
    self.shuffleCheckbox.target = self;
    self.shuffleCheckbox.action = @selector(settingCheckboxClicked:);
    self.loopCheckbox = [[NSButton alloc] init];
    [self.loopCheckbox setButtonType:NSButtonTypeSwitch];
    self.loopCheckbox.title = @"Loop Playlist";
    self.loopCheckbox.target = self;
    self.loopCheckbox.action = @selector(settingCheckboxClicked:);
    [playbackStack addArrangedSubview:self.shuffleCheckbox];
    [playbackStack addArrangedSubview:self.loopCheckbox];
    [mainStack addArrangedSubview:playbackStack];

    // --- Section Separator ---
    NSBox *separator3 = [[NSBox alloc] init];
    separator3.boxType = NSBoxSeparator;
    [mainStack addArrangedSubview:separator3];

    // --- Display Rows ---
    self.scalingPopUpButton = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.scalingPopUpButton addItemsWithTitles:@[@"Fill Screen", @"Fit to Screen", @"Stretch"]];
    self.scalingPopUpButton.target = self;
    self.scalingPopUpButton.action = @selector(scalingChanged:);
    NSStackView *scalingStack = [self createLabelledControlStack:@"Video Scaling:" control:self.scalingPopUpButton];
    [mainStack addArrangedSubview:scalingStack];

    self.transitionPopUpButton = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.transitionPopUpButton addItemsWithTitles:@[@"None", @"Fade", @"Cross Dissolve"]];
    self.transitionPopUpButton.target = self;
    self.transitionPopUpButton.action = @selector(transitionChanged:);
    NSStackView *transitionStack = [self createLabelledControlStack:@"Transition:" control:self.transitionPopUpButton];
    [mainStack addArrangedSubview:transitionStack];

    self.durationSlider = [[NSSlider alloc] init];
    self.durationSlider.minValue = kMinTransitionDuration;
    self.durationSlider.maxValue = kMaxTransitionDuration;
    self.durationSlider.target = self;
    self.durationSlider.action = @selector(sliderValueChanged:);
    self.durationLabel = [[NSTextField alloc] init];
    self.durationLabel.stringValue = @"0.0 s";
    [self.durationLabel.widthAnchor constraintEqualToConstant:50].active = YES;
    NSStackView *durationStack = [self createLabelledControlStack:@"Duration:" control:self.durationSlider secondControl:self.durationLabel];
    [mainStack addArrangedSubview:durationStack];

    // --- Buttons ---
    NSButton *cancelButton = [[NSButton alloc] init];
    cancelButton.title = @"Cancel";
    cancelButton.bezelStyle = NSBezelStyleRounded;
    cancelButton.keyEquivalent = @"\e"; // Escape key
    cancelButton.target = self;
    cancelButton.action = @selector(cancel:);

    NSButton *okButton = [[NSButton alloc] init];
    okButton.title = @"OK";
    okButton.bezelStyle = NSBezelStyleRounded;
    okButton.keyEquivalent = @"\r"; // Enter key
    okButton.target = self;
    okButton.action = @selector(closeConfigSheet:);

    NSView *spacer = [NSView new];
    NSStackView *buttonStack = [NSStackView stackViewWithViews:@[spacer, cancelButton, okButton]];
    buttonStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttonStack.spacing = 8;
    [mainStack addArrangedSubview:buttonStack];

    // --- Finalize Layout ---
    [NSLayoutConstraint activateConstraints:@[
        [mainStack.topAnchor constraintEqualToAnchor:contentView.topAnchor],
        [mainStack.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor],
        [mainStack.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor],
        [mainStack.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor]
    ]];

    // Adjust window size to fit content
    NSRect contentRect = NSMakeRect(0, 0, mainStack.fittingSize.width, mainStack.fittingSize.height);
    NSRect newFrame = [self.configSheet frameRectForContentRect:contentRect];
    [self.configSheet setFrame:newFrame display:YES];
}

- (NSStackView *)createLabelledControlStack:(NSString *)title control:(NSView *)control {
    return [self createLabelledControlStack:title control:control secondControl:nil];
}

- (NSStackView *)createLabelledControlStack:(NSString *)title control:(NSView *)control secondControl:(NSView *)secondControl {
    NSStackView *stack = [NSStackView new];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.spacing = 8;
    stack.alignment = NSLayoutAttributeCenterY;

    NSTextField *label = [[NSTextField alloc] init];
    label.stringValue = title;
    label.editable = NO;
    label.bordered = NO;
    label.drawsBackground = NO;
    [label.widthAnchor constraintEqualToConstant:100].active = YES;
    label.alignment = NSTextAlignmentRight;

    [stack addArrangedSubview:label];
    [stack addArrangedSubview:control];
    if (secondControl) {
        [stack addArrangedSubview:secondControl];
    } else {
        [stack addView:[NSView new] inGravity:NSStackViewGravityCenter];
    }
    return stack;
}

- (void)refreshUIFromDefaults {
    ScreenSaverDefaults *defaults = [self screenSaverDefaults];

    if (self.shuffleCheckbox) {
        self.shuffleCheckbox.state = [defaults boolForKey:kShuffleKey] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (self.loopCheckbox) {
        self.loopCheckbox.state = [defaults boolForKey:kLoopKey] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (self.recursiveScanCheckbox) {
        self.recursiveScanCheckbox.state = [defaults boolForKey:kRecursiveScanKey] ? NSControlStateValueOn : NSControlStateValueOff;
    }

    if (self.scalingPopUpButton) {
        [self.scalingPopUpButton selectItemAtIndex:[defaults integerForKey:kVideoScalingKey]];
    }

    if (self.transitionPopUpButton) {
        [self.transitionPopUpButton selectItemAtIndex:[defaults integerForKey:kTransitionTypeKey]];
        [self transitionChanged:self.transitionPopUpButton];
    }
    if (self.durationSlider) {
        self.durationSlider.doubleValue = [defaults doubleForKey:kTransitionDurationKey];
        [self updateDurationLabel];
    }

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
                        [self updateStatsLabels];

                        if (self.isPreview) {
                            [self restartAnimationWithDelay];
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
            [self updateStatsLabels];

            if (self.videoURLs && self.videoURLs.count > 0) {
                [self restartAnimationWithDelay];
            }
        }
    }];
}

- (void)saveFolderBookmarks {
    ScreenSaverDefaults *defaults = [self screenSaverDefaults];
    [defaults setObject:self.folderBookmarks forKey:kVideoFoldersBookmarksKey];
    [defaults synchronize];
}

- (IBAction)settingCheckboxClicked:(NSButton *)sender {
    ScreenSaverDefaults *defaults = [self screenSaverDefaults];
    NSString *key = nil;
    if (sender == self.shuffleCheckbox) key = kShuffleKey;
    else if (sender == self.loopCheckbox) key = kLoopKey;

    if (key) {
        [defaults setBool:(sender.state == NSControlStateValueOn) forKey:key];
        [defaults synchronize];
        if (self.isPreview && [key isEqualToString:kShuffleKey]) {
            [self restartAnimationWithDelay];
        }
    }
}

- (IBAction)recursiveScanCheckboxClicked:(NSButton *)sender {
    ScreenSaverDefaults *defaults = [self screenSaverDefaults];
    BOOL isEnabled = (sender.state == NSControlStateValueOn);
    [defaults setBool:isEnabled forKey:kRecursiveScanKey];
    [defaults synchronize];
    [self updateStatsLabels];

    if (self.videoURLs && self.videoURLs.count > 0) {
        [self restartAnimationWithDelay];
    }
}

- (IBAction)transitionChanged:(NSPopUpButton *)sender {
    ScreenSaverDefaults *defaults = [self screenSaverDefaults];
    NSInteger selectedTransition = sender.indexOfSelectedItem;
    [defaults setInteger:selectedTransition forKey:kTransitionTypeKey];
    [defaults synchronize];

    self.durationSlider.enabled = (selectedTransition != TransitionTypeNone);
    self.durationLabel.textColor = (selectedTransition != TransitionTypeNone) ? [NSColor labelColor] : [NSColor disabledControlTextColor];
}

- (IBAction)sliderValueChanged:(NSSlider *)sender {
    ScreenSaverDefaults *defaults = [self screenSaverDefaults];
    [defaults setDouble:sender.doubleValue forKey:kTransitionDurationKey];
    [defaults synchronize];
    [self updateDurationLabel];
}

- (void)updateDurationLabel {
    self.durationLabel.stringValue = [NSString stringWithFormat:@"%.1f s", self.durationSlider.doubleValue];
}

- (IBAction)scalingChanged:(NSPopUpButton *)sender {
    ScreenSaverDefaults *defaults = [self screenSaverDefaults];
    NSInteger selectedScaling = sender.indexOfSelectedItem;
    [defaults setInteger:selectedScaling forKey:kVideoScalingKey];
    [defaults synchronize];

    NSString *videoGravity = [self videoGravityFromScaling:(VideoScaling)selectedScaling];
    self.playerLayerA.videoGravity = videoGravity;
    self.playerLayerB.videoGravity = videoGravity;

    if (self.isPreview) {
        [self restartAnimationWithDelay];
    }
}

- (IBAction)closeConfigSheet:(id)sender {
    NSWindow *sheet = self.configSheet;

    // macOS 26 (Sequoia) compatibility: properly dismiss the sheet
    if (sheet.sheetParent) {
        [sheet.sheetParent endSheet:sheet];
    } else {
        [NSApp endSheet:sheet];
    }

    [sheet orderOut:self];

    self.configSheet = nil;
    self.folderBookmarks = nil;
}

- (void)cancel:(id)sender {
    [self closeConfigSheet:sender];
}

#pragma mark - Statistics

- (void)updateStatsLabels {
    if (!self.statsLabel) return;
    self.statsLabel.stringValue = @"Calculating...";
    [self calculateStatistics];
}

- (void)calculateStatistics {
    ScreenSaverDefaults *defaults = [self screenSaverDefaults];
    BOOL recursive = [defaults boolForKey:kRecursiveScanKey];
    NSArray<NSData *> *bookmarks = [self.folderBookmarks copy];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __block NSInteger videoCount = 0;
        __block NSInteger subfolderCount = 0;
        __block double totalDuration = 0;
        NSFileManager *fm = [NSFileManager defaultManager];
        dispatch_group_t durationGroup = dispatch_group_create();

        NSMutableArray<NSURL *> *accessedFolders = [NSMutableArray array];

        for (NSData *bookmark in bookmarks) {
            NSURL *folderURL = [NSURL URLByResolvingBookmarkData:bookmark
                                                         options:NSURLBookmarkResolutionWithSecurityScope
                                                   relativeToURL:nil
                                             bookmarkDataIsStale:NULL
                                                           error:NULL];
            if (!folderURL) continue;
            if (![folderURL startAccessingSecurityScopedResource]) {
                os_log_error(VideoScreenSaverLog(), "VideoScreenSaver: Failed to access security-scoped folder for stats: %@", folderURL);
                continue;
            }
            [accessedFolders addObject:folderURL];

            NSDirectoryEnumerator<NSURL *> *enumerator = [fm enumeratorAtURL:folderURL
                                                  includingPropertiesForKeys:@[NSURLContentTypeKey, NSURLIsDirectoryKey]
                                                                     options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                errorHandler:nil];
            for (NSURL *fileURL in enumerator) {
                NSNumber *isDirectory = nil;
                [fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];

                if ([isDirectory boolValue]) {
                    subfolderCount++;
                    if (!recursive) {
                        [enumerator skipDescendants];
                    }
                } else {
                    id contentType = nil;
                    [fileURL getResourceValue:&contentType forKey:NSURLContentTypeKey error:nil];
                    UTType *type = [self typeFromContentTypeValue:contentType];
                    if (type && [type conformsToType:UTTypeMovie]) {
                        videoCount++;
                        dispatch_group_enter(durationGroup);
                        AVAsset *asset = [AVAsset assetWithURL:fileURL];
                        [asset loadValuesAsynchronouslyForKeys:@[@"duration"] completionHandler:^{
                            if ([asset statusOfValueForKey:@"duration" error:nil] == AVKeyValueStatusLoaded) {
                                @synchronized(durationGroup) {
                                    totalDuration += CMTimeGetSeconds(asset.duration);
                                }
                            }
                            dispatch_group_leave(durationGroup);
                        }];
                    }
                }
            }
        }

        dispatch_group_notify(durationGroup, dispatch_get_main_queue(), ^{
            for (NSURL *folderURL in accessedFolders) {
                [folderURL stopAccessingSecurityScopedResource];
            }

            NSString *durationString = [self formatDuration:totalDuration];
            self.statsLabel.stringValue = [NSString stringWithFormat:@"%ld Folders  •  %ld Subfolders  •  %ld Videos  •  Total Duration: %@",
                                           (long)bookmarks.count,
                                           (long)subfolderCount,
                                           (long)videoCount,
                                           durationString];
        });
    });
}

- (NSString *)formatDuration:(double)totalSeconds {
    if (totalSeconds < 0 || isnan(totalSeconds)) {
        return @"--:--:--";
    }
    int hours = floor(totalSeconds / 3600);
    int minutes = floor(fmod(totalSeconds, 3600) / 60);
    int seconds = fmod(totalSeconds, 60);
    return [NSString stringWithFormat:@"%02d:%02d:%02d", hours, minutes, seconds];
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

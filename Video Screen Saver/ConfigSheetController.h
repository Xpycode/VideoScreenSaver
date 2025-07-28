//
//  ConfigSheetController.h
//  Video Screen Saver
//
//  Created by sim on 28.07.25.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface ConfigSheetController : NSWindowController
@property (weak) IBOutlet NSButton *chooseFolder;
@property (weak) IBOutlet NSTextField *folderLabel;
@property (weak) IBOutlet NSButton *shuffle;
@property (weak) IBOutlet NSButton *loop;

// In ConfigSheetController.h
- (IBAction)chooseFolderClicked:(id)sender;
- (IBAction)okButtonClicked:(id)sender;

@end

NS_ASSUME_NONNULL_END

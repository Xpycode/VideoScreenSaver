//
//  Video_Screen_SaverView+ConfigSheet.h
//  Video Screen Saver
//
//  Category containing configuration sheet UI and action handlers.
//

#import "Video_Screen_SaverView.h"

@interface Video_Screen_SaverView (ConfigSheet)

// These methods are called by ScreenSaverView
- (BOOL)hasConfigureSheet;
- (NSWindow *)configureSheet;

@end

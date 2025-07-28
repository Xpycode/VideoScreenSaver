//
//  Video_Screen_SaverView.h
//  Video Screen Saver
//
//  Created by sim on 28.07.25.
//

#import <ScreenSaver/ScreenSaver.h>

@interface Video_Screen_SaverView : ScreenSaverView

- (BOOL)hasConfigureSheet;
- (NSWindow *)configureSheet;

@end

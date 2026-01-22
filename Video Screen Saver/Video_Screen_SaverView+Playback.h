//
//  Video_Screen_SaverView+Playback.h
//  Video Screen Saver
//
//  Category containing video playback logic.
//

#import "Video_Screen_SaverView.h"

@interface Video_Screen_SaverView (Playback)

- (void)loadPlaylistAndStartPlayback;
- (void)prepareNextVideo;
- (void)showNoVideosFoundMessage;
- (void)showAllVideosFailedMessage;

@end

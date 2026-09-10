#import <UIKit/UIKit.h>

/**
 * Fullscreen player for software-decoded media. Native controls only:
 * top toolbar (Done + title), bottom toolbar (play/pause, time labels,
 * seek slider), activity spinner while probing, alert on failure.
 */
@interface OPSoftPlayerViewController : UIViewController

- (id)initWithURLString:(NSString *)url title:(NSString *)title;

@end

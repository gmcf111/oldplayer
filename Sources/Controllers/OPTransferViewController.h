#import <UIKit/UIKit.h>
#import "OPFileSource.h"

/**
 * Modal progress sheet shown while a remote file is downloaded to the local
 * media cache before playback. Uses only UIProgressView / UILabel / UIButton.
 */
@interface OPTransferViewController : UIViewController <UIAlertViewDelegate>

- (id)initWithSource:(id<OPFileSource>)source
                item:(OPFileItem *)item
           localPath:(NSString *)localPath;

@property (nonatomic, copy) void (^onComplete)(NSString *localPath);
@property (nonatomic, copy) void (^onCancel)(void);

@end

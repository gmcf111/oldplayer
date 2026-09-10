#import <UIKit/UIKit.h>
#import "OPServer.h"
#import "OPFileSource.h"

/**
 * Browses one directory of a remote server. Each subdirectory pushes a new
 * instance sharing the same OPFileSource, so there is always a native
 * back-navigation stack.
 */
@interface OPFileBrowserViewController : UITableViewController

- (id)initWithServer:(OPServer *)server
              source:(id<OPFileSource>)source
                path:(NSString *)path;

@end

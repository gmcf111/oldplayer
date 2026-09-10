#import <UIKit/UIKit.h>
#import "OPServer.h"

/**
 * Add/edit form for an OPServer, built from native controls only
 * (UITableView grouped style + UITextField / UISegmentedControl / UISwitch).
 */
@interface OPServerEditViewController : UITableViewController

- (id)initWithServer:(OPServer *)server;
// Called with the saved server after the user taps 保存.
@property (nonatomic, copy) void (^onSave)(OPServer *server);

@end

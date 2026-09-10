#import "OPRootListViewController.h"

@implementation OPRootListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"OldPlayer";
    self.tableView.backgroundColor = [UIColor whiteColor];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"OPPlaceholderCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    }
    cell.textLabel.text = @"OldPlayer 已启动 (iOS 6-9 armv7)";
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

@end

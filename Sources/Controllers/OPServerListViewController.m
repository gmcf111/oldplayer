#import "OPServerListViewController.h"
#import "OPServerEditViewController.h"
#import "OPFileBrowserViewController.h"
#import "OPServerStore.h"
#import "OPFileSourceFactory.h"
#import "Constants.h"

@interface OPServerListViewController ()
@property (nonatomic, strong) NSArray *servers;
@end

@implementation OPServerListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"OldPlayer";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(addTapped)];
    self.tableView.tableFooterView = [[UIView alloc] init];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadServers];
}

- (void)reloadServers {
    self.servers = [OPServerStore servers];
    [self.tableView reloadData];
    if (self.servers.count == 0) {
        [self showEmptyState];
    } else {
        self.tableView.tableFooterView = [[UIView alloc] init];
    }
}

- (void)showEmptyState {
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 120)];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 40, footer.bounds.size.width - 40, 24)];
    title.text = @"还没有服务器";
    title.font = [UIFont boldSystemFontOfSize:16.0];
    title.textAlignment = NSTextAlignmentCenter;
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, 68, footer.bounds.size.width - 40, 40)];
    hint.text = @"点右上角 + 添加一个 WebDAV / FTP / SMB 服务器";
    hint.numberOfLines = 2;
    hint.textColor = [UIColor grayColor];
    hint.font = [UIFont systemFontOfSize:13.0];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    [footer addSubview:title];
    [footer addSubview:hint];
    self.tableView.tableFooterView = footer;
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.servers.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"OPServerCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    }
    OPServer *server = self.servers[indexPath.row];
    cell.textLabel.text = server.displayName;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  %@",
                                 [server protocolDisplayName], [server endpointDescription]];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    OPServer *server = self.servers[indexPath.row];
    id<OPFileSource> source = [OPFileSourceFactory sourceForServer:server];
    if (source == nil) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"暂不支持"
                                                        message:[NSString stringWithFormat:@"%@ 协议尚未实现。",
                                                                 [server protocolDisplayName]]
                                                       delegate:nil
                                              cancelButtonTitle:@"好"
                                              otherButtonTitles:nil];
        [alert show];
        return;
    }
    OPFileBrowserViewController *browser =
        [[OPFileBrowserViewController alloc] initWithServer:server
                                                     source:source
                                                       path:server.remotePath];
    [self.navigationController pushViewController:browser animated:YES];
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) {
        return;
    }
    OPServer *server = self.servers[indexPath.row];
    [OPServerStore removeServer:server];
    [self reloadServers];
}

#pragma mark - Actions

- (void)addTapped {
    OPServerEditViewController *editor = [[OPServerEditViewController alloc] initWithServer:nil];
    __weak OPServerListViewController *weakSelf = self;
    editor.onSave = ^(OPServer *server) {
        [OPServerStore upsertServer:server];
        [weakSelf reloadServers];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    [self presentViewController:nav animated:YES completion:nil];
}

@end

#import "OPServerEditViewController.h"

typedef NS_ENUM(NSInteger, OPEditRow) {
    OPEditRowName = 0,
    OPEditRowProtocol,
    OPEditRowHost,
    OPEditRowPort,
    OPEditRowPath,
    OPEditRowUsername,
    OPEditRowPassword,
    OPEditRowSecure,
};

@interface OPServerEditViewController () <UITextFieldDelegate>
@property (nonatomic, strong) OPServer *server;
@property (nonatomic, assign) BOOL isNew;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UITextField *hostField;
@property (nonatomic, strong) UITextField *portField;
@property (nonatomic, strong) UITextField *pathField;
@property (nonatomic, strong) UITextField *usernameField;
@property (nonatomic, strong) UITextField *passwordField;
@property (nonatomic, strong) UISegmentedControl *protocolControl;
@property (nonatomic, strong) UISwitch *secureSwitch;
@end

@implementation OPServerEditViewController

- (id)initWithServer:(OPServer *)server {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        if (server) {
            _server = server;
            _isNew = NO;
        } else {
            _server = [[OPServer alloc] init];
            _server.port = [_server defaultPort];
            _isNew = YES;
        }
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.isNew ? @"添加服务器" : @"编辑服务器";

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self
                                                      action:@selector(cancelTapped)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                      target:self
                                                      action:@selector(saveTapped)];

    self.nameField = [self makeTextField];
    self.nameField.placeholder = @"例如 家庭 NAS";
    self.nameField.text = self.server.displayName;

    self.hostField = [self makeTextField];
    self.hostField.placeholder = @"IP 或域名";
    self.hostField.keyboardType = UIKeyboardTypeURL;
    self.hostField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.hostField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.hostField.text = self.server.host;

    self.portField = [self makeTextField];
    self.portField.placeholder = @"端口";
    self.portField.keyboardType = UIKeyboardTypeNumberPad;
    self.portField.text = self.server.port > 0 ? [NSString stringWithFormat:@"%ld", (long)self.server.port] : @"";

    self.pathField = [self makeTextField];
    self.pathField.placeholder = @"/";
    self.pathField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.pathField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.pathField.text = self.server.remotePath ?: @"/";

    self.usernameField = [self makeTextField];
    self.usernameField.placeholder = @"用户名 (可留空)";
    self.usernameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.usernameField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.usernameField.text = self.server.username;

    self.passwordField = [self makeTextField];
    self.passwordField.placeholder = @"密码 (可留空)";
    self.passwordField.secureTextEntry = YES;
    self.passwordField.text = self.server.password;

    self.protocolControl = [[UISegmentedControl alloc] initWithItems:@[ @"WebDAV", @"FTP", @"SMB" ]];
    self.protocolControl.selectedSegmentIndex = self.server.protocolType;
    [self.protocolControl addTarget:self
                             action:@selector(protocolChanged)
                   forControlEvents:UIControlEventValueChanged];

    self.secureSwitch = [[UISwitch alloc] init];
    self.secureSwitch.on = self.server.secure;
}

- (UITextField *)makeTextField {
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
    field.borderStyle = UITextBorderStyleNone;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.returnKeyType = UIReturnKeyNext;
    field.delegate = self;
    field.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    return field;
}

- (void)protocolChanged {
    // Keep the port in sync with the protocol when the user has not typed one.
    NSInteger defaultPort = [self defaultPortForType:self.protocolControl.selectedSegmentIndex];
    NSInteger current = [self.portField.text integerValue];
    NSInteger previousDefault = [self defaultPortForType:self.server.protocolType];
    if (current == 0 || current == previousDefault) {
        self.portField.text = [NSString stringWithFormat:@"%ld", (long)defaultPort];
    }
    [self.tableView reloadData];
}

- (NSInteger)defaultPortForType:(OPProtocolType)type {
    switch (type) {
        case OPProtocolTypeFTP: return 21;
        case OPProtocolTypeSMB: return 445;
        default: return self.secureSwitch.on ? 443 : 80;
    }
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;                 // name, protocol
    if (section == 1) {
        // host, port, path, secure(WebDAV only)
        return self.protocolControl.selectedSegmentIndex == OPProtocolTypeWebDAV ? 4 : 3;
    }
    return 2;                                    // username, password
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 1) return @"服务器";
    if (section == 2) return @"认证 (可选)";
    return nil;
}

- (UITableViewCell *)cellWithField:(UITextField *)field {
    static NSString *identifier = @"OPFieldCell";
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    for (UIView *view in cell.contentView.subviews) {
        [view removeFromSuperview];
    }
    field.frame = CGRectMake(15, 7, cell.contentView.bounds.size.width - 30, 30);
    [cell.contentView addSubview:field];
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0 && indexPath.row == OPEditRowProtocol) {
        static NSString *identifier = @"OPProtocolCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        for (UIView *view in cell.contentView.subviews) {
            [view removeFromSuperview];
        }
        self.protocolControl.frame = CGRectMake(15, 7, cell.contentView.bounds.size.width - 30, 30);
        [cell.contentView addSubview:self.protocolControl];
        return cell;
    }
    if (indexPath.section == 1 && indexPath.row == 2) {
        return [self cellWithField:self.pathField];
    }
    if (indexPath.section == 1 && indexPath.row == 3) {
        static NSString *identifier = @"OPSecureCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        cell.textLabel.text = @"使用 HTTPS";
        cell.accessoryView = self.secureSwitch;
        return cell;
    }

    if (indexPath.section == 0) {
        return [self cellWithField:self.nameField];
    }
    if (indexPath.section == 1) {
        if (indexPath.row == 0) return [self cellWithField:self.hostField];
        return [self cellWithField:self.portField];
    }
    if (indexPath.row == 0) return [self cellWithField:self.usernameField];
    return [self cellWithField:self.passwordField];
}

#pragma mark - Actions

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)saveTapped {
    [self.view endEditing:YES];
    NSString *host = [self.hostField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (host.length == 0) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"缺少地址"
                                                        message:@"请输入服务器地址"
                                                       delegate:nil
                                              cancelButtonTitle:@"好"
                                              otherButtonTitles:nil];
        [alert show];
        return;
    }
    self.server.displayName = [self.nameField.text stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (self.server.displayName.length == 0) {
        self.server.displayName = host;
    }
    self.server.protocolType = self.protocolControl.selectedSegmentIndex;
    self.server.host = host;
    self.server.port = [self.portField.text integerValue];
    if (self.server.port <= 0) {
        self.server.port = [self defaultPortForType:self.server.protocolType];
    }
    self.server.username = self.usernameField.text ?: @"";
    self.server.password = self.passwordField.text ?: @"";
    NSString *path = [self.pathField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.server.remotePath = path.length ? path : @"/";
    if (![self.server.remotePath hasPrefix:@"/"]) {
        self.server.remotePath = [@"/" stringByAppendingString:self.server.remotePath];
    }
    self.server.secure = self.secureSwitch.on;

    if (self.onSave) {
        self.onSave(self.server);
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end

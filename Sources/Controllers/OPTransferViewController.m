#import "OPTransferViewController.h"

@interface OPTransferViewController ()
@property (nonatomic, strong) id<OPFileSource> source;
@property (nonatomic, strong) OPFileItem *item;
@property (nonatomic, copy) NSString *localPath;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL cancelled;
@end

@implementation OPTransferViewController

- (id)initWithSource:(id<OPFileSource>)source
                item:(OPFileItem *)item
           localPath:(NSString *)localPath {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _source = source;
        _item = item;
        _localPath = [localPath copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"下载中";
    self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self
                                                      action:@selector(cancelTapped)];

    CGFloat width = self.view.bounds.size.width;
    self.nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 40, width - 40, 44)];
    self.nameLabel.text = self.item.name;
    self.nameLabel.numberOfLines = 2;
    self.nameLabel.textAlignment = NSTextAlignmentCenter;
    self.nameLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.nameLabel];

    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.frame = CGRectMake(20, 100, width - 40, 10);
    self.progressView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.progressView];

    self.detailLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 120, width - 40, 24)];
    self.detailLabel.textAlignment = NSTextAlignmentCenter;
    self.detailLabel.textColor = [UIColor grayColor];
    self.detailLabel.font = [UIFont systemFontOfSize:13.0];
    self.detailLabel.text = @"正在准备…";
    self.detailLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.detailLabel];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.started) {
        self.started = YES;
        [self beginDownload];
    }
}

- (void)beginDownload {
    __weak OPTransferViewController *weakSelf = self;
    [self.source downloadFile:self.item
                       toPath:self.localPath
                     progress:^(long long received, long long total) {
        OPTransferViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (total > 0) {
            strongSelf.progressView.progress = (float)((double)received / (double)total);
            strongSelf.detailLabel.text = [NSString stringWithFormat:@"%@ / %@",
                                           [strongSelf formatBytes:received],
                                           [strongSelf formatBytes:total]];
        } else {
            strongSelf.detailLabel.text = [NSString stringWithFormat:@"已接收 %@",
                                           [strongSelf formatBytes:received]];
        }
    } completion:^(NSError *error) {
        OPTransferViewController *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.cancelled) return;
        if (error) {
            [strongSelf showError:error];
            return;
        }
        NSString *path = strongSelf.localPath;
        void (^complete)(NSString *) = strongSelf.onComplete;
        [strongSelf dismissViewControllerAnimated:YES completion:^{
            if (complete) complete(path);
        }];
    }];
}

- (NSString *)formatBytes:(long long)bytes {
    static const char *units[] = { "B", "KB", "MB", "GB" };
    double size = (double)bytes;
    int unit = 0;
    while (size >= 1024.0 && unit < 3) {
        size /= 1024.0;
        unit++;
    }
    if (unit == 0) {
        return [NSString stringWithFormat:@"%lld B", bytes];
    }
    return [NSString stringWithFormat:@"%.1f %s", size, units[unit]];
}

- (void)showError:(NSError *)error {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"下载失败"
                                                    message:error.localizedDescription ?: @"未知错误"
                                                   delegate:self
                                          cancelButtonTitle:@"好"
                                          otherButtonTitles:nil];
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.onCancel) self.onCancel();
    }];
}

- (void)cancelTapped {
    self.cancelled = YES;
    [self.source cancelAll];
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.onCancel) self.onCancel();
    }];
}

@end

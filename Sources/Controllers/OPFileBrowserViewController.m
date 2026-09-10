#import "OPFileBrowserViewController.h"
#import "OPMediaCache.h"
#import "OPTransferViewController.h"
#import "OPLocalHTTPProxy.h"
#import "OPSoftPlayerViewController.h"
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>

@interface OPFileBrowserViewController ()
@property (nonatomic, strong) OPServer *server;
@property (nonatomic, strong) id<OPFileSource> source;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, assign) BOOL loaded;
@property (nonatomic, strong) MPMoviePlayerViewController *moviePlayer;
// Set while a streamed item plays; used to fall back to download when the
// stream errors out before the first frame becomes playable.
@property (nonatomic, strong) OPFileItem *streamingItem;
@property (nonatomic, assign) BOOL streamBecamePlayable;
@end

@implementation OPFileBrowserViewController

- (id)initWithServer:(OPServer *)server
              source:(id<OPFileSource>)source
                path:(NSString *)path {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _server = server;
        _source = source;
        _path = [path copy] ?: @"/";
        _items = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    NSString *title = [self.path isEqualToString:@"/"] ? self.server.displayName : [self.path lastPathComponent];
    self.title = title.length ? title : self.server.displayName;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self
                                                      action:@selector(reloadTapped)];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    self.spinner.center = self.view.center;
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                    UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:self.spinner];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.loaded) {
        [self loadDirectory];
    } else {
        // The list may be stale after returning from a download/playback.
        [self addRefreshControlIfAvailable];
    }
}

- (void)addRefreshControlIfAvailable {
    // UIRefreshControl is iOS 6+, so guard for safety.
    if ([[UIRefreshControl class] instancesRespondToSelector:@selector(beginRefreshing)] &&
        self.refreshControl == nil) {
        UIRefreshControl *control = [[UIRefreshControl alloc] init];
        [control addTarget:self action:@selector(refreshPulled) forControlEvents:UIControlEventValueChanged];
        self.refreshControl = control;
    }
}

- (void)refreshPulled {
    [self loadDirectory];
}

- (void)reloadTapped {
    [self loadDirectory];
}

- (void)setLoading:(BOOL)loading {
    if (loading) {
        [self.spinner startAnimating];
        [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    } else {
        [self.spinner stopAnimating];
        [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
        [self.refreshControl endRefreshing];
    }
}

- (void)loadDirectory {
    [self setLoading:YES];
    __weak OPFileBrowserViewController *weakSelf = self;
    [self.source listDirectory:self.path completion:^(NSArray *items, NSError *error) {
        OPFileBrowserViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf setLoading:NO];
        strongSelf.loaded = YES;
        if (error) {
            [strongSelf showError:error];
            return;
        }
        strongSelf.items = items ?: @[];
        [strongSelf.tableView reloadData];
        if (strongSelf.items.count == 0) {
            [strongSelf showEmptyState];
        }
    }];
}

- (void)showEmptyState {
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 60)];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(footer.bounds, 20, 0)];
    label.text = @"此目录为空";
    label.textColor = [UIColor grayColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [footer addSubview:label];
    self.tableView.tableFooterView = footer;
}

- (void)showError:(NSError *)error {
    NSString *message = error.localizedDescription ?: @"未知错误";
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"无法访问"
                                                    message:message
                                                   delegate:nil
                                          cancelButtonTitle:@"好"
                                          otherButtonTitles:nil];
    [alert show];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"OPFileCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    }
    OPFileItem *item = self.items[indexPath.row];
    cell.textLabel.text = item.name;
    cell.imageView.image = nil;
    if (item.isDirectory) {
        cell.detailTextLabel.text = @"文件夹";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        NSString *size = [item formattedSize];
        NSString *type = [item.extensionLowercase uppercaseString];
        cell.detailTextLabel.text = size.length ? [NSString stringWithFormat:@"%@  %@", type, size] : type;
        cell.accessoryType = item.isMediaFile ? UITableViewCellAccessoryDisclosureIndicator
                                              : UITableViewCellAccessoryNone;
        cell.textLabel.textColor = item.isMediaFile ? [UIColor blackColor] : [UIColor grayColor];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    OPFileItem *item = self.items[indexPath.row];
    if (item.isDirectory) {
        OPFileBrowserViewController *child =
            [[OPFileBrowserViewController alloc] initWithServer:self.server
                                                         source:self.source
                                                           path:item.remotePath];
        [self.navigationController pushViewController:child animated:YES];
    } else if (item.isMediaFile) {
        [self playItem:item];
    } else {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"无法播放"
                                                        message:@"该文件格式暂不支持。"
                                                       delegate:nil
                                              cancelButtonTitle:@"好"
                                              otherButtonTitles:nil];
        [alert show];
    }
}

#pragma mark - Playback

// Streaming first: WebDAV hands out a direct HTTP(S) URL, while FTP/SMB go
// through the localhost proxy that translates Range requests. Anything that
// cannot stream falls back to download-then-play. Formats the system player
// cannot open (mkv/avi/rmvb/...) go through the FFmpeg soft decoder instead.
- (void)playItem:(OPFileItem *)item {
    if ([item isSoftDecodedFormat]) {
        [self softPlayItem:item];
        return;
    }
    NSURL *streamURL = [self streamURLForItem:item];
    if (streamURL) {
        [self playStreamURL:streamURL item:item];
        return;
    }
    [self downloadAndPlayItem:item];
}

// Soft path: stream when the URL is plain HTTP (WebDAV direct or the
// FTP/SMB localhost proxy - FFmpeg's http client seeks with Range just like
// MPMoviePlayer). WebDAV HTTPS has no TLS in the soft stack, so those files
// are downloaded first and decoded locally.
- (void)softPlayItem:(OPFileItem *)item {
    NSURL *streamURL = [self streamURLForItem:item];
    if (streamURL && ![[[streamURL scheme] lowercaseString] isEqualToString:@"https"]) {
        [self playSoftURLString:[streamURL absoluteString] title:item.name];
        return;
    }
    [self downloadAndSoftPlayItem:item];
}

- (void)downloadAndSoftPlayItem:(OPFileItem *)item {
    NSString *localPath = [OPMediaCache localPathForServer:self.server item:item];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:localPath error:NULL];
    if (attrs && [attrs fileSize] > 0) {
        [self playSoftURLString:localPath title:item.name];
        return;
    }

    OPTransferViewController *transfer =
        [[OPTransferViewController alloc] initWithSource:self.source item:item localPath:localPath];
    __weak OPFileBrowserViewController *weakSelf = self;
    transfer.onComplete = ^(NSString *path) {
        [weakSelf playSoftURLString:path title:item.name];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:transfer];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)playSoftURLString:(NSString *)urlString title:(NSString *)title {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:NULL];
    [[AVAudioSession sharedInstance] setActive:YES error:NULL];

    OPSoftPlayerViewController *player =
        [[OPSoftPlayerViewController alloc] initWithURLString:urlString title:title];
    [self presentViewController:player animated:YES completion:nil];
}

- (NSURL *)streamURLForItem:(OPFileItem *)item {
    if ([self.source respondsToSelector:@selector(streamURLForItem:)]) {
        NSURL *directURL = [self.source streamURLForItem:item];
        if (directURL) {
            return directURL;
        }
    }
    if (self.server.protocolType == OPProtocolTypeFTP ||
        self.server.protocolType == OPProtocolTypeSMB) {
        return [[OPLocalHTTPProxy sharedProxy] proxyURLForServer:self.server item:item];
    }
    return nil;
}

- (void)downloadAndPlayItem:(OPFileItem *)item {
    NSString *localPath = [OPMediaCache localPathForServer:self.server item:item];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:localPath error:NULL];
    if (attrs && [attrs fileSize] > 0) {
        [self playLocalPath:localPath];
        return;
    }

    OPTransferViewController *transfer =
        [[OPTransferViewController alloc] initWithSource:self.source item:item localPath:localPath];
    __weak OPFileBrowserViewController *weakSelf = self;
    transfer.onComplete = ^(NSString *path) {
        [weakSelf playLocalPath:path];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:transfer];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)playStreamURL:(NSURL *)url item:(OPFileItem *)item {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:NULL];
    [[AVAudioSession sharedInstance] setActive:YES error:NULL];

    self.streamingItem = item;
    self.streamBecamePlayable = NO;
    self.moviePlayer = [[MPMoviePlayerViewController alloc] initWithContentURL:url];
    self.moviePlayer.moviePlayer.shouldAutoplay = YES;
    self.moviePlayer.moviePlayer.controlStyle = MPMovieControlStyleDefault;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(moviePlaybackDidFinish:)
                                                 name:MPMoviePlayerPlaybackDidFinishNotification
                                               object:self.moviePlayer.moviePlayer];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(movieLoadStateDidChange:)
                                                 name:MPMoviePlayerLoadStateDidChangeNotification
                                               object:self.moviePlayer.moviePlayer];
    [self presentViewController:self.moviePlayer animated:YES completion:nil];
}

- (void)playLocalPath:(NSString *)localPath {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:NULL];
    [[AVAudioSession sharedInstance] setActive:YES error:NULL];

    self.streamingItem = nil;
    self.moviePlayer =
        [[MPMoviePlayerViewController alloc] initWithContentURL:[NSURL fileURLWithPath:localPath]];
    self.moviePlayer.moviePlayer.shouldAutoplay = YES;
    self.moviePlayer.moviePlayer.controlStyle = MPMovieControlStyleDefault;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(moviePlaybackDidFinish:)
                                                 name:MPMoviePlayerPlaybackDidFinishNotification
                                               object:self.moviePlayer.moviePlayer];
    [self presentViewController:self.moviePlayer animated:YES completion:nil];
}

- (void)movieLoadStateDidChange:(NSNotification *)notification {
    MPMovieLoadState state = self.moviePlayer.moviePlayer.loadState;
    if (state & (MPMovieLoadStatePlayable | MPMovieLoadStatePlaythroughOK)) {
        self.streamBecamePlayable = YES;
    }
}

- (void)moviePlaybackDidFinish:(NSNotification *)notification {
    id finishedPlayer = [notification object];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:MPMoviePlayerPlaybackDidFinishNotification
                                                  object:finishedPlayer];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:MPMoviePlayerLoadStateDidChangeNotification
                                                  object:finishedPlayer];

    NSNumber *reasonValue = [[notification userInfo] objectForKey:MPMoviePlayerPlaybackDidFinishReasonUserInfoKey];
    BOOL playbackError = (reasonValue.integerValue == MPMovieFinishReasonPlaybackError);
    BOOL earlyStreamError = (playbackError &&
                             self.streamingItem != nil && !self.streamBecamePlayable);
    OPFileItem *fallbackItem = earlyStreamError ? self.streamingItem : nil;
    // A real failure the user should know about: a local file that won't
    // play, or a stream that died after it had already started.
    BOOL reportError = (playbackError && fallbackItem == nil);
    self.streamingItem = nil;
    self.moviePlayer = nil;

    if (fallbackItem) {
        // The stream never became playable (auth, range or protocol issue):
        // transparently fall back to download-then-play.
        [self dismissViewControllerAnimated:YES completion:^{
            [self downloadAndPlayItem:fallbackItem];
        }];
    } else if (reportError) {
        [self dismissViewControllerAnimated:YES completion:^{
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"无法播放"
                                                            message:@"该媒体无法播放，文件可能已损坏或中断。"
                                                           delegate:nil
                                                  cancelButtonTitle:@"好"
                                                  otherButtonTitles:nil];
            [alert show];
        }];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

@end

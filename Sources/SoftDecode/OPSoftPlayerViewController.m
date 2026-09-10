#import "OPSoftPlayerViewController.h"
#import "OPSoftDecoder.h"
#import "OPSoftVideoView.h"
#import <AVFoundation/AVFoundation.h>

@interface OPSoftPlayerViewController () <OPSoftDecoderDelegate> {
    NSString *urlString;
    NSString *mediaTitle;
    OPSoftDecoder *decoder;
    OPSoftVideoView *videoView;
    UIToolbar *topBar;
    UIToolbar *bottomBar;
    UIBarButtonItem *playPauseItem;
    UIBarButtonItem *titleItem;
    UILabel *currentLabel;
    UILabel *durationLabel;
    UISlider *slider;
    UILabel *audioOnlyLabel;
    UIActivityIndicatorView *spinner;
    NSTimer *uiTimer;
    BOOL opened;
    BOOL dragging;
    BOOL dismissed;
}
@end

@implementation OPSoftPlayerViewController

- (id)initWithURLString:(NSString *)urlString title:(NSString *)title {
    self = [super init];
    if (self) {
        urlString = [urlString copy] ?: @"";
        mediaTitle = [title copy] ?: @"";
    }
    return self;
}

- (void)dealloc {
    [uiTimer invalidate];
    [decoder stop];
}

#pragma mark - View

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    videoView = [[OPSoftVideoView alloc] initWithFrame:self.view.bounds];
    videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:videoView];

    audioOnlyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    audioOnlyLabel.text = mediaTitle;
    audioOnlyLabel.textColor = [UIColor whiteColor];
    audioOnlyLabel.font = [UIFont boldSystemFontOfSize:17];
    audioOnlyLabel.textAlignment = NSTextAlignmentCenter;
    audioOnlyLabel.numberOfLines = 2;
    audioOnlyLabel.hidden = YES;
    [self.view addSubview:audioOnlyLabel];

    // Top bar: Done + title.
    topBar = [[UIToolbar alloc] init];
    topBar.barStyle = UIBarStyleBlack;
    topBar.translucent = YES;
    UIBarButtonItem *done =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(doneTapped)];
    titleItem = [[UIBarButtonItem alloc] initWithTitle:mediaTitle
                                                 style:UIBarButtonItemStylePlain
                                                target:nil
                                                action:nil];
    UIBarButtonItem *flexTop =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                      target:nil
                                                      action:nil];
    topBar.items = @[ done, flexTop, titleItem, flexTop ];
    topBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:topBar];

    // Bottom bar: play/pause, times, seek slider.
    bottomBar = [[UIToolbar alloc] init];
    bottomBar.barStyle = UIBarStyleBlack;
    bottomBar.translucent = YES;
    playPauseItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPause
                                                      target:self
                                                      action:@selector(playPauseTapped)];
    currentLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 52, 22)];
    currentLabel.text = @"0:00";
    currentLabel.textColor = [UIColor whiteColor];
    currentLabel.font = [UIFont systemFontOfSize:12];
    currentLabel.backgroundColor = [UIColor clearColor];
    UIBarButtonItem *currentItem =
        [[UIBarButtonItem alloc] initWithCustomView:currentLabel];
    slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 120, 22)];
    slider.continuous = YES;
    [slider addTarget:self action:@selector(sliderChanged)
     forControlEvents:UIControlEventValueChanged];
    [slider addTarget:self action:@selector(sliderTouchDown)
     forControlEvents:UIControlEventTouchDown];
    [slider addTarget:self action:@selector(sliderTouchUp)
     forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    UIBarButtonItem *sliderItem =
        [[UIBarButtonItem alloc] initWithCustomView:slider];
    durationLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 52, 22)];
    durationLabel.text = @"--:--";
    durationLabel.textColor = [UIColor whiteColor];
    durationLabel.font = [UIFont systemFontOfSize:12];
    durationLabel.backgroundColor = [UIColor clearColor];
    UIBarButtonItem *durationItem =
        [[UIBarButtonItem alloc] initWithCustomView:durationLabel];
    bottomBar.items = @[ playPauseItem, currentItem, sliderItem, durationItem ];
    bottomBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:bottomBar];

    spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    spinner.hidesWhenStopped = YES;
    spinner.center = self.view.center;
    spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
        UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin |
        UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:spinner];

    [self layoutBars];
}

- (void)layoutBars {
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat topH = 44;
    topBar.frame = CGRectMake(0, 0, w, topH);
    bottomBar.frame = CGRectMake(0, h - topH, w, topH);
    CGFloat sliderW = w - 52 - 52 - 60 - 40;
    if (sliderW < 60) sliderW = 60;
    slider.frame = CGRectMake(0, 0, sliderW, 22);
    audioOnlyLabel.frame = CGRectMake(20, (h - 80) / 2, w - 40, 80);
    titleItem.title = mediaTitle;
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    [self layoutBars];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:NULL];
    [[AVAudioSession sharedInstance] setActive:YES error:NULL];
    if (!decoder) {
        [spinner startAnimating];
        decoder = [[OPSoftDecoder alloc] initWithURLString:urlString title:mediaTitle];
        decoder.delegate = self;
        [decoder open];
        uiTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                   target:self
                                                 selector:@selector(refreshTime)
                                                 userInfo:nil
                                                  repeats:YES];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [uiTimer invalidate];
    uiTimer = nil;
    [decoder stop];
    decoder = nil;
}

#pragma mark - Controls

- (void)doneTapped {
    [self dismissNow];
}

- (void)dismissNow {
    if (dismissed) return;
    dismissed = YES;
    [uiTimer invalidate];
    uiTimer = nil;
    [decoder stop];
    decoder = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)playPauseTapped {
    if (!opened) return;
    if (decoder.playing) {
        [decoder pause];
    } else {
        [decoder play];
    }
    [self refreshPlayButton];
}

- (void)refreshPlayButton {
    UIBarButtonSystemItem item = decoder.playing ? UIBarButtonSystemItemPause
                                                : UIBarButtonSystemItemPlay;
    playPauseItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:item
                                                      target:self
                                                      action:@selector(playPauseTapped)];
    NSMutableArray *items = [bottomBar.items mutableCopy];
    if (items.count > 0) {
        [items replaceObjectAtIndex:0 withObject:playPauseItem];
        bottomBar.items = items;
    }
}

- (void)sliderTouchDown {
    dragging = YES;
}

- (void)sliderTouchUp {
    dragging = NO;
    if (opened && decoder.duration > 0) {
        [decoder seekToTime:slider.value];
        [self refreshTime];
    }
}

- (void)sliderChanged {
    currentLabel.text = [self formatTime:slider.value];
}

- (void)refreshTime {
    if (!opened || !decoder) return;
    double pos = decoder.currentTime;
    double dur = decoder.duration;
    if (!dragging) {
        if (dur > 0) {
            slider.enabled = YES;
            slider.minimumValue = 0;
            slider.maximumValue = (float)dur;
            slider.value = (float)pos;
        } else {
            slider.enabled = NO;
        }
        currentLabel.text = [self formatTime:pos];
    }
    if (dur > 0) {
        durationLabel.text = [self formatTime:dur];
    }
    [self refreshPlayButton];
}

- (NSString *)formatTime:(double)seconds {
    if (seconds < 0 || isnan(seconds)) seconds = 0;
    long total = (long)seconds;
    long h = total / 3600;
    long m = (total % 3600) / 60;
    long s = total % 60;
    if (h > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", h, m, s];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", m, s];
}

#pragma mark - OPSoftDecoderDelegate

- (void)softDecoderDidOpen:(OPSoftDecoder *)decoder {
    opened = YES;
    [spinner stopAnimating];
    if (!decoder.hasVideo && decoder.hasAudio) {
        audioOnlyLabel.hidden = NO;
        [videoView clear];
    }
    [self refreshTime];
    [self refreshPlayButton];
}

- (void)softDecoder:(OPSoftDecoder *)decoder
         didRenderY:(const uint8_t *)y
                  U:(const uint8_t *)u
                  V:(const uint8_t *)v
              width:(int)width
             height:(int)height
            strideY:(int)strideY
            strideU:(int)strideU
            strideV:(int)strideV {
    audioOnlyLabel.hidden = YES;
    [videoView displayY:y U:u V:v width:width height:height
                strideY:strideY strideU:strideU strideV:strideV];
}

- (void)softDecoder:(OPSoftDecoder *)decoder
  didUpdatePosition:(double)position
           duration:(double)duration {
    if (!dragging) {
        if (duration > 0) {
            slider.enabled = YES;
            slider.minimumValue = 0;
            slider.maximumValue = (float)duration;
            slider.value = (float)position;
            durationLabel.text = [self formatTime:duration];
        }
        currentLabel.text = [self formatTime:position];
    }
}

- (void)softDecoderDidFinish:(OPSoftDecoder *)decoder {
    [self dismissNow];
}

- (void)softDecoder:(OPSoftDecoder *)decoder didFailWithError:(NSError *)error {
    [spinner stopAnimating];
    NSString *message = error.localizedDescription ?: @"软解码失败";
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"无法播放"
                                                    message:message
                                                   delegate:nil
                                          cancelButtonTitle:@"好"
                                          otherButtonTitles:nil];
    [alert show];
    [self dismissNow];
}

@end

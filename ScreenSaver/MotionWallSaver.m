#import <ScreenSaver/ScreenSaver.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

// A separate system-hosted view. No desktop windows, login UI, or password handling.
@interface MotionWallSaverView : ScreenSaverView
@property(nonatomic, strong) AVQueuePlayer *player;
@property(nonatomic, strong) AVPlayerLooper *looper;
@property(nonatomic, strong) AVPlayerLayer *videoLayer;
@property(nonatomic, strong) NSTextField *messageLabel;
@property(nonatomic, strong) NSURL *movieURL;
@property(nonatomic) BOOL fillVideo;
@property(nonatomic) BOOL respectLowPower;
@property(nonatomic) BOOL playbackFailed;
@end

@implementation MotionWallSaverView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        self.animationTimeInterval = 1.0; // AVPlayerLayer renders the actual video frames.
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        self.videoLayer = [AVPlayerLayer layer];
        [self.layer addSublayer:self.videoLayer];
        self.messageLabel = [NSTextField wrappingLabelWithString:@""];
        self.messageLabel.textColor = NSColor.whiteColor;
        self.messageLabel.alignment = NSTextAlignmentCenter;
        self.messageLabel.font = [NSFont systemFontOfSize:isPreview ? 10 : 18];
        [self addSubview:self.messageLabel];
        // Some legacy hosts omit stopAnimation. These notifications are a
        // best-effort fallback; they never replace the normal view lifecycle.
        for (NSString *name in @[@"com.apple.screensaver.willstop", @"com.apple.screensaver.didstop",
                                  @"com.apple.screenIsUnlocked"]) {
            [NSDistributedNotificationCenter.defaultCenter addObserver:self
                selector:@selector(systemSaverEnded:) name:name object:nil];
        }
    }
    return self;
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.videoLayer.frame = self.bounds;
    [CATransaction commit];
    CGFloat inset = self.isPreview ? 8 : 30;
    CGFloat width = MAX(0, NSWidth(self.bounds) - inset * 2);
    self.messageLabel.frame = NSMakeRect(inset, MAX(0, NSMidY(self.bounds) - 45), width, 90);
}

- (void)startAnimation {
    [super startAnimation];
    [self releasePlayer];
    self.playbackFailed = NO;
    // Bundle resources are accessible to the sandboxed screen-saver host.
    // Never use Bundle.main: that would be the system's host application.
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    self.movieURL = [bundle URLForResource:@"wallpaper" withExtension:@"mp4"];
    NSURL *settingsURL = [bundle URLForResource:@"settings" withExtension:@"json"];
    NSData *data = settingsURL ? [NSData dataWithContentsOfURL:settingsURL] : nil;
    id settings = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    self.fillVideo = YES;
    self.respectLowPower = YES;
    if ([settings isKindOfClass:NSDictionary.class]) {
        if ([settings[@"fill"] isKindOfClass:NSNumber.class]) self.fillVideo = [settings[@"fill"] boolValue];
        if ([settings[@"respectLowPower"] isKindOfClass:NSNumber.class]) self.respectLowPower = [settings[@"respectLowPower"] boolValue];
    }
    [self updatePlayback];
    self.needsLayout = YES;
}

- (void)updatePlayback {
    if (self.playbackFailed) return;
    if (self.respectLowPower && NSProcessInfo.processInfo.lowPowerModeEnabled) {
        [self releasePlayer];
        self.messageLabel.stringValue = @"MotionWall\nПауза в режиме энергосбережения";
        self.messageLabel.hidden = NO;
        return;
    }
    if (!self.movieURL) {
        self.messageLabel.stringValue = @"MotionWall\nВыбери видео и установи видеозаставку заново в приложении.";
        self.messageLabel.hidden = NO;
        return;
    }
    if (!self.player) {
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:self.movieURL];
        self.player = [[AVQueuePlayer alloc] init];
        self.player.muted = YES;
        self.player.preventsDisplaySleepDuringVideoPlayback = NO;
        self.videoLayer.videoGravity = self.fillVideo ? AVLayerVideoGravityResizeAspectFill : AVLayerVideoGravityResizeAspect;
        self.videoLayer.player = self.player;
        self.looper = [AVPlayerLooper playerLooperWithPlayer:self.player templateItem:item];
        self.messageLabel.hidden = YES;
        [self.player play];
    }
    if (self.looper.status == AVPlayerLooperStatusFailed || self.player.status == AVPlayerStatusFailed ||
        self.player.currentItem.status == AVPlayerItemStatusFailed) {
        [self releasePlayer];
        self.playbackFailed = YES;
        self.messageLabel.stringValue = @"MotionWall\nНе удалось воспроизвести видео. Установи видеозаставку заново.";
        self.messageLabel.hidden = NO;
    }
}

- (void)animateOneFrame {
    if (self.isAnimating) [self updatePlayback];
}

- (void)systemSaverEnded:(NSNotification *)notification {
    if (self.isPreview) return;
    if (NSThread.isMainThread) {
        [self stopAnimation];
    } else {
        __weak MotionWallSaverView *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf stopAnimation]; });
    }
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window && self.player) [self stopAnimation];
}

- (void)releasePlayer {
    [self.player pause];
    [self.looper disableLooping];
    [self.player removeAllItems];
    self.videoLayer.player = nil;
    self.looper = nil;
    self.player = nil;
}

- (void)stopAnimation {
    [self releasePlayer];
    [super stopAnimation];
}

- (void)dealloc {
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
    [self releasePlayer];
}

- (BOOL)hasConfigureSheet { return NO; }
@end

#import <UIKit/UIKit.h>
#import <ReplayKit/ReplayKit.h>
#import <AVKit/AVKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>
#import "EngineBridge.h"
#import "Recognizer.h"
#import "Tracker.h"
#import "Shared.h"

@interface XQViewController : UIViewController
    <AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate>
@end

@implementation XQViewController {
    UITextView *_fenView;
    UILabel *_statusLabel;
    UILabel *_readLabel;
    UILabel *_bestLabel;
    UILabel *_cnLabel;
    UILabel *_infoLabel;
    UILabel *_hintLabel;
    UILabel *_depthLabel;
    UISlider *_depthSlider;
    UIView *_calLayer;
    RPSystemBroadcastPickerView *_picker;
    AVAudioPlayer *_player;

    AVSampleBufferDisplayLayer *_pipLayer;
    AVPictureInPictureController *_pip;

    int _calStep;
    CGPoint _calFirst;
    NSString *_lastFen;
    NSString *_lastCn;
    double _lastFrameAt;
    BOOL _reading;
    BOOL _pipWanted;
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"象棋连线";
    [self buildUI];
    XQStartFrameServer();
    [self setupPiP];
    [self startKeepAlive];
    [self setupNotifications];

    NSString *nnue = [[NSBundle mainBundle] pathForResource:@"pikafish" ofType:@"nnue"];
    if (nnue) [[XQEngine shared] startWithNNUE:nnue];

    __weak typeof(self) weakSelf = self;
    [XQEngine shared].onBestMove = ^(NSString *move) {
        __strong typeof(weakSelf) s = weakSelf;
        [s onBestMove:move];
    };
    [XQEngine shared].onInfo = ^(NSString *line) {
        __strong typeof(weakSelf) s = weakSelf;
        if (line.length > 110) line = [line substringToIndex:110];
        s->_infoLabel.text = line;
    };

    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        __strong typeof(weakSelf) s = weakSelf;
        s->_statusLabel.text = [XQEngine shared].ready ? @"引擎：就绪" : @"引擎：启动中…";
    }];

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    XQFrameNotifyCB, CFSTR(XQ_NOTIF_NAME),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void XQFrameNotifyCB(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                            const void *object, CFDictionaryRef userInfo) {
    XQViewController *vc = (__bridge XQViewController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{ [vc onFrameNotify]; });
}

#pragma mark - 读屏帧处理

- (void)onFrameNotify {
    if (!_reading) return;
    double now = [[NSDate date] timeIntervalSince1970];
    if (now - _lastFrameAt < 0.45) return;
    _lastFrameAt = now;

    void *buf = NULL; int w = 0, h = 0, stride = 0; double ts = 0;
    if (!XQTakeLatestFrame(&buf, &w, &h, &stride, &ts)) {
        if (!XQReadFrame(&buf, &w, &h, &stride, &ts)) return;
    }
    if (now - ts > 2.0) { free(buf); return; }

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    CGPoint tl = CGPointMake([d doubleForKey:@"tlX"], [d doubleForKey:@"tlY"]);
    CGPoint br = CGPointMake([d doubleForKey:@"brX"], [d doubleForKey:@"brY"]);
    if (br.x <= tl.x + 20 || br.y <= tl.y + 20) {
        free(buf);
        _readLabel.text = @"读屏：先标定棋盘（点两个对角交叉点）";
        return;
    }

    NSString *mv = nil;
    NSString *fen = [[XQTracker shared] feedFrame:buf width:w height:h stride:stride
                                       screenSize:[UIScreen mainScreen].bounds.size
                                               tl:tl br:br outMove:&mv];
    free(buf);

    if (!fen) {
        _readLabel.text = [NSString stringWithFormat:@"读屏：跟踪中…（已同步 %@）",
                           [[XQTracker shared] trackingReady] ? @"是" : @"否"];
        return;
    }

    _readLabel.text = [NSString stringWithFormat:@"读屏：✓ 对面走了 %@", mv ?: @"?"];
    _lastFen = fen;
    _fenView.text = fen;
    [[XQEngine shared] goFen:fen depth:(int)_depthSlider.value];
}

#pragma mark - UI

- (void)buildUI {
    CGFloat W = self.view.bounds.size.width;
    CGFloat y = 70;

    _statusLabel = [self labelWithFrame:CGRectMake(16, y, W - 32, 22) size:14 bold:YES];
    y += 26;
    _readLabel = [self labelWithFrame:CGRectMake(16, y, W - 32, 22) size:13 bold:NO];
    _readLabel.text = @"读屏：未开启";
    y += 30;

    _fenView = [[UITextView alloc] initWithFrame:CGRectMake(16, y, W - 32, 68)];
    _fenView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    _fenView.layer.borderWidth = 1.0;
    _fenView.layer.borderColor = [UIColor systemGray4Color].CGColor;
    _fenView.layer.cornerRadius = 8;
    _fenView.text = @"rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1";
    [self.view addSubview:_fenView];
    y += 78;

    _bestLabel = [self labelWithFrame:CGRectMake(16, y, W - 32, 46) size:36 bold:YES];
    _bestLabel.text = @"-";
    _bestLabel.textAlignment = NSTextAlignmentCenter;
    y += 48;

    _cnLabel = [self labelWithFrame:CGRectMake(16, y, W - 32, 34) size:24 bold:YES];
    _cnLabel.textAlignment = NSTextAlignmentCenter;
    _cnLabel.textColor = [UIColor systemRedColor];
    y += 40;

    _infoLabel = [self labelWithFrame:CGRectMake(16, y, W - 32, 26) size:10 bold:NO];
    _infoLabel.textColor = [UIColor secondaryLabelColor];
    y += 32;

    _depthLabel = [self labelWithFrame:CGRectMake(16, y, W - 32, 18) size:12 bold:NO];
    _depthLabel.text = @"搜索深度 12";
    y += 20;

    _depthSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, y, W - 32, 28)];
    _depthSlider.minimumValue = 6;
    _depthSlider.maximumValue = 22;
    _depthSlider.value = 12;
    [_depthSlider addTarget:self action:@selector(depthChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_depthSlider];
    y += 38;

    [self buttonWithTitle:@"① 标定棋盘（两个对角交叉点）" frame:CGRectMake(16, y, W - 32, 42) action:@selector(onCalibrate)];
    y += 50;
    [self buttonWithTitle:@"② 开始读屏（系统广播）" frame:CGRectMake(16, y, W - 32, 42) action:@selector(onStartRead)];
    y += 50;
    [self buttonWithTitle:@"③ 开启悬浮窗（PiP）" frame:CGRectMake(16, y, W - 32, 42) action:@selector(onTogglePiP)];
    y += 52;
    [self buttonWithTitle:@"④ 重新同步（回到开局）" frame:CGRectMake(16, y, W - 32, 42) action:@selector(onResync)];
    y += 50;

    _hintLabel = [self labelWithFrame:CGRectMake(16, y, W - 32, 40) size:11 bold:NO];
    _hintLabel.textColor = [UIColor secondaryLabelColor];
    _hintLabel.text = @"顺序：标定 → 开始广播 → 切到对面下棋，悬浮窗会一直显示最优着法。";
    y += 44;

    _picker = [[RPSystemBroadcastPickerView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    _picker.preferredExtension = @"com.yg.xiangqilink.broadcast";
    _picker.showsMicrophoneButton = NO;
    _picker.hidden = YES;
    [self.view addSubview:_picker];
}

- (UILabel *)labelWithFrame:(CGRect)f size:(CGFloat)s bold:(BOOL)b {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.font = b ? [UIFont boldSystemFontOfSize:s] : [UIFont systemFontOfSize:s];
    l.numberOfLines = 2;
    [self.view addSubview:l];
    return l;
}

- (void)buttonWithTitle:(NSString *)t frame:(CGRect)f action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    b.backgroundColor = [UIColor secondarySystemBackgroundColor];
    b.layer.cornerRadius = 10;
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
}

- (void)depthChanged { _depthLabel.text = [NSString stringWithFormat:@"搜索深度 %d", (int)_depthSlider.value]; }

#pragma mark - 读屏开关

- (void)onStartRead {
    _reading = YES;
    _readLabel.text = @"读屏：等待广播开始…";
    for (UIView *v in _picker.subviews)
        if ([v isKindOfClass:[UIButton class]]) {
            [(UIButton *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
            break;
        }
}

#pragma mark - 同步

- (void)onResync {
    [[XQTracker shared] resetToInitial];
    _lastFen = nil;
    _readLabel.text = @"读屏：已重置，等待基准帧…";
    _bestLabel.text = @"-";
    _cnLabel.text = @"";
}

#pragma mark - 标定

- (void)onCalibrate {
    _calStep = 0;
    _calFirst = CGPointZero;
    _calLayer = [[UIView alloc] initWithFrame:self.view.window.bounds];
    _calLayer.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, 70, _calLayer.bounds.size.width - 40, 40)];
    hint.tag = 99;
    hint.textAlignment = NSTextAlignmentCenter;
    hint.textColor = [UIColor whiteColor];
    hint.font = [UIFont boldSystemFontOfSize:17];
    hint.text = @"点棋盘【左上角交叉点】";
    [_calLayer addSubview:hint];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onCalTap:)];
    [_calLayer addGestureRecognizer:tap];
    [self.view.window addSubview:_calLayer];
}

- (void)onCalTap:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:_calLayer];
    UILabel *hint = (UILabel *)[_calLayer viewWithTag:99];
    if (_calStep == 0) { _calFirst = p; _calStep = 1; hint.text = @"点棋盘【右下角交叉点】"; return; }

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setDouble:MIN(_calFirst.x, p.x) forKey:@"tlX"];
    [d setDouble:MIN(_calFirst.y, p.y) forKey:@"tlY"];
    [d setDouble:MAX(_calFirst.x, p.x) forKey:@"brX"];
    [d setDouble:MAX(_calFirst.y, p.y) forKey:@"brY"];
    [_calLayer removeFromSuperview];
    _calLayer = nil;
}

#pragma mark - 结果展示

- (void)onBestMove:(NSString *)move {
    NSString *fen = _lastFen ?: _fenView.text;
    NSString *cn = [[XQRecognizer shared] chineseMoveForICCS:move fen:fen];
    _bestLabel.text = move;
    _cnLabel.text = cn;
    _lastCn = cn;

    [self renderPiPWithMove:cn iccs:move];
    if (!_pip || !_pip.isPictureInPictureActive) {
        [self postBanner:[NSString stringWithFormat:@"%@  (%@)", cn, move]];
    }
}

- (void)setupNotifications {
    [[UNUserNotificationCenter currentNotificationCenter]
        requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                     completionHandler:^(BOOL granted, NSError *err) {}];
}

- (void)postBanner:(NSString *)text {
    UNMutableNotificationContent *ct = [[UNMutableNotificationContent alloc] init];
    ct.title = @"象棋连线 · 最优着法";
    ct.body = text;
    if (@available(iOS 15.0, *)) ct.interruptionLevel = UNNotificationInterruptionLevelTimeSensitive;
    UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:@"xq_best" content:ct trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:req withCompletionHandler:nil];
}

#pragma mark - PiP 悬浮窗

- (void)setupPiP {
    _pipLayer = [[AVSampleBufferDisplayLayer alloc] init];
    _pipLayer.frame = CGRectMake(20, self.view.bounds.size.height - 120, 120, 60);
    _pipLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    [self.view.layer addSublayer:_pipLayer];

    if (![AVPictureInPictureController isPictureInPictureSupported]) {
        NSLog(@"[XQ] PiP unsupported");
        return;
    }

    AVPictureInPictureControllerContentSource *src =
        [[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:_pipLayer
                                                                        playbackDelegate:self];
    _pip = [[AVPictureInPictureController alloc] initWithContentSource:src];
    _pip.delegate = self;
    NSLog(@"[XQ] PiP ready=%d", _pip != nil);
}

- (void)onTogglePiP {
    if (!_pip) { NSLog(@"[XQ] no PiP controller"); return; }
    if (_pip.isPictureInPictureActive) {
        [_pip stopPictureInPicture];
        _pipWanted = NO;
        return;
    }
    _pipWanted = YES;
    [self renderPiPWithMove:_lastCn ?: @"等待识别…" iccs:nil];
    [_pip startPictureInPicture];
}

- (void)renderPiPWithMove:(NSString *)cn iccs:(NSString *)iccs {
    if (!_pipLayer) return;

    const int W = 480, H = 160;
    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    if (CVPixelBufferCreate(kCFAllocatorDefault, W, H, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess || !pb)
        return;

    CVPixelBufferLockBaseAddress(pb, 0);
    void *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, W, H, 8, bpr, cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);

    if (ctx) {
        CGContextSetRGBFillColor(ctx, 0.06, 0.07, 0.09, 1.0);
        CGContextFillRect(ctx, CGRectMake(0, 0, W, H));

        UIGraphicsPushContext(ctx);
        NSLog(@"[XQ] draw %@", cn);
        UIColor *fg = [UIColor colorWithRed:1.0 green:0.35 blue:0.3 alpha:1.0];
        NSDictionary *big = @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:64],
                               NSForegroundColorAttributeName: fg };
        [cn drawAtPoint:CGPointMake(20, 44) withAttributes:big];
        if (iccs.length) {
            NSDictionary *sm = @{ NSFontAttributeName: [UIFont monospacedSystemFontOfSize:26 weight:UIFontWeightMedium],
                                  NSForegroundColorAttributeName: [UIColor colorWithWhite:0.85 alpha:1.0] };
            [iccs drawAtPoint:CGPointMake(24, 10) withAttributes:sm];
        }
        UIGraphicsPopContext();
        CGContextRelease(ctx);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt) != noErr) {
        CVPixelBufferRelease(pb);
        return;
    }
    CMSampleTimingInfo timing = { CMTimeMake(1, 30), kCMTimeZero, kCMTimeInvalid };
    CMSampleBufferRef sb = NULL;
    if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fmt, &timing, &sb) == noErr) {
        [_pipLayer enqueueSampleBuffer:sb];
        [_pipLayer setNeedsDisplay];
        CFRelease(sb);
    }
    CFRelease(fmt);
    CVPixelBufferRelease(pb);
}

#pragma mark - AVPictureInPicture 代理

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)c {
    NSLog(@"[XQ] PiP started");
}
- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)c {
    NSLog(@"[XQ] PiP stopped");
}
- (void)pictureInPictureController:(AVPictureInPictureController *)c failedToStartPictureInPictureWithError:(NSError *)e {
    NSLog(@"[XQ] PiP failed: %@", e);
}
- (void)pictureInPictureController:(AVPictureInPictureController *)c
      restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    completionHandler(YES);
}
- (void)pictureInPictureController:(AVPictureInPictureController *)c setPlaying:(BOOL)playing {}
- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)c { return NO; }
- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)c {
    return CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
}
- (void)pictureInPictureController:(AVPictureInPictureController *)c
               didTransitionToRenderSize:(CMVideoDimensions)newSize {}
- (void)pictureInPictureController:(AVPictureInPictureController *)c
                   skipByInterval:(CMTime)interval
                  completionHandler:(void (^)(void))completionHandler {
    completionHandler();
}

#pragma mark - 保持后台运行

- (void)startKeepAlive {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s setCategory:AVAudioSessionCategoryPlayback
       withOptions:AVAudioSessionCategoryOptionMixWithOthers
             error:nil];
    [s setActive:YES error:nil];

    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"silence.wav"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        int sr = 8000, n = sr;
        NSMutableData *d = [NSMutableData data];
        [d appendBytes:"RIFF" length:4];
        uint32_t sz = 36 + n; [d appendBytes:&sz length:4];
        [d appendBytes:"WAVEfmt " length:8];
        uint32_t fmt = 16; [d appendBytes:&fmt length:4];
        uint16_t pcm = 1, ch = 1; [d appendBytes:&pcm length:2]; [d appendBytes:&ch length:2];
        uint32_t rate = sr; [d appendBytes:&rate length:4];
        uint32_t br = sr; [d appendBytes:&br length:4];
        uint16_t ba = 1, bps = 8; [d appendBytes:&ba length:2]; [d appendBytes:&bps length:2];
        [d appendBytes:"data" length:4];
        uint32_t ds = n; [d appendBytes:&ds length:4];
        uint8_t *zeros = calloc(n, 1);
        [d appendBytes:zeros length:n];
        free(zeros);
        [d writeToFile:path atomically:YES];
    }
    _player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil];
    _player.numberOfLoops = -1;
    _player.volume = 0;
    [_player play];
}

@end

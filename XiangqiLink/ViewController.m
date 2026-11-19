#import <UIKit/UIKit.h>
#import <ReplayKit/ReplayKit.h>
#import <UserNotifications/UserNotifications.h>
#import <AVFoundation/AVFoundation.h>
#import "EngineBridge.h"
#import "TouchInjector.h"
#import "Recognizer.h"
#import "Shared.h"

@interface XQViewController : UIViewController
@end

@implementation XQViewController {
    UITextView *_fenView;
    UILabel *_statusLabel;
    UILabel *_bestLabel;
    UILabel *_cnLabel;
    UILabel *_infoLabel;
    UILabel *_coordLabel;
    UILabel *_readLabel;
    UILabel *_depthLabel;
    UISlider *_depthSlider;
    UIView *_calLayer;
    RPSystemBroadcastPickerView *_picker;
    AVAudioPlayer *_player;
    int _calStep;
    CGPoint _calFirst;
    NSString *_lastFen;
    NSString *_lastBest;
    double _lastFrameAt;
    BOOL _reading;
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"象棋连线";
    [self buildUI];
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
        if (line.length > 120) line = [line substringToIndex:120];
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

- (void)onFrameNotify {
    if (!_reading) return;
    double now = [[NSDate date] timeIntervalSince1970];
    if (now - _lastFrameAt < 0.45) return;
    _lastFrameAt = now;

    void *buf = NULL; int w = 0, h = 0, stride = 0; double ts = 0;
    if (!XQReadFrame(&buf, &w, &h, &stride, &ts)) return;
    if (now - ts > 2.0) { free(buf); return; }        /* 超过 2 秒的帧不要 */

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    CGPoint tl = CGPointMake([d doubleForKey:@"tlX"], [d doubleForKey:@"tlY"]);
    CGPoint br = CGPointMake([d doubleForKey:@"brX"], [d doubleForKey:@"brY"]);
    if (br.x <= tl.x + 20 || br.y <= tl.y + 20) { free(buf); _readLabel.text = @"读屏：先标定棋盘"; return; }

    CGSize screen = [UIScreen mainScreen].bounds.size;
    double conf = 0;
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *fen = [[XQRecognizer shared] fenFromFrame:buf width:w height:h stride:stride
                                             screenSize:screen tl:tl br:br confidence:&conf debugDir:dir];
    free(buf);

    if (!fen) {
        _readLabel.text = [NSString stringWithFormat:@"读屏：识别中… 置信 %.2f", conf];
        return;
    }

    _readLabel.text = [NSString stringWithFormat:@"读屏：✓ 置信 %.2f  帧 %.1fs", conf, now - ts];
    if ([fen isEqualToString:_lastFen]) return;

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

    _fenView = [[UITextView alloc] initWithFrame:CGRectMake(16, y, W - 32, 76)];
    _fenView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _fenView.layer.borderWidth = 1.0;
    _fenView.layer.borderColor = [UIColor systemGray4Color].CGColor;
    _fenView.layer.cornerRadius = 8;
    _fenView.text = @"rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1";
    [self.view addSubview:_fenView];
    y += 86;

    _bestLabel = [self labelWithFrame:CGRectMake(16, y, W - 32, 44) size:34 bold:YES];
    _bestLabel.text = @"-";
    _bestLabel.textAlignment = NSTextAlignmentCenter;
    y += 46;

    _cnLabel = [self labelWithFrame:CGRectMake(16, y, W - 32, 30) size:22 bold:YES];
    _cnLabel.textAlignment = NSTextAlignmentCenter;
    _cnLabel.textColor = [UIColor systemRedColor];
    y += 36;

    _infoLabel = [self labelWithFrame:CGRectMake(16, y, W - 32, 28) size:10 bold:NO];
    _infoLabel.textColor = [UIColor secondaryLabelColor];
    _infoLabel.numberOfLines = 2;
    y += 34;

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

    [self buttonWithTitle:@"开始读屏（系统广播）" frame:CGRectMake(16, y, W - 32, 42) action:@selector(onStartRead)];
    y += 50;

    [self buttonWithTitle:@"标定棋盘（两个对角交叉点）" frame:CGRectMake(16, y, W - 32, 42) action:@selector(onCalibrate)];
    y += 50;

    [self buttonWithTitle:@"把最佳着法落到对面" frame:CGRectMake(16, y, W - 32, 42) action:@selector(onPlay)];
    y += 50;

    _coordLabel = [self labelWithFrame:CGRectMake(16, y, W - 32, 34) size:10 bold:NO];
    _coordLabel.numberOfLines = 2;
    _coordLabel.textColor = [UIColor secondaryLabelColor];
    [self refreshCoord];

    /* 系统广播选择器，隐藏起来由按钮触发 */
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

#pragma mark - 读屏

- (void)onStartRead {
    _reading = YES;
    _readLabel.text = @"读屏：等待广播开始…";
    /* 点一下系统广播选择器里的“开始直播” */
    for (UIView *v in _picker.subviews)
        if ([v isKindOfClass:[UIButton class]]) { [(UIButton *)v sendActionsForControlEvents:UIControlEventTouchUpInside]; break; }
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
    [self refreshCoord];
}

- (void)refreshCoord {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    _coordLabel.text = [NSString stringWithFormat:@"左上 %.0f,%.0f  右下 %.0f,%.0f   注入：%@",
                        [d doubleForKey:@"tlX"], [d doubleForKey:@"tlY"],
                        [d doubleForKey:@"brX"], [d doubleForKey:@"brY"],
                        [XQInjector shared].available ? @"可用" : @"不可用"];
}

#pragma mark - 结果展示

- (void)onBestMove:(NSString *)move {
    _lastBest = move;
    _bestLabel.text = move;
    NSString *fen = _lastFen ?: _fenView.text;
    NSString *cn = [[XQRecognizer shared] chineseMoveForICCS:move fen:fen];
    _cnLabel.text = cn;
    [self postBanner:[NSString stringWithFormat:@"%@  (%@)", cn, move]];
}

- (void)setupNotifications {
    UNUserNotificationCenter *c = [UNUserNotificationCenter currentNotificationCenter];
    [c requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                     completionHandler:^(BOOL granted, NSError *err) {
        NSLog(@"[XQ] notification granted=%d", granted);
    }];
}

- (void)postBanner:(NSString *)text {
    UNMutableNotificationContent *ct = [[UNMutableNotificationContent alloc] init];
    ct.title = @"象棋连线 · 最优着法";
    ct.body = text;
    if (@available(iOS 15.0, *)) ct.interruptionLevel = UNNotificationInterruptionLevelTimeSensitive;
    UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:@"xq_best" content:ct trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:req withCompletionHandler:^(NSError *e) {
        if (e) NSLog(@"[XQ] banner err %@", e);
    }];
}

#pragma mark - 保持后台运行（静音播放）

- (void)startKeepAlive {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [s setActive:YES error:nil];

    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"silence.wav"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        /* 1 秒 8kHz 单声道静音 wav */
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
    NSError *err = nil;
    _player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&err];
    if (err) { NSLog(@"[XQ] keepalive err %@", err); return; }
    _player.numberOfLoops = -1;
    _player.volume = 0;
    [_player play];
}

#pragma mark - 落子

- (CGPoint)pointForSquare:(NSString *)sq {
    if (sq.length != 2) return CGPointZero;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    double tlX = [d doubleForKey:@"tlX"], tlY = [d doubleForKey:@"tlY"];
    double brX = [d doubleForKey:@"brX"], brY = [d doubleForKey:@"brY"];
    int file = [sq characterAtIndex:0] - 'a';
    int rank = [sq characterAtIndex:1] - '0';
    if (file < 0 || file > 8 || rank < 0 || rank > 9) return CGPointZero;
    double cellW = (brX - tlX) / 8.0, cellH = (brY - tlY) / 9.0;
    return CGPointMake(tlX + file * cellW, tlY + (9 - rank) * cellH);
}

- (void)onPlay {
    if (!_lastBest || _lastBest.length < 4) return;
    CGPoint p1 = [self pointForSquare:[_lastBest substringWithRange:NSMakeRange(0, 2)]];
    CGPoint p2 = [self pointForSquare:[_lastBest substringWithRange:NSMakeRange(2, 2)]];
    [[XQInjector shared] tapX:p1.x y:p1.y];
    usleep(120000);
    [[XQInjector shared] tapX:p2.x y:p2.y];
}

@end

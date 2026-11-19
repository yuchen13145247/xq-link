#import <UIKit/UIKit.h>
#import "EngineBridge.h"
#import "TouchInjector.h"

@interface XQViewController : UIViewController
@end

@implementation XQViewController {
    UITextView *_fenView;
    UILabel *_statusLabel;
    UILabel *_bestLabel;
    UILabel *_infoLabel;
    UILabel *_coordLabel;
    UILabel *_depthLabel;
    UISlider *_depthSlider;
    UIView *_calLayer;
    int _calStep;
    CGPoint _calFirst;
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"象棋连线";
    [self buildUI];

    NSString *nnue = [[NSBundle mainBundle] pathForResource:@"pikafish" ofType:@"nnue"];
    if (nnue) {
        [[XQEngine shared] startWithNNUE:nnue];
    } else {
        NSLog(@"[XQ] 缺少 pikafish.nnue");
    }

    __weak typeof(self) weakSelf = self;
    [XQEngine shared].onBestMove = ^(NSString *move) {
        __strong typeof(weakSelf) self2 = weakSelf;
        self2->_bestLabel.text = move;
    };
    [XQEngine shared].onInfo = ^(NSString *line) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (line.length > 120) line = [line substringToIndex:120];
        self2->_infoLabel.text = line;
    };

    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        __strong typeof(weakSelf) self2 = weakSelf;
        self2->_statusLabel.text = [XQEngine shared].ready ? @"引擎：就绪" : @"引擎：启动中…";
    }];
}

#pragma mark - UI

- (void)buildUI {
    CGFloat W = self.view.bounds.size.width;
    CGFloat y = 70;

    _statusLabel = [self labelWithFrame:CGRectMake(16, y, W - 32, 24) size:15 bold:YES];
    y += 32;

    _fenView = [[UITextView alloc] initWithFrame:CGRectMake(16, y, W - 32, 96)];
    _fenView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _fenView.layer.borderWidth = 1.0;
    _fenView.layer.borderColor = [UIColor systemGray4Color].CGColor;
    _fenView.layer.cornerRadius = 8;
    _fenView.text = @"rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1";
    [self.view addSubview:_fenView];
    y += 106;

    _depthLabel = [self labelWithFrame:CGRectMake(16, y, W - 32, 20) size:13 bold:NO];
    _depthLabel.text = @"搜索深度 14";
    y += 24;

    _depthSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, y, W - 32, 30)];
    _depthSlider.minimumValue = 6;
    _depthSlider.maximumValue = 24;
    _depthSlider.value = 14;
    [_depthSlider addTarget:self action:@selector(depthChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_depthSlider];
    y += 42;

    [self buttonWithTitle:@"计算最佳着法" frame:CGRectMake(16, y, W - 32, 44) action:@selector(onCalc)];
    y += 56;

    _bestLabel = [self labelWithFrame:CGRectMake(16, y, W - 32, 40) size:30 bold:YES];
    _bestLabel.text = @"-";
    _bestLabel.textAlignment = NSTextAlignmentCenter;
    y += 44;

    _infoLabel = [self labelWithFrame:CGRectMake(16, y, W - 32, 34) size:11 bold:NO];
    _infoLabel.numberOfLines = 2;
    _infoLabel.textColor = [UIColor secondaryLabelColor];
    y += 40;

    [self buttonWithTitle:@"标定棋盘（点两个对角交叉点）" frame:CGRectMake(16, y, W - 32, 44) action:@selector(onCalibrate)];
    y += 56;

    [self buttonWithTitle:@"把最佳着法落到对面" frame:CGRectMake(16, y, W - 32, 44) action:@selector(onPlay)];
    y += 56;

    _coordLabel = [self labelWithFrame:CGRectMake(16, y, W - 32, 40) size:11 bold:NO];
    _coordLabel.numberOfLines = 2;
    _coordLabel.textColor = [UIColor secondaryLabelColor];
    [self refreshCoord];
}

- (UILabel *)labelWithFrame:(CGRect)f size:(CGFloat)s bold:(BOOL)b {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.font = b ? [UIFont boldSystemFontOfSize:s] : [UIFont systemFontOfSize:s];
    l.numberOfLines = 0;
    [self.view addSubview:l];
    return l;
}

- (void)buttonWithTitle:(NSString *)t frame:(CGRect)f action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    b.backgroundColor = [UIColor secondarySystemBackgroundColor];
    b.layer.cornerRadius = 10;
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
}

- (void)depthChanged {
    _depthLabel.text = [NSString stringWithFormat:@"搜索深度 %d", (int)_depthSlider.value];
}

#pragma mark - 标定

- (void)onCalibrate {
    _calStep = 0;
    _calFirst = CGPointZero;
    _calLayer = [[UIView alloc] initWithFrame:self.view.window.bounds];
    _calLayer.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    _calLayer.userInteractionEnabled = YES;

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
    if (_calStep == 0) {
        _calFirst = p;
        _calStep = 1;
        hint.text = @"点棋盘【右下角交叉点】";
        return;
    }
    CGPoint tl = CGPointMake(MIN(_calFirst.x, p.x), MIN(_calFirst.y, p.y));
    CGPoint br = CGPointMake(MAX(_calFirst.x, p.x), MAX(_calFirst.y, p.y));
    [[NSUserDefaults standardUserDefaults] setDouble:tl.x forKey:@"tlX"];
    [[NSUserDefaults standardUserDefaults] setDouble:tl.y forKey:@"tlY"];
    [[NSUserDefaults standardUserDefaults] setDouble:br.x forKey:@"brX"];
    [[NSUserDefaults standardUserDefaults] setDouble:br.y forKey:@"brY"];
    [_calLayer removeFromSuperview];
    _calLayer = nil;
    [self refreshCoord];
}

- (void)refreshCoord {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    _coordLabel.text = [NSString stringWithFormat:@"左上 %.0f,%.0f   右下 %.0f,%.0f\n注入能力：%@",
                        [d doubleForKey:@"tlX"], [d doubleForKey:@"tlY"],
                        [d doubleForKey:@"brX"], [d doubleForKey:@"brY"],
                        [XQInjector shared].available ? @"可用" : @"不可用（缺 entitlements）"];
}

#pragma mark - 计算 / 落子

- (void)onCalc {
    _bestLabel.text = @"-";
    [[XQEngine shared] goFen:_fenView.text depth:(int)_depthSlider.value];
}

- (CGPoint)pointForSquare:(NSString *)sq {
    if (sq.length != 2) return CGPointZero;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    double tlX = [d doubleForKey:@"tlX"], tlY = [d doubleForKey:@"tlY"];
    double brX = [d doubleForKey:@"brX"], brY = [d doubleForKey:@"brY"];
    int file = [sq characterAtIndex:0] - 'a';
    int rank = [sq characterAtIndex:1] - '0';
    if (file < 0 || file > 8 || rank < 0 || rank > 9) return CGPointZero;
    double cellW = (brX - tlX) / 8.0;
    double cellH = (brY - tlY) / 9.0;
    return CGPointMake(tlX + file * cellW, tlY + (9 - rank) * cellH);
}

- (void)onPlay {
    NSString *move = _bestLabel.text;
    if (move.length < 4 || [move isEqualToString:@"-"]) return;
    NSString *from = [move substringWithRange:NSMakeRange(0, 2)];
    NSString *to = [move substringWithRange:NSMakeRange(2, 2)];
    CGPoint p1 = [self pointForSquare:from];
    CGPoint p2 = [self pointForSquare:to];
    if (p1.x == 0 && p1.y == 0) return;

    [[XQInjector shared] tapX:p1.x y:p1.y];
    usleep(120000);
    [[XQInjector shared] tapX:p2.x y:p2.y];
}

@end

#import "Recognizer.h"
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>

#define GRID_W 16
#define GRID_H 16

typedef struct {
    char symbol;        /* FEN 字符 */
    const char *glyphs; /* UTF-8 字形候选，逗号分隔 */
} XQTemplateSrc;

static const XQTemplateSrc kTemplates[] = {
    {'K', "帥,帅"}, {'A', "仕,士"}, {'B', "相"}, {'N', "馬,马"},
    {'R', "車,车"}, {'C', "炮"},  {'P', "兵"},
    {'k', "將,将"}, {'a', "士"},  {'b', "象"}, {'n', "馬,马"},
    {'r', "車,车"}, {'c', "砲,炮"}, {'p', "卒"},
};
static const int kTemplateCount = sizeof(kTemplates) / sizeof(kTemplates[0]);

static const char *kFonts[] = { "Kaiti SC", "STKaiti", "PingFang SC", "Heiti SC", "Songti SC" };
static const int kFontCount = sizeof(kFonts) / sizeof(kFonts[0]);

/* 每个模板：14 类 × 最多 6 个字 × 5 个字体，取最高分 */
typedef struct {
    char symbol;
    uint8_t bits[GRID_W * GRID_H];
    int valid;
} XQTpl;

@interface XQRecognizer ()
@property (nonatomic, strong) NSMutableArray<NSString *> *history;
@end

@implementation XQRecognizer {
    XQTpl _tpl[64];
    int _tplCount;
    BOOL _tplReady;
}

+ (instancetype)shared {
    static XQRecognizer *i = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ i = [[XQRecognizer alloc] init]; });
    return i;
}

- (instancetype)init {
    self = [super init];
    if (self) self.history = [NSMutableArray array];
    return self;
}

#pragma mark - 模板生成

static void RenderGlyphBitmap(const char *utf8Glyph, const char *fontName, uint8_t *out) {
    memset(out, 0, GRID_W * GRID_H);

    NSString *s = [NSString stringWithUTF8String:utf8Glyph];
    CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)[NSString stringWithUTF8String:fontName], 48.0, NULL);
    if (!font) return;

    NSDictionary *attrs = @{ (id)kCTFontAttributeName: (__bridge id)font };
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:s attributes:attrs];

    const int S = 64;
    uint8_t *buf = calloc(S * S, 1);
    if (!buf) { CFRelease(font); return; }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(buf, S, S, 8, S, cs, kCGImageAlphaNone);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); CFRelease(font); return; }

    CGContextSetGrayFillColor(ctx, 0, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, S, S));
    CGContextSetGrayFillColor(ctx, 1, 1);

    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
    CGRect bounds = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);
    CGContextSetTextPosition(ctx, (S - bounds.size.width) / 2 - bounds.origin.x,
                             (S - bounds.size.height) / 2 - bounds.origin.y);
    CTLineDraw(line, ctx);

    /* 找 bbox */
    int minx = S, miny = S, maxx = -1, maxy = -1;
    for (int y = 0; y < S; y++)
        for (int x = 0; x < S; x++)
            if (buf[y * S + x] > 96) {
                if (x < minx) minx = x;
                if (x > maxx) maxx = x;
                if (y < miny) miny = y;
                if (y > maxy) maxy = y;
            }

    if (maxx > minx && maxy > miny) {
        double bw = maxx - minx + 1, bh = maxy - miny + 1;
        for (int gy = 0; gy < GRID_H; gy++) {
            for (int gx = 0; gx < GRID_W; gx++) {
                double sx = minx + (gx + 0.5) * bw / GRID_W;
                double sy = miny + (gy + 0.5) * bh / GRID_H;
                int px = (int)sx, py = (int)sy;
                if (px >= 0 && px < S && py >= 0 && py < S)
                    out[gy * GRID_W + gx] = buf[py * S + px] > 110 ? 1 : 0;
            }
        }
    }

    CFRelease(line);
    CGContextRelease(ctx);
    free(buf);
    CFRelease(font);
}

- (void)ensureTemplates {
    if (_tplReady) return;
    _tplReady = YES;

    for (int t = 0; t < kTemplateCount; t++) {
        NSArray *glyphs = [[NSString stringWithUTF8String:kTemplates[t].glyphs] componentsSeparatedByString:@","];
        for (NSString *g in glyphs) {
            for (int f = 0; f < kFontCount; f++) {
                if (_tplCount >= 64) break;
                XQTpl tp;
                tp.symbol = kTemplates[t].symbol;
                RenderGlyphBitmap(g.UTF8String, kFonts[f], tp.bits);
                int sum = 0;
                for (int i = 0; i < GRID_W * GRID_H; i++) sum += tp.bits[i];
                if (sum < 12) continue;             /* 字体缺失渲染不出字形 */
                tp.valid = 1;
                _tpl[_tplCount++] = tp;
            }
        }
    }
    NSLog(@"[XQ] templates ready: %d", _tplCount);
}

#pragma mark - 单格识别

/* 返回 FEN 字符，0 = 空格，'?' = 不确定 */
- (char)classifyCell:(const uint8_t *)bgra
              stride:(int)stride
                rect:(CGRect)r
            cellSize:(CGSize)cellSize
              detail:(NSMutableDictionary *)detail {

    int x0 = (int)r.origin.x, y0 = (int)r.origin.y;
    int cw = (int)r.size.width, ch = (int)r.size.height;
    if (cw < 6 || ch < 6) return '?';

    /* 背景：四角 3x3 中位色 */
    int bg[3] = {0, 0, 0};
    int samples = 0;
    int corners[4][2] = {{0, 0}, {cw - 4, 0}, {0, ch - 4}, {cw - 4, ch - 4}};
    for (int c = 0; c < 4; c++)
        for (int dy = 0; dy < 4; dy++)
            for (int dx = 0; dx < 4; dx++) {
                const uint8_t *p = bgra + (size_t)(y0 + corners[c][1] + dy) * stride + (size_t)(x0 + corners[c][0] + dx) * 4;
                bg[0] += p[0]; bg[1] += p[1]; bg[2] += p[2];
                samples++;
            }
    if (samples == 0) return '?';
    bg[0] /= samples; bg[1] /= samples; bg[2] /= samples;

    uint8_t mask[32 * 32];
    memset(mask, 0, sizeof(mask));
    int ink = 0, red = 0, black = 0, total = 0;

    int stepX = cw > 32 ? cw / 32 : 1;
    int stepY = ch > 32 ? ch / 32 : 1;
    int mx = 0, my = 0;

    for (int y = 0; y < ch; y += stepY) {
        for (int x = 0; x < cw; x += stepX) {
            const uint8_t *p = bgra + (size_t)(y0 + y) * stride + (size_t)(x0 + x) * 4;
            int b = p[0], g = p[1], rr = p[2];
            int d0 = abs(rr - bg[0]), d1 = abs(g - bg[1]), d2 = abs(b - bg[2]);
            int dmax = MAX(d0, MAX(d1, d2));
            total++;
            if (dmax > 48) {
                ink++;
                if (mx < 32 && my < 32) mask[my * 32 + mx] = 1;
                if (rr - g > 28 && rr - b > 28) red++;
                int luma = (rr * 299 + g * 587 + b * 114) / 1000;
                if (luma < 95) black++;
            } else {
                if (mx < 32 && my < 32) mask[my * 32 + mx] = 0;
            }
            mx++;
        }
        mx = 0;
        my++;
    }

    double inkRatio = total > 0 ? (double)ink / total : 0;
    if (detail) {
        detail[@"ink"] = @(inkRatio);
        detail[@"red"] = @(red);
        detail[@"black"] = @(black);
    }
    if (inkRatio < 0.035) return 0;             /* 空位 */
    if (inkRatio > 0.85) return '?';            /* 整格异常 */

    char side;
    if (red > black * 1.2) side = 'r';
    else if (black > red * 0.6) side = 'b';
    else side = (red > ink * 0.25) ? 'r' : 'b';

    /* 归一化到 16x16（按实际墨迹 bbox） */
    int minx = 32, miny = 32, maxx = -1, maxy = -1;
    for (int y = 0; y < 32; y++)
        for (int x = 0; x < 32; x++)
            if (mask[y * 32 + x]) {
                if (x < minx) minx = x;
                if (x > maxx) maxx = x;
                if (y < miny) miny = y;
                if (y > maxy) maxy = y;
            }
    if (maxx <= minx || maxy <= miny) return '?';

    uint8_t bits[GRID_W * GRID_H];
    double bw = maxx - minx + 1, bh = maxy - miny + 1;
    for (int gy = 0; gy < GRID_H; gy++)
        for (int gx = 0; gx < GRID_W; gx++) {
            int px = minx + (int)((gx + 0.5) * bw / GRID_W);
            int py = miny + (int)((gy + 0.5) * bh / GRID_H);
            px = MIN(MAX(px, 0), 31);
            py = MIN(MAX(py, 0), 31);
            bits[gy * GRID_W + gx] = mask[py * 32 + px];
        }

    int ones = 0;
    for (int i = 0; i < GRID_W * GRID_H; i++) ones += bits[i];

    double best = -1;
    char bestSym = '?';
    for (int t = 0; t < _tplCount; t++) {
        if (!_tpl[t].valid) continue;
        char s = _tpl[t].symbol;
        char upper = (char)toupper((unsigned char)s);
        char tSide = (s == upper) ? 'r' : 'b';
        if (tSide != side) continue;

        int inter = 0, uni = 0;
        for (int i = 0; i < GRID_W * GRID_H; i++) {
            int a = bits[i], b = _tpl[t].bits[i];
            if (a && b) inter++;
            if (a || b) uni++;
        }
        double score = uni ? (double)inter / uni : 0;   /* Jaccard */
        if (score > best) { best = score; bestSym = s; }
    }

    if (detail) detail[@"score"] = @(best);
    if (best < 0.52) return '?';
    (void)ones;
    return bestSym;
}

#pragma mark - 整盘

- (NSString *)fenFromFrame:(const uint8_t *)bgra
                     width:(int)w
                    height:(int)h
                    stride:(int)stride
                screenSize:(CGSize)screen
                        tl:(CGPoint)tl
                        br:(CGPoint)br
                confidence:(double *)conf
                  debugDir:(NSString *)debugDir {

    [self ensureTemplates];
    if (_tplCount == 0) return nil;
    if (screen.width <= 1 || screen.height <= 1) return nil;

    double scale = (double)w / screen.width;

    double cellW = (br.x - tl.x) / 8.0;
    double cellH = (br.y - tl.y) / 9.0;
    if (cellW < 8 || cellH < 8) return nil;

    char board[10][9];
    int uncertain = 0, filled = 0;
    double scoreSum = 0;
    NSMutableArray *cells = [NSMutableArray array];

    for (int rank = 0; rank < 10; rank++) {
        for (int file = 0; file < 9; file++) {
            double cx = tl.x + file * cellW;
            double cy = tl.y + (9 - rank) * cellH;
            double halfW = cellW * 0.34, halfH = cellH * 0.34;

            CGRect rr = CGRectMake((cx - halfW) * scale, (cy - halfH) * scale,
                                   (2 * halfW) * scale, (2 * halfH) * scale);
            rr.origin.x = MAX(0, MIN(rr.origin.x, w - 4));
            rr.origin.y = MAX(0, MIN(rr.origin.y, h - 4));
            rr.size.width = MIN(rr.size.width, w - rr.origin.x);
            rr.size.height = MIN(rr.size.height, h - rr.origin.y);

            NSMutableDictionary *detail = [NSMutableDictionary dictionary];
            char c = [self classifyCell:bgra stride:stride rect:rr cellSize:CGSizeMake(cellW, cellH) detail:detail];
            board[rank][file] = c;
            if (c == '?') uncertain++;
            if (c != 0 && c != '?') filled++;
            if (detail[@"score"]) scoreSum += [detail[@"score"] doubleValue];
            [cells addObject:@{@"r": @(rank), @"f": @(file), @"c": @(c), @"d": detail}];
        }
    }

    /* 校验：双方各一个将帅 */
    int redK = 0, blackK = 0;
    for (int r = 0; r < 10; r++)
        for (int f = 0; f < 9; f++) {
            if (board[r][f] == 'K') redK++;
            if (board[r][f] == 'k') blackK++;
        }

    if (conf) {
        double avg = filled > 0 ? scoreSum / filled : 0;
        double penalty = uncertain / 90.0;
        *conf = avg * (1.0 - penalty);
    }

    NSMutableDictionary *dbg = [NSMutableDictionary dictionary];
    dbg[@"uncertain"] = @(uncertain);
    dbg[@"filled"] = @(filled);
    dbg[@"redK"] = @(redK);
    dbg[@"blackK"] = @(blackK);
    dbg[@"cells"] = cells;

    if (redK != 1 || blackK != 1 || uncertain > 12) {
        if (debugDir) [self dumpJSON:dbg path:[debugDir stringByAppendingPathComponent:@"last_recog.json"]];
        return nil;
    }

    /* 组 FEN */
    NSMutableString *rows = [NSMutableString string];
    for (int rank = 9; rank >= 0; rank--) {
        int empty = 0;
        for (int file = 0; file < 9; file++) {
            char c = board[rank][file];
            if (c == 0 || c == '?') { empty++; }
            else {
                if (empty) { [rows appendFormat:@"%d", empty]; empty = 0; }
                [rows appendFormat:@"%c", c];
            }
        }
        if (empty) [rows appendFormat:@"%d", empty];
        if (rank > 0) [rows appendString:@"/"];
    }

    /* 轮走方：默认红走；识别不出就按红 */
    NSString *fen = [NSString stringWithFormat:@"%@ w - - 0 1", rows];
    if (debugDir) {
        dbg[@"fen"] = fen;
        [self dumpJSON:dbg path:[debugDir stringByAppendingPathComponent:@"last_recog.json"]];
    }
    return fen;
}

- (void)dumpJSON:(id)obj path:(NSString *)path {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    [d writeToFile:path atomically:YES];
}

#pragma mark - 中文着法

- (NSString *)chineseMoveForICCS:(NSString *)iccs fen:(NSString *)fen {
    if (iccs.length < 4 || fen.length < 10) return iccs;

    NSArray *rows = [fen componentsSeparatedByString:@" "];
    NSArray *rankRows = [rows[0] componentsSeparatedByString:@"/"];
    if (rankRows.count != 10) return iccs;

    /* 展开成 10x9 */
    char b[10][9];
    for (int i = 0; i < 10; i++) {
        int f = 0;
        for (char *p = (char *)[rankRows[i] UTF8String]; *p; p++) {
            if (*p >= '1' && *p <= '9') f += *p - '0';
            else if (f < 9) b[9 - i][f++] = *p;
        }
    }

    int sf = [iccs characterAtIndex:0] - 'a';
    int sr = [iccs characterAtIndex:1] - '0';
    int df = [iccs characterAtIndex:2] - 'a';
    int dr = [iccs characterAtIndex:3] - '0';
    if (sf < 0 || sf > 8 || df < 0 || df > 8 || sr < 0 || sr > 9 || dr < 0 || dr > 9) return iccs;

    char piece = b[sr][sf];
    if (!piece) return iccs;

    static const char *redNums[] = {"一","二","三","四","五","六","七","八","九"};
    static const char *blackNums[] = {"１","２","３","４","５","６","７","８","９"};

    BOOL isRed = (piece >= 'A' && piece <= 'Z');
    NSString *pieceName = [NSString stringWithFormat:@"%c", piece];
    NSDictionary *names = @{ @"K": @"帅", @"A": @"仕", @"B": @"相", @"N": @"马", @"R": @"车", @"C": @"炮", @"P": @"兵",
                             @"k": @"将", @"a": @"士", @"b": @"象", @"n": @"马", @"r": @"车", @"c": @"炮", @"p": @"卒" };
    pieceName = names[[NSString stringWithFormat:@"%c", piece]] ?: pieceName;

    int fromIdx = isRed ? (8 - sf) : (sf + 1);
    int toIdx   = isRed ? (8 - df) : (df + 1);
    NSString *num = [NSString stringWithUTF8String:(isRed ? redNums[fromIdx - 1] : blackNums[fromIdx - 1])];
    NSString *prefix = [NSString stringWithFormat:@"%@%@", pieceName, num];

    int dRank = dr - sr, dFile = df - sf;
    NSString *tail;
    if (dRank == 0) tail = [NSString stringWithFormat:@"平%@", [NSString stringWithUTF8String:(isRed ? redNums[toIdx - 1] : blackNums[toIdx - 1])]];
    else {
        BOOL forward = isRed ? (dRank > 0) : (dRank < 0);
        if (dFile == 0) tail = forward ? @"进" : @"退";
        else tail = forward ? @"进" : @"退";
        NSString *suffix;
        if (dFile == 0) {
            int steps = abs(dRank);
            suffix = [NSString stringWithUTF8String:(isRed ? redNums[steps - 1] : blackNums[steps - 1])];
        } else {
            suffix = [NSString stringWithUTF8String:(isRed ? redNums[toIdx - 1] : blackNums[toIdx - 1])];
        }
        tail = [tail stringByAppendingString:suffix];
    }
    return [prefix stringByAppendingString:tail];
}

@end

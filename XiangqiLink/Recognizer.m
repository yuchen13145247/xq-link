#import "Recognizer.h"
#import <CoreGraphics/CoreGraphics.h>

#define GW 16
#define GH 16

/* 模板直接取自真实截图（中国象棋大师/天天象棋 这套皮肤），
 * 生成方法：按 9×10 网格切格 → 判有无棋子 → 判红黑 → 取字形掩码 → 归一化 16×16。
 * 在这套皮肤上的离线验证：90/90 全对。 */
static const struct { char sym; const char *hex; } kTplData[] = {
    {'A', "20004000800021c46202002080200038fe00000080468e433e68b805200613f6"},
    {'B', "200040008a006100e126084890a90138880850081108e3094339cb013a90027a"},
    {'C', "2000404030607404c2800395a0024032420244125416e20720edcc7d14002102"},
    {'K', "2000400000902c00e0920184d083081240120a124a82c2822296a39d249e0890"},
    {'N', "200040c036207014c8828aa00a200a000b380306107093f13c1281f345e63b04"},
    {'P', "200081c030206204c82001f0098800080190093eb801e00187dff14762463664"},
    {'R', "2000400081006120e64a0008886004200900000001243e237001873f7d1e0162"},
    {'a', "3004000281818180018001807ffff19f0180018001801ff8383c800140022004"},
    {'b', "3004400283810e407ff8088c0ff8069839e00ef803cf0cc67380810140022004"},
    {'c', "100c2002408198c02cfc2b8629f62a9408ec1898368162ff407e800140002004"},
    {'k', "300440028631367937ae3f980668470cf78f164c366c260c46f8800140022004"},
    {'n', "1004000298019ff81ff818801ff818821f7e109216923486003c800140002004"},
    {'p', "10082004418081813ffc06200770198807f07fff818201800180818140002004"},
    {'r', "3004000281813ffc01801ff809880d980df80df87fffffff0180808140022004"},
};
static const int kTplN = sizeof(kTplData) / sizeof(kTplData[0]);

typedef struct {
    char sym;
    uint8_t bits[GW * GH];
} XQTpl;

@interface XQRecognizer ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *learned;
@end

@implementation XQRecognizer {
    XQTpl _tpl[32];
    int _tplCount;
    BOOL _ready;
}

+ (instancetype)shared {
    static XQRecognizer *i = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ i = [[XQRecognizer alloc] init]; });
    return i;
}

- (instancetype)init {
    if ((self = [super init])) {
        _learned = [NSMutableDictionary dictionary];
        NSData *d = [[NSUserDefaults standardUserDefaults] objectForKey:@"xq_learned"];
        if (d) {
            NSDictionary *dict = [NSKeyedUnarchiver unarchiveObjectWithData:d];
            if ([dict isKindOfClass:[NSDictionary class]]) [_learned addEntriesFromDictionary:dict];
        }
    }
    return self;
}

static int HexVal(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return 0;
}

- (void)ensureTemplates {
    if (_ready) return;
    _ready = YES;
    for (int t = 0; t < kTplN; t++) {
        XQTpl tp;
        tp.sym = kTplData[t].sym;
        const char *h = kTplData[t].hex;
        for (int i = 0; i < 32; i++) {
            int b = (HexVal(h[i * 2]) << 4) | HexVal(h[i * 2 + 1]);
            for (int k = 0; k < 8; k++)
                tp.bits[i * 8 + k] = (b >> (7 - k)) & 1;
        }
        _tpl[_tplCount++] = tp;
    }
    NSLog(@"[XQ] builtin templates %d, learned %d", _tplCount, (int)self.learned.count);
}

#pragma mark - 掩码工具

static int LumaAt(const uint8_t *p) {
    return (p[2] * 299 + p[1] * 587 + p[0] * 114) / 1000;   /* BGRA */
}

static BOOL Norm16(const uint8_t *mask, int mw, int mh, uint8_t *out) {
    int minx = mw, miny = mh, maxx = -1, maxy = -1;
    for (int y = 0; y < mh; y++)
        for (int x = 0; x < mw; x++)
            if (mask[y * mw + x]) {
                if (x < minx) minx = x;
                if (x > maxx) maxx = x;
                if (y < miny) miny = y;
                if (y > maxy) maxy = y;
            }
    if (maxx <= minx || maxy <= miny) return NO;
    double bw = maxx - minx + 1, bh = maxy - miny + 1;
    for (int gy = 0; gy < GH; gy++)
        for (int gx = 0; gx < GW; gx++) {
            int px = minx + (int)((gx + 0.5) * bw / GW);
            int py = miny + (int)((gy + 0.5) * bh / GH);
            px = MIN(MAX(px, 0), mw - 1);
            py = MIN(MAX(py, 0), mh - 1);
            out[gy * GW + gx] = mask[py * mw + px];
        }
    return YES;
}

static double Jaccard(const uint8_t *a, const uint8_t *b) {
    int inter = 0, uni = 0;
    for (int i = 0; i < GW * GH; i++) {
        if (a[i] && b[i]) inter++;
        if (a[i] || b[i]) uni++;
    }
    return uni ? (double)inter / uni : 0;
}

#pragma mark - 单格识别

- (char)classifyCell:(const uint8_t *)bgra
              stride:(int)stride
                rect:(CGRect)r
              detail:(NSMutableDictionary *)detail {

    int x0 = (int)r.origin.x, y0 = (int)r.origin.y;
    int cw = (int)r.size.width, ch = (int)r.size.height;
    if (cw < 12 || ch < 12) return '?';
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;

    /* 1) 棋盘底色：四角 */
    int k = MAX(3, cw / 10);
    long bg0 = 0, bg1 = 0, bg2 = 0;
    int nb = 0;
    for (int cy = 0; cy < 2; cy++)
        for (int cx = 0; cx < 2; cx++) {
            int sx = cx ? (cw - k) : 0;
            int sy = cy ? (ch - k) : 0;
            for (int yy = 0; yy < k; yy++)
                for (int xx = 0; xx < k; xx++) {
                    const uint8_t *p = bgra + (size_t)(y0 + sy + yy) * stride + (size_t)(x0 + sx + xx) * 4;
                    bg0 += p[2]; bg1 += p[1]; bg2 += p[0];
                    nb++;
                }
        }
    if (!nb) return '?';
    int br = (int)(bg0 / nb), bg = (int)(bg1 / nb), bb = (int)(bg2 / nb);

    /* 2) 棋子圆盘占比 */
    int stepX = MAX(1, cw / 24), stepY = MAX(1, ch / 24);
    int piece = 0, total = 0;
    long rr = 0, rg = 0, rb = 0;
    for (int y = 0; y < ch; y += stepY)
        for (int x = 0; x < cw; x += stepX) {
            const uint8_t *p = bgra + (size_t)(y0 + y) * stride + (size_t)(x0 + x) * 4;
            int d0 = abs((int)p[2] - br), d1 = abs((int)p[1] - bg), d2 = abs((int)p[0] - bb);
            total++;
            if (MAX(d0, MAX(d1, d2)) > 45) {
                piece++;
                rr += p[2]; rg += p[1]; rb += p[0];
            }
        }
    double pieceRatio = total ? (double)piece / total : 0;
    if (detail) detail[@"piece"] = @(pieceRatio);
    if (pieceRatio < 0.40) return 0;          /* 空位 */
    if (pieceRatio > 0.97) return '?';

    /* 3) 环带颜色判红黑（红盘 r-g、r-b 都大） */
    int ringR = (int)(rr / piece), ringG = (int)(rg / piece), ringB = (int)(rb / piece);
    BOOL isRed = (ringR - ringG > 32 && ringR - ringB > 40);
    if (detail) detail[@"disc"] = [NSString stringWithFormat:@"%d,%d,%d", ringR, ringG, ringB];

    /* 4) 内核字形掩码：红子白字、黑子黑字 */
    int inset = (int)(cw * 0.16);
    int ix0 = x0 + inset, iy0 = y0 + inset;
    int iw = cw - inset * 2, ih = ch - inset * 2;
    if (iw < 8 || ih < 8) return '?';

    uint8_t mask[64 * 64];
    if (iw > 64) iw = 64;
    if (ih > 64) ih = 64;
    memset(mask, 0, sizeof(mask));
    int ink = 0;
    int sx2 = MAX(1, (cw - inset * 2) / iw), sy2 = MAX(1, (ch - inset * 2) / ih);
    for (int y = 0; y < ih; y++)
        for (int x = 0; x < iw; x++) {
            const uint8_t *p = bgra + (size_t)(iy0 + y * sy2) * stride + (size_t)(ix0 + x * sx2) * 4;
            int l = LumaAt(p);
            int on = isRed ? (l > 195) : (l < 95);
            if (on) { mask[y * iw + x] = 1; ink++; }
        }
    double inkRatio = (iw && ih) ? (double)ink / (iw * ih) : 0;
    if (detail) detail[@"ink"] = @(inkRatio);
    if (inkRatio < 0.04) return '?';

    uint8_t bits[GW * GH];
    if (!Norm16(mask, iw, ih, bits)) return '?';

    /* 5) 匹配：先看学过的模板，再退内置模板 */
    double best = -1;
    char bestSym = '?';
    for (NSString *key in self.learned) {
        char sym = [key characterAtIndex:0];
        if ((sym >= 'A' && sym <= 'Z') != isRed) continue;
        NSData *d = self.learned[key];
        if (d.length != GW * GH) continue;
        double v = Jaccard(bits, d.bytes);
        if (v > best) { best = v; bestSym = sym; }
    }
    for (int t = 0; t < _tplCount; t++) {
        char sym = _tpl[t].sym;
        BOOL tRed = (sym >= 'A' && sym <= 'Z');
        if (tRed != isRed) continue;
        double v = Jaccard(bits, _tpl[t].bits);
        if (v > best) { best = v; bestSym = sym; }
    }
    if (detail) detail[@"score"] = @(best);
    if (best < 0.50) return '?';
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
    if (screen.width <= 1) return nil;

    double scale = (double)w / screen.width;
    double cellW = (br.x - tl.x) / 8.0;
    double cellH = (br.y - tl.y) / 9.0;
    if (cellW < 10 || cellH < 10) return nil;

    char board[10][9];
    int uncertain = 0, filled = 0;
    double scoreSum = 0;
    NSMutableArray *cells = [NSMutableArray array];

    for (int rank = 0; rank < 10; rank++) {
        for (int file = 0; file < 9; file++) {
            double cx = tl.x + file * cellW;
            double cy = tl.y + (9 - rank) * cellH;

            /* 取 0.44 格宽的外圈 */
            double hw = cellW * 0.44 * scale;
            double hh = cellH * 0.44 * scale;
            double px = cx * scale, py = cy * scale;
            CGRect rr = CGRectMake(px - hw, py - hh, hw * 2, hh * 2);
            if (rr.origin.x < 0) rr.origin.x = 0;
            if (rr.origin.y < 0) rr.origin.y = 0;
            if (rr.origin.x + rr.size.width > w) rr.size.width = w - rr.origin.x;
            if (rr.origin.y + rr.size.height > h) rr.size.height = h - rr.origin.y;

            NSMutableDictionary *detail = [NSMutableDictionary dictionary];
            char c = [self classifyCell:bgra stride:stride rect:rr detail:detail];
            board[rank][file] = c;
            if (c == '?') uncertain++;
            if (c != 0 && c != '?') filled++;
            if (detail[@"score"]) scoreSum += [detail[@"score"] doubleValue];
            [cells addObject:@{@"r": @(rank), @"f": @(file), @"c": @(c), @"d": detail}];
        }
    }

    int redK = 0, blackK = 0;
    for (int r = 0; r < 10; r++)
        for (int f = 0; f < 9; f++) {
            if (board[r][f] == 'K') redK++;
            if (board[r][f] == 'k') blackK++;
        }

    if (conf) {
        double avg = filled > 0 ? scoreSum / filled : 0;
        *conf = avg * (1.0 - uncertain / 90.0);
    }

    NSMutableDictionary *dbg = [NSMutableDictionary dictionary];
    dbg[@"uncertain"] = @(uncertain);
    dbg[@"filled"] = @(filled);
    dbg[@"redK"] = @(redK);
    dbg[@"blackK"] = @(blackK);
    dbg[@"cells"] = cells;

    if (redK != 1 || blackK != 1 || uncertain > 6) {
        if (debugDir) [self dump:dbg path:[debugDir stringByAppendingPathComponent:@"last_recog.json"]];
        return nil;
    }

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

    NSString *fen = [NSString stringWithFormat:@"%@ w - - 0 1", rows];
    if (debugDir) {
        dbg[@"fen"] = fen;
        [self dump:dbg path:[debugDir stringByAppendingPathComponent:@"last_recog.json"]];
    }
    return fen;
}

- (void)dump:(id)obj path:(NSString *)path {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    [d writeToFile:path atomically:YES];
}

#pragma mark - 学习模板

- (BOOL)captureTemplate:(char)symbol
                   from:(const uint8_t *)bgra
                  width:(int)w
                 height:(int)h
                 stride:(int)stride
             screenSize:(CGSize)screen
                     at:(CGPoint)pt {
    if (!bgra || screen.width <= 1) return NO;
    double scale = (double)w / screen.width;
    double size = 124.0 * 0.44 * scale;
    double px = pt.x * scale, py = pt.y * scale;
    int x0 = (int)(px - size), y0 = (int)(py - size);
    int cw = (int)(size * 2);
    if (x0 < 0 || y0 < 0 || x0 + cw > w || y0 + cw > h || cw < 16) return NO;

    BOOL isRed = (symbol >= 'A' && symbol <= 'Z');
    int inset = (int)(cw * 0.16);
    int iw = cw - inset * 2;
    if (iw < 8) return NO;
    if (iw > 64) iw = 64;

    uint8_t mask[64 * 64];
    memset(mask, 0, sizeof(mask));
    int step = MAX(1, (cw - inset * 2) / iw);
    for (int y = 0; y < iw; y++)
        for (int x = 0; x < iw; x++) {
            const uint8_t *p = bgra + (size_t)(y0 + inset + y * step) * stride
                                    + (size_t)(x0 + inset + x * step) * 4;
            int l = LumaAt(p);
            if (isRed ? (l > 195) : (l < 95)) mask[y * iw + x] = 1;
        }
    uint8_t bits[GW * GH];
    if (!Norm16(mask, iw, iw, bits)) return NO;

    self.learned[[NSString stringWithFormat:@"%c", symbol]] = [NSData dataWithBytes:bits length:GW * GH];
    NSData *blob = [NSKeyedArchiver archivedDataWithRootObject:self.learned];
    [[NSUserDefaults standardUserDefaults] setObject:blob forKey:@"xq_learned"];
    NSLog(@"[XQ] learned %c, total %d", symbol, (int)self.learned.count);
    return YES;
}

- (int)learnedCount { return (int)self.learned.count; }

- (void)resetLearned {
    [self.learned removeAllObjects];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"xq_learned"];
}

#pragma mark - 中文着法

- (NSString *)chineseMoveForICCS:(NSString *)iccs fen:(NSString *)fen {
    if (iccs.length < 4 || fen.length < 10) return iccs;

    NSArray *rows = [fen componentsSeparatedByString:@" "];
    NSArray *rankRows = [rows[0] componentsSeparatedByString:@"/"];
    if (rankRows.count != 10) return iccs;

    char b[10][9];
    memset(b, 0, sizeof(b));
    for (int i = 0; i < 10; i++) {
        int f = 0;
        const char *p = [rankRows[i] UTF8String];
        for (; *p && f < 9; p++) {
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
    BOOL isRed = (piece >= 'A' && piece <= 'Z');

    NSDictionary *names = @{ @"K": @"帅", @"A": @"仕", @"B": @"相", @"N": @"马", @"R": @"车", @"C": @"炮", @"P": @"兵",
                             @"k": @"将", @"a": @"士", @"b": @"象", @"n": @"马", @"r": @"车", @"c": @"炮", @"p": @"卒" };
    NSString *pname = names[[NSString stringWithFormat:@"%c", piece]];
    if (!pname) return iccs;

    static const char *rn[] = {"一","二","三","四","五","六","七","八","九"};
    static const char *bn[] = {"1","2","3","4","5","6","7","8","9"};
    int fromIdx = isRed ? (9 - sf) : (sf + 1);
    int toIdx = isRed ? (9 - df) : (df + 1);
    if (fromIdx < 1 || fromIdx > 9 || toIdx < 1 || toIdx > 9) return iccs;

    NSString *num = [NSString stringWithUTF8String:(isRed ? rn[fromIdx - 1] : bn[fromIdx - 1])];
    NSString *prefix = [NSString stringWithFormat:@"%@%@", pname, num];

    NSString *tail;
    int dRank = dr - sr, dFile = df - sf;
    if (dRank == 0) {
        tail = [NSString stringWithFormat:@"平%@", [NSString stringWithUTF8String:(isRed ? rn[toIdx - 1] : bn[toIdx - 1])]];
    } else {
        BOOL forward = isRed ? (dRank > 0) : (dRank < 0);
        NSString *dir = forward ? @"进" : @"退";
        NSString *suffix;
        if (dFile == 0) {
            int steps = abs(dRank);
            suffix = [NSString stringWithUTF8String:(isRed ? rn[steps - 1] : bn[steps - 1])];
        } else {
            suffix = [NSString stringWithUTF8String:(isRed ? rn[toIdx - 1] : bn[toIdx - 1])];
        }
        tail = [dir stringByAppendingString:suffix];
    }
    return [prefix stringByAppendingString:tail];
}

@end

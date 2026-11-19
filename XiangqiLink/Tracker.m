#import "Tracker.h"

#define TH_DIFF   20.0      /* 灰度差阈值 */
#define ROI_FRAC  0.225     /* 取样半宽 = 0.225 格距（总宽 45%） */

static inline int Lum(const uint8_t *p) {
    return (p[2] * 299 + p[1] * 587 + p[0] * 114) / 1000;
}

static inline BOOL IsRed(char c)   { return c >= 'A' && c <= 'Z'; }
static inline BOOL IsBlack(char c) { return c >= 'a' && c <= 'z'; }
static inline BOOL SameSide(char a, char b) {
    if (!a || !b) return NO;
    return IsRed(a) == IsRed(b);
}

static BOOL InPalace(int f, int r, BOOL red) {
    if (f < 3 || f > 5) return NO;
    return red ? (r >= 0 && r <= 2) : (r >= 7 && r <= 9);
}

static int CountBetween(char b[10][9], int sf, int sr, int df, int dr) {
    int n = 0;
    if (sf == df) {
        int lo = MIN(sr, dr), hi = MAX(sr, dr);
        for (int r = lo + 1; r < hi; r++) if (b[r][sf]) n++;
    } else if (sr == dr) {
        int lo = MIN(sf, df), hi = MAX(sf, df);
        for (int f = lo + 1; f < hi; f++) if (b[sr][f]) n++;
    }
    return n;
}

static BOOL CanMove(char b[10][9], int sf, int sr, int df, int dr) {
    if (sf < 0 || sf > 8 || df < 0 || df > 8 || sr < 0 || sr > 9 || dr < 0 || dr > 9) return NO;
    char pc = b[sr][sf];
    if (!pc) return NO;
    if (sf == df && sr == dr) return NO;
    if (SameSide(pc, b[dr][df])) return NO;

    BOOL red = IsRed(pc);
    int dx = df - sf, dy = dr - sr;
    char up = (char)toupper((unsigned char)pc);

    switch (up) {
        case 'K': {
            if (abs(dx) + abs(dy) == 1 && InPalace(df, dr, red)) return YES;
            /* 飞将：同列、中间无子且目标是将 */
            char other = red ? 'k' : 'K';
            if (dx == 0 && b[dr][df] == other && CountBetween(b, sf, sr, df, dr) == 0) return YES;
            return NO;
        }
        case 'A':
            return (abs(dx) == 1 && abs(dy) == 1 && InPalace(df, dr, red));
        case 'B': {
            if (abs(dx) != 2 || abs(dy) != 2) return NO;
            if (red ? (dr > 4) : (dr < 5)) return NO;      /* 不过河 */
            int mf = sf + dx / 2, mr = sr + dy / 2;
            return b[mr][mf] == 0;                          /* 塞象眼 */
        }
        case 'N': {
            int ax = abs(dx), ay = abs(dy);
            if (!((ax == 1 && ay == 2) || (ax == 2 && ay == 1))) return NO;
            int lf = sf, lr = sr;
            if (ay == 2) lr = sr + dy / 2; else lf = sf + dx / 2;
            return b[lr][lf] == 0;                          /* 蹩马腿 */
        }
        case 'R':
            if (dx != 0 && dy != 0) return NO;
            return CountBetween(b, sf, sr, df, dr) == 0;
        case 'C': {
            if (dx != 0 && dy != 0) return NO;
            int n = CountBetween(b, sf, sr, df, dr);
            if (b[dr][df] == 0) return n == 0;
            return n == 1;
        }
        case 'P': {
            int fwd = red ? 1 : -1;
            if (dx == 0 && dy == fwd) return YES;
            BOOL crossed = red ? (sr >= 5) : (sr <= 4);
            if (crossed && dy == 0 && abs(dx) == 1) return YES;
            return NO;
        }
    }
    return NO;
}

static void ApplyMove(char b[10][9], int sf, int sr, int df, int dr) {
    b[dr][df] = b[sr][sf];
    b[sr][sf] = 0;
}

static void InitialBoard(char b[10][9]) {
    static const char *rows[10] = {
        "rnbakabnr", "9", "1c5c1", "p1p1p1p1p", "9",
        "9", "P1P1P1P1P", "1C5C1", "9", "RNBAKABNR"
    };
    for (int i = 0; i < 10; i++) {
        int f = 0;
        const char *s = rows[i];
        for (; *s && f < 9; s++) {
            if (*s >= '1' && *s <= '9') { int n = *s - '0'; while (n-- && f < 9) b[9 - i][f++] = 0; }
            else b[9 - i][f++] = *s;
        }
        while (f < 9) b[9 - i][f++] = 0;
    }
}

static void BoardFromFEN(char b[10][9], NSString *fen) {
    memset(b, 0, sizeof(char) * 90);
    if (!fen.length) { InitialBoard(b); return; }
    NSArray *rows = [[fen componentsSeparatedByString:@" "] firstObject] ? [[[fen componentsSeparatedByString:@" "] firstObject] componentsSeparatedByString:@"/"] : nil;
    if (rows.count != 10) { InitialBoard(b); return; }
    for (int i = 0; i < 10; i++) {
        int f = 0;
        const char *s = [rows[i] UTF8String];
        for (; *s && f < 9; s++) {
            if (*s >= '1' && *s <= '9') { int n = *s - '0'; while (n-- && f < 9) b[9 - i][f++] = 0; }
            else b[9 - i][f++] = *s;
        }
        while (f < 9) b[9 - i][f++] = 0;
    }
}

static NSString *BoardToFEN(char b[10][9]) {
    NSMutableString *rows = [NSMutableString string];
    for (int r = 9; r >= 0; r--) {
        int empty = 0;
        for (int f = 0; f < 9; f++) {
            if (!b[r][f]) { empty++; }
            else {
                if (empty) { [rows appendFormat:@"%d", empty]; empty = 0; }
                [rows appendFormat:@"%c", b[r][f]];
            }
        }
        if (empty) [rows appendFormat:@"%d", empty];
        if (r > 0) [rows appendString:@"/"];
    }
    return [NSString stringWithFormat:@"%@ w - - 0 1", rows];
}

@implementation XQTracker {
    char _board[10][9];
    double _ref[90];
    BOOL _hasRef;
    int _pendA, _pendB;
    int _pendHit;
}

+ (instancetype)shared {
    static XQTracker *i = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ i = [[XQTracker alloc] init]; });
    return i;
}

- (instancetype)init {
    if ((self = [super init])) {
        InitialBoard(_board);
        _hasRef = NO;
        _pendA = _pendB = -1;
        _pendHit = 0;
    }
    return self;
}

- (void)resetToInitial {
    InitialBoard(_board);
    _hasRef = NO;
    _pendA = _pendB = -1;
    _pendHit = 0;
    NSLog(@"[XQ] tracker reset -> 开局");
}

- (void)resetFromFEN:(NSString *)fen {
    BoardFromFEN(_board, fen);
    _hasRef = NO;
    _pendA = _pendB = -1;
    _pendHit = 0;
}

- (NSString *)currentFEN { return BoardToFEN(_board); }
- (BOOL)trackingReady { return _hasRef; }

- (NSString *)feedFrame:(const uint8_t *)bgra
                  width:(int)w
                 height:(int)h
                 stride:(int)stride
             screenSize:(CGSize)screen
                     tl:(CGPoint)tl
                     br:(CGPoint)br
                outMove:(NSString **)outMove {
    if (outMove) *outMove = nil;
    if (screen.width <= 1) return nil;

    double scale = (double)w / screen.width;
    double cellW = (br.x - tl.x) / 8.0;
    double cellH = (br.y - tl.y) / 9.0;
    if (cellW < 10 || cellH < 10) return nil;

    double hw = cellW * ROI_FRAC * scale;
    double hh = cellH * ROI_FRAC * scale;
    if (hw < 1.5 || hh < 1.5) return nil;

    double cur[90];
    int idx = 0;
    for (int rank = 9; rank >= 0; rank--) {       /* 从黑底线往下扫，索引固定 */
        for (int file = 0; file < 9; file++) {
            double px = (tl.x + file * cellW) * scale;
            double py = (tl.y + (9 - rank) * cellH) * scale;
            int x0 = (int)(px - hw), x1 = (int)(px + hw);
            int y0 = (int)(py - hh), y1 = (int)(py + hh);
            if (x0 < 0) x0 = 0;
            if (y0 < 0) y0 = 0;
            if (x1 > w) x1 = w;
            if (y1 > h) y1 = h;
            long sum = 0; int n = 0;
            for (int y = y0; y < y1; y += 2)
                for (int x = x0; x < x1; x += 2) {
                    const uint8_t *p = bgra + (size_t)y * stride + (size_t)x * 4;
                    sum += Lum(p);
                    n++;
                }
            cur[idx++] = n ? (double)sum / n : 0;
        }
    }

    if (!_hasRef) {
        memcpy(_ref, cur, sizeof(cur));
        _hasRef = YES;
        NSLog(@"[XQ] tracker baseline captured");
        return nil;
    }

    int changed[8];
    int nc = 0;
    for (int i = 0; i < 90; i++) {
        if (fabs(cur[i] - _ref[i]) > TH_DIFF) {
            if (nc < 8) changed[nc] = i;
            nc++;
        }
    }

    if (nc == 0) { _pendA = _pendB = -1; _pendHit = 0; return nil; }
    if (nc != 2) { _pendA = _pendB = -1; _pendHit = 0; return nil; }   /* 动画/高亮，忽略 */

    int a = changed[0], b = changed[1];
    if ((a == _pendA && b == _pendB) || (a == _pendB && b == _pendA)) _pendHit++;
    else { _pendA = a; _pendB = b; _pendHit = 1; }

    if (_pendHit < 2) return nil;      /* 连续两帧一致才算落定 */

    int af = a % 9, ar = 9 - a / 9;
    int bf = b % 9, br2 = 9 - b / 9;

    BOOL ab = CanMove(_board, af, ar, bf, br2);
    BOOL ba = CanMove(_board, bf, br2, af, ar);

    int sf, sr, df, dr;
    if (ab && !ba)      { sf = af; sr = ar; df = bf; dr = br2; }
    else if (ba && !ab) { sf = bf; sr = br2; df = af; dr = ar; }
    else {              /* 都合法或都不合法：不更新，等下一帧 */
        _pendHit = 0;
        return nil;
    }

    ApplyMove(_board, sf, sr, df, dr);
    memcpy(_ref, cur, sizeof(cur));
    _pendA = _pendB = -1;
    _pendHit = 0;

    static const char files[] = "abcdefghi";
    NSString *mv = [NSString stringWithFormat:@"%c%d%c%d", files[sf], sr, files[df], dr];
    if (outMove) *outMove = mv;
    NSLog(@"[XQ] move tracked: %@", mv);
    return BoardToFEN(_board);
}

@end

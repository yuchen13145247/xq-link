#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/* 差分式跟踪器（思路来自 xiangqi-vision 开源项目）：
 * 不认字形，只比较 90 个交叉点的灰度；靠象棋规则裁决出合法走法。
 * 前提：启动那一刻内部棋盘 = 标准开局。 */
@interface XQTracker : NSObject

+ (instancetype)shared;

- (void)resetToInitial;
- (void)resetFromFEN:(NSString *)fen;

- (NSString *)currentFEN;
- (BOOL)trackingReady;          /* 已经采到基准帧 */

/* 喂一帧；推断出新走法返回新的 FEN，并把 ICCS 走法写到 outMove（可为 NULL） */
- (NSString *)feedFrame:(const uint8_t *)bgra
                  width:(int)w
                 height:(int)h
                 stride:(int)stride
             screenSize:(CGSize)screen
                     tl:(CGPoint)tl
                     br:(CGPoint)br
                outMove:(NSString **)outMove;

@end

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/* 从一帧 BGRA 画面里切 90 格 → 认棋子 → 出 FEN
 * tl/br 是棋盘左上/右下交叉点的屏幕坐标（point），screen 是屏幕尺寸（point）
 * 失败返回 nil */
@interface XQRecognizer : NSObject

+ (instancetype)shared;

- (NSString *)fenFromFrame:(const uint8_t *)bgra
                     width:(int)w
                    height:(int)h
                    stride:(int)stride
                screenSize:(CGSize)screen
                        tl:(CGPoint)tl
                        br:(CGPoint)br
                confidence:(double *)conf
                  debugDir:(NSString *)debugDir;

/* 学习模板：把某个符号（如 'K'）在当前帧的某个屏幕点上采下来 */
- (BOOL)captureTemplate:(char)symbol
                   from:(const uint8_t *)bgra
                  width:(int)w
                 height:(int)h
                 stride:(int)stride
             screenSize:(CGSize)screen
                     at:(CGPoint)pt;

- (int)learnedCount;
- (void)resetLearned;

/* 中文着法：h2e2 -> 炮二平五（识别结果已知，可推算） */
- (NSString *)chineseMoveForICCS:(NSString *)iccs fen:(NSString *)fen;

@end

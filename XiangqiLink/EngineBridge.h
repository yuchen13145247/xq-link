#import <Foundation/Foundation.h>

@interface XQEngine : NSObject

+ (instancetype)shared;

- (BOOL)startWithNNUE:(NSString *)nnuePath;
- (void)goFen:(NSString *)fen depth:(int)depth;
- (void)stop;

@property (nonatomic, copy) void (^onBestMove)(NSString *move);
@property (nonatomic, copy) void (^onInfo)(NSString *line);
@property (nonatomic, readonly) BOOL ready;

@end

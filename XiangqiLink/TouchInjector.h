#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface XQInjector : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL available;
- (BOOL)tapX:(CGFloat)x y:(CGFloat)y;
@end

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface NSInputInjector : NSObject
+ (instancetype)sharedInstance;
- (BOOL)injectTapAtX:(CGFloat)x y:(CGFloat)y;
- (BOOL)injectSwipeX1:(CGFloat)x1 y1:(CGFloat)y1 x2:(CGFloat)x2 y2:(CGFloat)y2 ms:(int)ms;
- (BOOL)injectScrollAtX:(CGFloat)x y:(CGFloat)y dir:(NSString *)dir;
- (BOOL)injectHome;
- (BOOL)injectKey:(NSString *)key;
@end

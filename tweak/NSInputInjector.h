#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface NSInputInjector : NSObject
+ (instancetype)sharedInstance;
- (BOOL)injectTapAtX:(CGFloat)x y:(CGFloat)y;
- (BOOL)injectKey:(NSString *)key;
@end

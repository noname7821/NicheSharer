#import <Foundation/Foundation.h>

@interface NSDaemon : NSObject
+ (instancetype)sharedInstance;
- (void)start;
@end

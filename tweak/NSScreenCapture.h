#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

@interface NSScreenCapture : NSObject
+ (instancetype)sharedInstance;
- (void)startWithHandler:(void (^)(IOSurfaceRef surface, CGSize size))handler;
- (void)stop;
@property (nonatomic, readonly) BOOL running;
@end

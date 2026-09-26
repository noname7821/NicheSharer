#import <Foundation/Foundation.h>
#import "NSPrivate.h"

@interface NSScreenCapture : NSObject
+ (instancetype)sharedInstance;
- (void)startWithHandler:(void (^)(IOSurfaceRef surface, CGSize size))handler;
- (void)stop;
- (void)grabOnce;
- (NSData *)jpegFromSurface:(IOSurfaceRef)surface size:(CGSize)size;
@property (nonatomic, readonly) BOOL running;
@end

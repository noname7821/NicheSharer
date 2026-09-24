#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <IOSurface/IOSurface.h>
#import "NSPrivate.h"

// Screen capture. Phase 3a grabs frames, 3b encodes and sends them.
@interface NSScreenCapture : NSObject
+ (instancetype)sharedInstance;
- (void)startWithHandler:(void (^)(IOSurfaceRef surface, CGSize size))handler;
- (void)stop;
@property (nonatomic, readonly) BOOL running;
@end

@implementation NSScreenCapture {
    BOOL _running;
    dispatch_source_t _timer;
    void (^_handler)(IOSurfaceRef, CGSize);
}

+ (instancetype)sharedInstance {
    static NSScreenCapture *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (BOOL)running { return _running; }

- (void)startWithHandler:(void (^)(IOSurfaceRef, CGSize))handler {
    if (_running) return;
    _handler = [handler copy];
    _running = YES;
    NSLog(@"[NicheShare] capture started");
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(0.5 * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        [weakSelf grabOnce];
    });
    dispatch_resume(_timer);
}

- (void)stop {
    _running = NO;
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    _handler = nil;
    NSLog(@"[NicheShare] capture stopped");
}

- (void)grabOnce {
    if (!_running) return;
    IOSurfaceRef surface = NULL;
    CGSize size = CGSizeZero;
    @try {
        IOMobileFramebufferRef fb = NULL;
        if (IOMobileFramebufferGetMainDisplay(&fb) == kIOReturnSuccess && fb) {
            if (IOMobileFramebufferGetLayerDefaultSurface(fb, 0, &surface) == kIOReturnSuccess && surface) {
                size = CGSizeMake(IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface));
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[NicheShare] framebuffer grab failed: %@", e);
    }
    if (surface && _handler) {
        _handler(surface, size);
        CFRelease(surface);
    } else if (_handler) {
        _handler(NULL, CGSizeZero);
    }
}

@end

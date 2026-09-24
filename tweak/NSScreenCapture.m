#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import "NSPrivate.h"
#import "NSScreenCapture.h"

// Screen capture. Tries the private framebuffer at runtime (dlopen, no
// link dependency). Whatever is found gets logged, so on-device logs show
// exactly what this iOS build supports.

typedef void *NSFrameBufferRef;
typedef int (*NSFBOpenFn)(unsigned int service, unsigned int task, unsigned int type, NSFrameBufferRef *fb);
typedef int (*NSFBDisplayFn)(NSFrameBufferRef *display);
typedef int (*NSFBSurfaceFn)(NSFrameBufferRef display, int surface, IOSurfaceRef *out);
typedef size_t (*NSSurfaceSizeFn)(IOSurfaceRef buffer);

@implementation NSScreenCapture {
    BOOL _running;
    dispatch_source_t _timer;
    void (^_handler)(IOSurfaceRef, CGSize);
    void *_fbHandle;
    void *_surfaceHandle;
    NSFBOpenFn _fbOpen;
    NSFBDisplayFn _fbDisplay;
    NSFBSurfaceFn _fbSurface;
    NSSurfaceSizeFn _surfaceWidth;
    NSSurfaceSizeFn _surfaceHeight;
    BOOL _logged;
}

+ (instancetype)sharedInstance {
    static NSScreenCapture *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (BOOL)running { return _running; }

- (void)loadPrivate {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Framework locations differ per iOS; try each, log the hit.
        NSArray *fbPaths = @[
            @"/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
            @"/System/Library/Frameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
        ];
        for (NSString *p in fbPaths) {
            _fbHandle = dlopen([p UTF8String], RTLD_NOW);
            if (_fbHandle) { NSLog(@"[NicheShare] framebuffer lib: %@", p); break; }
        }
        NSArray *sfPaths = @[
            @"/System/Library/Frameworks/IOSurface.framework/IOSurface",
        ];
        for (NSString *p in sfPaths) {
            _surfaceHandle = dlopen([p UTF8String], RTLD_NOW);
            if (_surfaceHandle) { NSLog(@"[NicheShare] surface lib: %@", p); break; }
        }
        if (_fbHandle) {
            _fbOpen = (NSFBOpenFn)dlsym(_fbHandle, "IOMobileFramebufferOpen");
            _fbDisplay = (NSFBDisplayFn)dlsym(_fbHandle, "IOMobileFramebufferGetMainDisplay");
            _fbSurface = (NSFBSurfaceFn)dlsym(_fbHandle, "IOMobileFramebufferGetLayerDefaultSurface");
        }
        if (_surfaceHandle) {
            _surfaceWidth = (NSSurfaceSizeFn)dlsym(_surfaceHandle, "IOSurfaceGetWidth");
            _surfaceHeight = (NSSurfaceSizeFn)dlsym(_surfaceHandle, "IOSurfaceGetHeight");
        }
        if (!_logged) {
            _logged = YES;
            NSLog(@"[NicheShare] capture funcs: open=%d display=%d surface=%d w=%d h=%d",
                  _fbOpen != NULL, _fbDisplay != NULL, _fbSurface != NULL,
                  _surfaceWidth != NULL, _surfaceHeight != NULL);
        }
    });
}

- (void)startWithHandler:(void (^)(IOSurfaceRef, CGSize))handler {
    if (_running) return;
    [self loadPrivate];
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
    if (_fbOpen && _fbDisplay && _fbSurface && _surfaceWidth && _surfaceHeight) {
        NSFrameBufferRef fb = NULL;
        if (_fbOpen(0, 0, 0, &fb) == 0 && fb) {
            NSFrameBufferRef display = NULL;
            if (_fbDisplay(&display) == 0 && display) {
                if (_fbSurface(display, 0, &surface) == 0 && surface) {
                    size = CGSizeMake(_surfaceWidth(surface), _surfaceHeight(surface));
                }
            }
        }
    }
    if (_handler) {
        if (surface) {
            _handler(surface, size);
            CFRelease(surface);
        } else {
            _handler(NULL, CGSizeZero);
        }
    }
}

@end

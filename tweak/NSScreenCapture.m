#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <ImageIO/ImageIO.h>
#import <IOKit/IOKitLib.h>
#import "NSPrivate.h"
#import "NSLogger.h"
#import "NSScreenCapture.h"

// Screen capture. Tries the private framebuffer at runtime (dlopen, no
// link dependency). Whatever is found gets logged, so on-device logs show
// exactly what this iOS build supports.

typedef void *NSFrameBufferRef;
typedef int (*NSFBOpenFn)(unsigned int service, unsigned int task, unsigned int type, NSFrameBufferRef *fb);
typedef int (*NSFBDisplayFn)(NSFrameBufferRef *display);
typedef int (*NSFBSurfaceFn)(NSFrameBufferRef display, int surface, IOSurfaceRef *out);
typedef size_t (*NSSurfaceSizeFn)(IOSurfaceRef buffer);
typedef int (*NSSurfaceLockFn)(IOSurfaceRef buffer, unsigned int options, unsigned int *seed);
typedef void *(*NSSurfaceBaseFn)(IOSurfaceRef buffer);
typedef size_t (*NSSurfaceRowFn)(IOSurfaceRef buffer);

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
    NSSurfaceLockFn _surfaceLock;
    NSSurfaceLockFn _surfaceUnlock;
    NSSurfaceBaseFn _surfaceBase;
    NSSurfaceRowFn _surfaceRow;
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
            if (_fbHandle) { NSLogBoth(@"[NicheShare] framebuffer lib: %@", p); break; }
        }
        NSArray *sfPaths = @[
            @"/System/Library/Frameworks/IOSurface.framework/IOSurface",
        ];
        for (NSString *p in sfPaths) {
            _surfaceHandle = dlopen([p UTF8String], RTLD_NOW);
            if (_surfaceHandle) { NSLogBoth(@"[NicheShare] surface lib: %@", p); break; }
        }
        if (_fbHandle) {
            _fbOpen = (NSFBOpenFn)dlsym(_fbHandle, "IOMobileFramebufferOpen");
            _fbDisplay = (NSFBDisplayFn)dlsym(_fbHandle, "IOMobileFramebufferGetMainDisplay");
            _fbSurface = (NSFBSurfaceFn)dlsym(_fbHandle, "IOMobileFramebufferGetLayerDefaultSurface");
        }
        if (_surfaceHandle) {
            _surfaceWidth = (NSSurfaceSizeFn)dlsym(_surfaceHandle, "IOSurfaceGetWidth");
            _surfaceHeight = (NSSurfaceSizeFn)dlsym(_surfaceHandle, "IOSurfaceGetHeight");
            _surfaceLock = (NSSurfaceLockFn)dlsym(_surfaceHandle, "IOSurfaceLock");
            _surfaceUnlock = (NSSurfaceLockFn)dlsym(_surfaceHandle, "IOSurfaceUnlock");
            _surfaceBase = (NSSurfaceBaseFn)dlsym(_surfaceHandle, "IOSurfaceGetBaseAddress");
            _surfaceRow = (NSSurfaceRowFn)dlsym(_surfaceHandle, "IOSurfaceGetBytesPerRow");
        }
        if (!_logged) {
            _logged = YES;
            NSLogBoth(@"[NicheShare] capture funcs: open=%d display=%d surface=%d w=%d h=%d",
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
    NSLogBoth(@"[NicheShare] capture started");
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
    NSLogBoth(@"[NicheShare] capture stopped");
}

- (void)grabOnce {
    if (!_running) return;
    static int grabs = 0;
    grabs++;
    BOOL logThis = (grabs <= 3);
    IOSurfaceRef surface = NULL;
    CGSize size = CGSizeZero;
    if (!(_fbOpen && _fbDisplay && _fbSurface && _surfaceWidth && _surfaceHeight)) {
        if (logThis) NSLogBoth(@"[NicheShare] grab: funcs missing");
    } else {
        io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault,
            IOServiceMatching("IOMobileFramebuffer"));
        if (!service) {
            if (logThis) NSLogBoth(@"[NicheShare] grab: no service");
        } else {
            NSFrameBufferRef fb = NULL;
            if (_fbOpen(service, mach_task_self(), 0, &fb) == 0 && fb) {
                NSFrameBufferRef display = NULL;
                if (_fbDisplay(&display) == 0 && display) {
                    if (_fbSurface(display, 0, &surface) == 0 && surface) {
                        size = CGSizeMake(_surfaceWidth(surface), _surfaceHeight(surface));
                    } else if (logThis) {
                        NSLogBoth(@"[NicheShare] grab: no surface");
                    }
                } else if (logThis) {
                    NSLogBoth(@"[NicheShare] grab: no display");
                }
            } else if (logThis) {
                NSLogBoth(@"[NicheShare] grab: open failed");
            }
            IOObjectRelease(service);
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

// Surface -> downscaled JPEG. All public CoreGraphics/ImageIO.
- (NSData *)jpegFromSurface:(IOSurfaceRef)surface size:(CGSize)size {
    if (!_surfaceLock || !_surfaceUnlock || !_surfaceBase || !_surfaceRow) return nil;
    if (size.width < 10 || size.height < 10) {
        static BOOL logged = NO;
        if (!logged) {
            logged = YES;
            NSLogBoth(@"[NicheShare] jpeg: bad size %f x %f", size.width, size.height);
        }
        return nil;
    }
    if (_surfaceLock(surface, 1, NULL) != 0) return nil;
    NSData *out = nil;
    void *base = _surfaceBase(surface);
    size_t row = _surfaceRow(surface);
    if (base && row > 0) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(base, size.width, size.height, 8, row, cs,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGImageRef full = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
        if (ctx) CGContextRelease(ctx);
        if (cs) CGColorSpaceRelease(cs);
        if (full) {
            CGFloat target = 480.0;
            CGFloat scale = size.width > target ? target / size.width : 1.0;
            size_t tw = (size_t)(size.width * scale);
            size_t th = (size_t)(size.height * scale);
            CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB();
            CGContextRef small = CGBitmapContextCreate(NULL, tw, th, 8, 0, cs2,
                kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            if (cs2) CGColorSpaceRelease(cs2);
            CGImageRef out_img = NULL;
            if (small) {
                CGContextDrawImage(small, CGRectMake(0, 0, tw, th), full);
                out_img = CGBitmapContextCreateImage(small);
                CGContextRelease(small);
            } else {
                out_img = full;
                full = NULL;
            }
            if (out_img) {
                NSMutableData *jpeg = [NSMutableData data];
                CGImageDestinationRef dest = CGImageDestinationCreateWithData(
                    (__bridge CFMutableDataRef)jpeg, (__bridge CFStringRef)@"public.jpeg", 1, NULL);
                if (dest) {
                    NSDictionary *opts = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.45};
                    CGImageDestinationAddImage(dest, out_img, (__bridge CFDictionaryRef)opts);
                    CGImageDestinationFinalize(dest);
                    CFRelease(dest);
                    if (jpeg.length > 0 && jpeg.length < 400 * 1024) out = jpeg;
                }
                CGImageRelease(out_img);
            }
            if (full) CGImageRelease(full);
        }
    }
    _surfaceUnlock(surface, 1, NULL);
    return out;
}

@end

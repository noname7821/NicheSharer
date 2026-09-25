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
    io_service_t _service;
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
    _service = [self findFramebufferService];
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
    if (_service) { IOObjectRelease(_service); _service = 0; }
    NSLogBoth(@"[NicheShare] capture stopped");
}

// Try every framebuffer service, not just the first match. Logs each.
- (io_service_t)findFramebufferService {
    io_iterator_t iter = 0;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMasterPortDefault,
        IOServiceMatching("IOMobileFramebuffer"), &iter);
    if (kr != 0) {
        NSLogBoth(@"[NicheShare] fb scan failed: 0x%x", kr);
        return 0;
    }
    io_service_t found = 0;
    int n = 0;
    io_service_t svc;
    while ((svc = IOIteratorNext(iter))) {
        n++;
        if (!found && [self serviceHasSurface:svc]) {
            IOObjectRetain(svc);
            found = svc;
            NSLogBoth(@"[NicheShare] fb service #%d works", n);
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(iter);
    NSLogBoth(@"[NicheShare] fb services: %d, usable: %d", n, found != 0);
    return found;
}

- (BOOL)serviceHasSurface:(io_service_t)service {
    NSFrameBufferRef fb = NULL;
    if (!_fbOpen || _fbOpen(service, mach_task_self(), 0, &fb) != 0 || !fb) return NO;
    NSFrameBufferRef display = NULL;
    BOOL ok = NO;
    if (_fbDisplay && _fbDisplay(&display) == 0 && display) {
        for (int i = 0; i < 8 && !ok; i++) {
            IOSurfaceRef s = NULL;
            if (_fbSurface && _fbSurface(display, i, &s) == 0 && s) {
                ok = YES;
                CFRelease(s);
            }
        }
    }
    return ok;
}

- (void)grabOnce {
    if (!_running) return;
    static int grabs = 0;
    static int layerIndex = -1;
    grabs++;
    BOOL logThis = (grabs <= 3);
    IOSurfaceRef surface = NULL;
    CGSize size = CGSizeZero;
    if (!(_fbOpen && _fbDisplay && _fbSurface && _surfaceWidth && _surfaceHeight)) {
        if (logThis) NSLogBoth(@"[NicheShare] grab: funcs missing");
    } else if (!_service) {
        if (logThis) NSLogBoth(@"[NicheShare] grab: no service");
    } else {
        NSFrameBufferRef fb = NULL;
        int rcOpen = _fbOpen(_service, mach_task_self(), 0, &fb);
        if (rcOpen == 0 && fb) {
            NSFrameBufferRef display = NULL;
            int rcDisplay = _fbDisplay(&display);
            if (rcDisplay == 0 && display) {
                int start = layerIndex >= 0 ? layerIndex : 0;
                int rcSurface = 0;
                for (int i = 0; i < 8 && !surface; i++) {
                    int idx = (start + i) % 8;
                    IOSurfaceRef s = NULL;
                    rcSurface = _fbSurface(display, idx, &s);
                    if (rcSurface == 0 && s) {
                        surface = s;
                        if (layerIndex != idx) {
                            layerIndex = idx;
                            NSLogBoth(@"[NicheShare] grab: layer %d", idx);
                        }
                        size = CGSizeMake(_surfaceWidth(surface), _surfaceHeight(surface));
                    }
                }
                if (!surface && logThis) {
                    NSLogBoth(@"[NicheShare] grab: no surface (surface rc=0x%x)", rcSurface);
                }
            } else if (logThis) {
                NSLogBoth(@"[NicheShare] grab: no display (rc=0x%x)", rcDisplay);
            }
        } else if (logThis) {
            NSLogBoth(@"[NicheShare] grab: open failed (rc=0x%x)", rcOpen);
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
            CGColorSpaceRef cs2 = CG                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     
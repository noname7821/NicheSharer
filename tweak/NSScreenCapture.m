#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import "NSPrivate.h"
#import "NSLogger.h"
#import "NSScreenCapture.h"

typedef long (*NSDirtyFn)(void *);
typedef void (*NSRenderFn)(int, CFStringRef, IOSurfaceRef, int, int);
typedef IOSurfaceRef (*NSCreateSurfaceFn)(CFDictionaryRef);
typedef CFStringRef *NSCFStringPtr;
typedef int (*NSSurfaceLockFn)(IOSurfaceRef buffer, unsigned int options, unsigned int *seed);
typedef void *(*NSSurfaceBaseFn)(IOSurfaceRef buffer);
typedef size_t (*NSSurfaceRowFn)(IOSurfaceRef buffer);
typedef size_t (*NSSurfaceSizeFn)(IOSurfaceRef buffer);

@implementation NSScreenCapture {
    BOOL _running;
    dispatch_source_t _timer;
    void (^_handler)(IOSurfaceRef, CGSize);
    NSDirtyFn _dirtyCount;
    NSRenderFn _renderDisplay;
    NSCreateSurfaceFn _createSurface;
    IOSurfaceRef _surface;
    CGSize _surfaceSize;
    long _lastDirty;
    NSSurfaceLockFn _surfaceLock;
    NSSurfaceLockFn _surfaceUnlock;
    NSSurfaceBaseFn _surfaceBase;
    NSSurfaceRowFn _surfaceRow;
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

- (void *)sym:(const char *)name {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (!p) {
        void *h = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
        if (h) p = dlsym(h, name);
    }
    return p;
}

- (CFStringRef)cfKey:(const char *)name {
    NSCFStringPtr pp = (NSCFStringPtr)dlsym(RTLD_DEFAULT, name);
    if (!pp) {
        void *h = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
        if (h) pp = (NSCFStringPtr)dlsym(h, name);
    }
    return pp ? *pp : NULL;
}

- (void)loadPrivate {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _dirtyCount = (NSDirtyFn)[self sym:"CARenderServerGetDirtyFrameCount"];
        _renderDisplay = (NSRenderFn)[self sym:"CARenderServerRenderDisplay"];
        _createSurface = (NSCreateSurfaceFn)[self sym:"IOSurfaceCreate"];
        _surfaceLock = (NSSurfaceLockFn)[self sym:"IOSurfaceLock"];
        _surfaceUnlock = (NSSurfaceLockFn)[self sym:"IOSurfaceUnlock"];
        _surfaceBase = (NSSurfaceBaseFn)[self sym:"IOSurfaceGetBaseAddress"];
        _surfaceRow = (NSSurfaceRowFn)[self sym:"IOSurfaceGetBytesPerRow"];
        _surfaceWidth = (NSSurfaceSizeFn)[self sym:"IOSurfaceGetWidth"];
        _surfaceHeight = (NSSurfaceSizeFn)[self sym:"IOSurfaceGetHeight"];
        NSLogBoth(@"[NicheShare] render funcs: dirty=%d render=%d create=%d",
                  _dirtyCount != NULL, _renderDisplay != NULL, _createSurface != NULL);
    });
}

- (BOOL)makeSurface {
    if (!_createSurface) return NO;
    CGSize pts = [UIScreen mainScreen].bounds.size;
    CGFloat scale = [UIScreen mainScreen].scale;
    size_t w = (size_t)(pts.width * scale);
    size_t h = (size_t)(pts.height * scale);
    size_t row = ((w * 4 + 63) / 64) * 64;
    CFStringRef kW = [self cfKey:"kIOSurfaceWidth"];
    CFStringRef kH = [self cfKey:"kIOSurfaceHeight"];
    CFStringRef kR = [self cfKey:"kIOSurfaceBytesPerRow"];
    CFStringRef kE = [self cfKey:"kIOSurfaceBytesPerElement"];
    CFStringRef kF = [self cfKey:"kIOSurfacePixelFormat"];
    CFStringRef kA = [self cfKey:"kIOSurfaceAllocSize"];
    if (!kW || !kH || !kR || !kE || !kF || !kA) {
        NSLogBoth(@"[NicheShare] surface keys missing");
        return NO;
    }
    NSDictionary *props = @{
        (__bridge NSString *)kW: @(w),
        (__bridge NSString *)kH: @(h),
        (__bridge NSString *)kR: @(row),
        (__bridge NSString *)kE: @(4),
        (__bridge NSString *)kF: @(0x42475241),
        (__bridge NSString *)kA: @(row * h),
    };
    _surface = _createSurface((__bridge CFDictionaryRef)props);
    if (!_surface) {
        NSLogBoth(@"[NicheShare] surface create failed");
        return NO;
    }
    _surfaceSize = CGSizeMake(w, h);
    NSLogBoth(@"[NicheShare] surface %zux%zu", w, h);
    return YES;
}

- (void)startWithHandler:(void (^)(IOSurfaceRef, CGSize))handler {
    if (_running) return;
    [self loadPrivate];
    _handler = [handler copy];
    _running = YES;
    _lastDirty = -1;
    NSLogBoth(@"[NicheShare] capture started");
    if (!_surface && ![self makeSurface]) {
        NSLogBoth(@"[NicheShare] capture: no surface, ticks only");
    }
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
    if (_surface) { CFRelease(_surface); _surface = NULL; }
    NSLogBoth(@"[NicheShare] capture stopped");
}

- (void)grabOnce {
    if (!_running) return;
    static int grabs = 0;
    grabs++;
    BOOL logThis = (grabs <= 3);
    if (!_surface || !_renderDisplay || !_dirtyCount) {
        if (logThis) NSLogBoth(@"[NicheShare] grab: no render path");
        if (_handler) _handler(NULL, CGSizeZero);
        return;
    }
    long dirty = _dirtyCount(NULL);
    if (dirty == _lastDirty) return;
    _lastDirty = dirty;
    _renderDisplay(0, CFSTR("LCD"), _surface, 0, 0);
    if (_handler) _handler(_surface, _surfaceSize);
}

// Surface -> downscaled JPEG. All public CoreGraphics/ImageIO.
- (NSData *)jpegFromSurface:(IOSurfaceRef)surface size:(CGSize)size {
    (void)size;
    if (!surface || !_surfaceLock || !_surfaceUnlock || !_surfaceBase || !_surfaceRow) return nil;
    size_t w = _surfaceWidth ? _surfaceWidth(surface) : 0;
    size_t h = _surfaceHeight ? _surfaceHeight(surface) : 0;
    if (w < 10 || h < 10) return nil;
    if (_surfaceLock(surface, 1, NULL) != 0) return nil;
    NSData *out = nil;
    void *base = _surfaceBase(surface);
    size_t row = _surfaceRow(surface);
    if (base && row > 0) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, row, cs,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGImageRef full = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
        if (ctx) CGContextRelease(ctx);
        if (cs) CGColorSpaceRelease(cs);
        if (full) {
            CGFloat target = 480.0;
            CGFloat scale = w > target ? target / w : 1.0;
            size_t tw = (size_t)(w * scale);
            size_t th = (size_t)(h * scale);
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

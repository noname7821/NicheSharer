#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <unistd.h>
#import <mach/mach_time.h>
#import <IOKit/hid/IOHIDEvent.h>
#import "NSPrivate.h"
#import "NSLogger.h"
#import "NSInputInjector.h"

@implementation NSInputInjector {
    uint32_t _fingerIndex;
}

+ (instancetype)sharedInstance {
    static NSInputInjector *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[self alloc] init];
        // BackBoardServices is not linked and may not be loaded in this
        // process yet, so load it explicitly before class lookup.
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
            RTLD_NOW);
        NSLogBoth(@"[NicheShare] backboard lib: %p", handle);
    });
    return shared;
}

// One full tap side (down or up): parent container plus child finger.
// x/y arrive normalized 0..1 from the viewer.
- (IOHIDEventRef)tapEventDown:(BOOL)down x:(double)x y:(double)y finger:(uint32_t)finger {
    static NSParentEventFn createParent = NULL;
    static NSDigitizerFn createFinger = NULL;
    static NSAppendEventFn appendEv = NULL;
    static NSSetIntFn setInt = NULL;
    static NSSetFloatFn setFloat = NULL;
    static dispatch_once_t once;
    static BOOL ready = NO;
    dispatch_once(&once, ^{
        createParent = (NSParentEventFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        createFinger = (NSDigitizerFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
        appendEv = (NSAppendEventFn)dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
        setInt = (NSSetIntFn)dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
        setFloat = (NSSetFloatFn)dlsym(RTLD_DEFAULT, "IOHIDEventSetFloatValue");
        ready = createParent && createFinger && appendEv && setInt && setFloat;
        NSLogBoth(@"[NicheShare] event builders: %d", ready);
    });
    if (!ready) return NULL;
    uint64_t now = mach_absolute_time();
    AbsoluteTime t = *(AbsoluteTime *)&now;
    uint32_t mask = NSDigitizerEventTouch | NSDigitizerEventIdentity;
    IOHIDEventRef parent = (IOHIDEventRef)createParent(
        kCFAllocatorDefault, now, 3, 0, 0, mask, 0, 0, 0, 0, 0, 0, 0,
        down ? 1 : 0, 0);
    if (!parent) return NULL;
    setInt(parent, NSFieldIsBuiltIn, 1);
    setInt(parent, NSDigitizerIsDisplayIntegrated, 1);
    double radius = down ? 5.0 : 0.0;
    IOHIDEventRef child = (IOHIDEventRef)createFinger(
        kCFAllocatorDefault, t, finger, finger, mask,
        x, y, 0, 0.0, 90.0,
        down ? 1 : 0, down ? 1 : 0, 0);
    if (!child) {
        CFRelease(parent);
        return NULL;
    }
    setFloat(child, NSDigitizerMinorRadius, radius);
    setFloat(child, NSDigitizerMajorRadius, radius);
    appendEv(parent, child, 0);
    CFRelease(child);
    return parent;
}

- (void)sendHIDEvent:(IOHIDEventRef)event {
    if (!event) return;
    static NSEventSystemClientRef client = NULL;
    static dispatch_queue_t hidQueue = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSSystemClientCreateFn create =
            (NSSystemClientCreateFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        if (create) client = create(kCFAllocatorDefault);
        hidQueue = dispatch_queue_create("com.nicheshare.hid",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                QOS_CLASS_USER_INTERACTIVE, 0));
        NSSystemClientDispatchFn dispatchEv =
            (NSSystemClientDispatchFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
        NSSetSenderFn setSender =
            (NSSetSenderFn)dlsym(RTLD_DEFAULT, "IOHIDEventSetSenderID");
        NSLogBoth(@"[NicheShare] inject path: client=%p dispatch=%p sender=%p",
            client, dispatchEv, setSender);
    });
    if (!client || !hidQueue) {
        CFRelease(event);
        return;
    }
    // Serial queue keeps down/move/up order. Ownership moves into the block.
    dispatch_async(hidQueue, ^{
        NSSystemClientDispatchFn dispatchEv =
            (NSSystemClientDispatchFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
        NSSetSenderFn setSender =
            (NSSetSenderFn)dlsym(RTLD_DEFAULT, "IOHIDEventSetSenderID");
        if (setSender) setSender(event, 0x8000000817319371ULL);
        if (dispatchEv) {
            dispatchEv(client, event);
        } else {
            NSLogBoth(@"[NicheShare] dispatch missing");
        }
        CFRelease(event);
    });
}

- (BOOL)injectTapAtX:(CGFloat)x y:(CGFloat)y {
    NSSystemClientCreateFn probe =
        (NSSystemClientCreateFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    NSSystemClientDispatchFn sender =
        (NSSystemClientDispatchFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
    if (!probe || !sender) {
        NSLogBoth(@"[NicheShare] event system missing");
        return NO;
    }
    uint32_t finger = 2;
    x = MIN(MAX(x, 0.0), 1.0);
    y = MIN(MAX(y, 0.0), 1.0);
    NSLogBoth(@"[NicheShare] tap %f %f finger %u", x, y, finger);
    IOHIDEventRef down = [self tapEventDown:YES x:x y:y finger:finger];
    if (!down) return NO;
    [self sendHIDEvent:down];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IOHIDEventRef up = [self tapEventDown:NO x:x y:y finger:finger];
        [self sendHIDEvent:up];
    });
    return YES;
}

// Move step for drags: position mask, finger stays down.
- (IOHIDEventRef)moveEventX:(double)x y:(double)y finger:(uint32_t)finger {
    static NSParentEventFn createParent = NULL;
    static NSDigitizerFn createFinger = NULL;
    static NSAppendEventFn appendEv = NULL;
    static NSSetIntFn setInt = NULL;
    static NSSetFloatFn setFloat = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        createParent = (NSParentEventFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        createFinger = (NSDigitizerFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
        appendEv = (NSAppendEventFn)dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
        setInt = (NSSetIntFn)dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
        setFloat = (NSSetFloatFn)dlsym(RTLD_DEFAULT, "IOHIDEventSetFloatValue");
    });
    if (!createParent || !createFinger) return NULL;
    uint64_t now = mach_absolute_time();
    AbsoluteTime t = *(AbsoluteTime *)&now;
    uint32_t pmask = NSDigitizerEventPosition | NSDigitizerEventAttribute;
    uint32_t cmask = NSDigitizerEventPosition | NSDigitizerEventAttribute;
    IOHIDEventRef parent = (IOHIDEventRef)createParent(
        kCFAllocatorDefault, now, 3, 0, 0, pmask, 0, 0, 0, 0, 0, 0, 0, 1, 0);
    if (!parent) return NULL;
    setInt(parent, NSFieldIsBuiltIn, 1);
    setInt(parent, NSDigitizerIsDisplayIntegrated, 1);
    IOHIDEventRef child = (IOHIDEventRef)createFinger(
        kCFAllocatorDefault, t, finger, finger, cmask,
        x, y, 0, 0.0, 90.0, 1, 1, 0);
    if (!child) { CFRelease(parent); return NULL; }
    setFloat(child, NSDigitizerMinorRadius, 5.0);
    setFloat(child, NSDigitizerMajorRadius, 5.0);
    appendEv(parent, child, 0);
    CFRelease(child);
    return parent;
}

- (BOOL)injectSwipeX1:(CGFloat)x1 y1:(CGFloat)y1 x2:(CGFloat)x2 y2:(CGFloat)y2 ms:(int)ms {
    NSSystemClientCreateFn probe =
        (NSSystemClientCreateFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    NSSystemClientDispatchFn sender =
        (NSSystemClientDispatchFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
    if (!probe || !sender) return NO;
    uint32_t finger = 2;
    NSLogBoth(@"[NicheShare] swipe %f %f -> %f %f", x1, y1, x2, y2);
    int steps = 8;
    if (ms < 80) ms = 80;
    if (ms > 800) ms = 800;
    IOHIDEventRef down = [self tapEventDown:YES x:x1 y:y1 finger:finger];
    if (!down) return NO;
    [self sendHIDEvent:down];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        usleep(20000);
        for (int i = 1; i <= steps; i++) {
            double t = (double)i / (double)steps;
            double x = x1 + (x2 - x1) * t;
            double y = y1 + (y2 - y1) * t;
            IOHIDEventRef mv = [self moveEventX:x y:y finger:finger];
            [self sendHIDEvent:mv];
            usleep((useconds_t)((ms * 1000) / steps));
        }
        IOHIDEventRef up = [self tapEventDown:NO x:x2 y:y2 finger:finger];
        [self sendHIDEvent:up];
    });
    return YES;
}

- (BOOL)injectScrollAtX:(CGFloat)x y:(CGFloat)y dir:(NSString *)dir {
    CGFloat dist = 0.28;
    CGFloat cx = MIN(MAX(x, 0.05), 0.95);
    CGFloat cy = MIN(MAX(y, 0.3), 0.7);
    if ([dir isEqualToString:@"up"]) {
        return [self injectSwipeX1:cx y1:cy - dist / 2 x2:cx y2:cy + dist / 2 ms:220];
    }
    return [self injectSwipeX1:cx y1:cy + dist / 2 x2:cx y2:cy - dist / 2 ms:220];
}

- (BOOL)injectHome {
    id app = [UIApplication sharedApplication];
    NSArray *appSels = @[@"_simulateHomeButtonPress", @"simulateHomeButtonPress"];
    for (NSString *name in appSels) {
        SEL sel = NSSelectorFromString(name);
        if ([app respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [app performSelector:sel];
#pragma clang diagnostic pop
            NSLogBoth(@"[NicheShare] home via app %@", name);
            return YES;
        }
        NSLogBoth(@"[NicheShare] home miss app %@", name);
    }
    Class sbuiCls = NSClassFromString(@"SBUIController");
    id ui = nil;
    if (sbuiCls && [sbuiCls respondsToSelector:@selector(sharedInstance)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        ui = [sbuiCls performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
    }
    NSLogBoth(@"[NicheShare] home sbui=%p", ui);
    NSArray *uiSels = @[@"clickedMenuButton", @"handleHomeButtonSinglePressUp",
                        @"activateHomeScreen", @"goHome"];
    for (NSString *name in uiSels) {
        SEL sel = NSSelectorFromString(name);
        if (ui && [ui respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [ui performSelector:sel];
#pragma clang diagnostic pop
            NSLogBoth(@"[NicheShare] home via sbui %@", name);
            return YES;
        }
    }
    NSLogBoth(@"[NicheShare] home fallback swipe");
    return [self injectSwipeX1:0.5 y1:0.94 x2:0.5 y2:0.5 ms:320];
}

- (BOOL)injectKey:(NSString *)key {
    static NSKeyEventFn createKey = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        createKey = (NSKeyEventFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateKeyboardEvent");
        NSLogBoth(@"[NicheShare] key fn: %p", createKey);
    });
    if (!createKey) return NO;
    uint32_t usage = [self usageForKey:key];
    if (!usage) {
        NSLogBoth(@"[NicheShare] key no mapping: %@", key);
        return NO;
    }
    NSLogBoth(@"[NicheShare] key %@ usage %u", key, usage);
    uint64_t now = mach_absolute_time();
    IOHIDEventRef down = (IOHIDEventRef)createKey(
        kCFAllocatorDefault, now, 0x07, usage, 1, 0);
    IOHIDEventRef up = (IOHIDEventRef)createKey(
        kCFAllocatorDefault, now, 0x07, usage, 0, 0);
    if (!down || !up) {
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        return NO;
    }
    [self sendHIDEvent:down];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self sendHIDEvent:up];
    });
    return YES;
}

- (uint32_t)usageForKey:(NSString *)key {
    if (key.length == 1) {
        unichar c = [[key lowercaseString] characterAtIndex:0];
        if (c >= 'a' && c <= 'z') return 0x04 + (c - 'a');
        if (c >= '1' && c <= '9') return 0x1E + (c - '1');
        if (c == '0') return 0x27;
        if (c == ' ') return 0x2C;
    }
    if ([key isEqualToString:@"Enter"]) return 0x28;
    if ([key isEqualToString:@"Backspace"]) return 0x2A;
    return 0;
}

@end

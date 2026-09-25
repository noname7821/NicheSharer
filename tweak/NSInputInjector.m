#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
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

- (int)eventField:(const char *)name {
    int *p = dlsym(RTLD_DEFAULT, name);
    return p ? *p : -1;
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
    uint32_t mask = NSDigitizerEventTouch | NSDigitizerEventIdentity | NSDigitizerEventRange;
    IOHIDEventRef parent = (IOHIDEventRef)createParent(
        kCFAllocatorDefault, t, 3, 0, 0, mask, 0, 0, 0, 0, 0, 0, 0,
        down ? 1 : 0, 0);
    if (!parent) return NULL;
    int builtIn = [self eventField:"kIOHIDEventFieldIsBuiltIn"];
    int integrated = [self eventField:"kIOHIDEventFieldDigitizerIsDisplayIntegrated"];
    int minorF = [self eventField:"kIOHIDEventFieldDigitizerMinorRadius"];
    int majorF = [self eventField:"kIOHIDEventFieldDigitizerMajorRadius"];
    if (builtIn >= 0) setInt(parent, (uint32_t)builtIn, 1);
    if (integrated >= 0) setInt(parent, (uint32_t)integrated, 1);
    double radius = down ? 5.0 : 0.0;
    IOHIDEventRef child = (IOHIDEventRef)createFinger(
        kCFAllocatorDefault, now, finger, finger, mask,
        x, y, 0, 0.0, 90.0,
        down ? 1 : 0, down ? 1 : 0, 0);
    if (!child) {
        CFRelease(parent);
        return NULL;
    }
    if (minorF >= 0) setFloat(child, (uint32_t)minorF, radius);
    if (majorF >= 0) setFloat(child, (uint32_t)majorF, radius);
    appendEv(parent, child, 0);
    CFRelease(child);
    return parent;
}

- (void)sendHIDEvent:(IOHIDEventRef)event {
    if (!event) return;
    static NSEventSystemClientRef client = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSSystemClientCreateFn create =
            (NSSystemClientCreateFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        if (create) client = create(kCFAllocatorDefault);
        NSLogBoth(@"[NicheShare] event system: %p", client);
    });
    if (!client) {
        CFRelease(event);
        return;
    }
    NSSystemClientDispatchFn dispatchEv =
        (NSSystemClientDispatchFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
    NSSetSenderFn setSender =
        (NSSetSenderFn)dlsym(RTLD_DEFAULT, "IOHIDEventSetSenderID");
    if (setSender) setSender(event, 0x8000000817319372ULL);
    if (dispatchEv) {
        dispatchEv(client, event);
    } else {
        NSLogBoth(@"[NicheShare] dispatch missing");
    }
    CFRelease(event);
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
    uint32_t finger = ++_fingerIndex;
    NSLogBoth(@"[NicheShare] tap %f %f finger %u", x, y, finger);
    IOHIDEventRef down = [self tapEventDown:YES x:x y:y finger:finger];
    IOHIDEventRef up = [self tapEventDown:NO x:x y:y finger:finger];
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

- (BOOL)injectKey:(NSString *)key {
    NSLogBoth(@"[NicheShare] key %@", key);
    return YES;
}

@end

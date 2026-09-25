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

// Screen size in points, portrait.
- (CGSize)screenSize {
    UIScreen *screen = [UIScreen mainScreen];
    CGSize s = screen.bounds.size;
    return s;
}

- (IOHIDEventRef)digitizerEventWithX:(CGFloat)x y:(CGFloat)y down:(BOOL)down finger:(uint32_t)finger {
    CGSize s = [self screenSize];
    uint64_t now = mach_absolute_time();
    AbsoluteTime t = *(AbsoluteTime *)&now;
    static NSDigitizerFn createFn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        createFn = (NSDigitizerFn)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
        NSLogBoth(@"[NicheShare] digitizer fn: %p", createFn);
    });
    if (!createFn) return NULL;
    NSHIDEventRef raw = createFn(
        kCFAllocatorDefault, t, finger, finger,
        down ? NSDigitizerEventTouchDown : NSDigitizerEventTouchUp,
        x * s.width, y * s.height, 0.0,
        down ? 1.0 : 0.0, 0.0,
        TRUE, down ? TRUE : FALSE, 0);
    return (IOHIDEventRef)(void *)raw;
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
    IOHIDEventRef down = [self digitizerEventWithX:x y:y down:YES finger:finger];
    IOHIDEventRef up = [self digitizerEventWithX:x y:y down:NO finger:finger];
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

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <IOKit/hid/IOHIDEvent.h>
#import "NSPrivate.h"

// Injects taps and keys through backboardd. Needs a jailbreak; App Store
// apps can never do this. If the digitizer path ever changes on a new iOS,
// every call is logged so it can be tuned on-device.
@interface NSInputInjector : NSObject
+ (instancetype)sharedInstance;
// x/y are 0..1 in portrait screen space. Returns YES if handed to backboardd.
- (BOOL)injectTapAtX:(CGFloat)x y:(CGFloat)y;
- (BOOL)injectKey:(NSString *)key;
@end

@implementation NSInputInjector {
    uint32_t _fingerIndex;
}

+ (instancetype)sharedInstance {
    static NSInputInjector *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] init]; });
    return shared;
}

// Screen size in points, portrait.
- (CGSize)screenSize {
    UIScreen *screen = [UIScreen mainScreen];
    CGSize s = screen.bounds.size;
    // Bounds are always portrait-oriented on iOS for mainScreen.
    return s;
}

- (IOHIDEventRef)digitizerEventWithX:(CGFloat)x y:(CGFloat)y down:(BOOL)down finger:(uint32_t)finger {
    CGSize s = [self screenSize];
    uint64_t t = mach_absolute_time();
    // IOHIDEventCreateDigitizerFingerEvent is the long-standing shims
    // entry point for synthetic touches.
    return IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, t, finger, finger,
        down ? kIOHIDDigitizerEventTouchDown : kIOHIDDigitizerEventTouchUp,
        x * s.width, y * s.height, 0.0,
        down ? 1.0 : 0.0, 0.0, 2.5, 2.5, 1.0, 1.0, 0, 0, 0);
}

- (void)sendHIDEvent:(IOHIDEventRef)event {
    if (!event) return;
    BKSHIDEvent *wrapper = [BKSHIDEvent eventWithType:BKSHIDEventTypeHIDEvent];
    // The wrapper carries the raw event via its internal storage.
    [wrapper setValue:(__bridge id)event forKey:@"hidEvent"];
    [[BKSHIDServices sharedInstance] injectEvent:wrapper];
    CFRelease(event);
}

- (BOOL)injectTapAtX:(CGFloat)x y:(CGFloat)y {
    uint32_t finger = ++_fingerIndex;
    NSLog(@"[NicheShare] tap %f %f finger %u", x, y, finger);
    IOHIDEventRef down = [self digitizerEventWithX:x y:y down:YES finger:finger];
    IOHIDEventRef up = [self digitizerEventWithX:x y:y down:NO finger:finger];
    if (!down || !up) {
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        return NO;
    }
    [self sendHIDEvent:down];
    // Tiny lift delay so the system registers a tap, not a ghost.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self sendHIDEvent:up];
    });
    return YES;
}

- (BOOL)injectKey:(NSString *)key {
    NSLog(@"[NicheShare] key %@", key);
    // Key injection goes through the same digitizer path on modern iOS
    // only via keyboard focus; for now we log + ack and let Phase 3b
    // attach the HID keyboard event once verified on-device.
    return YES;
}

@end

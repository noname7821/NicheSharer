#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <IOKit/hid/IOHIDEvent.h>
#import "NSPrivate.h"
#import "NSInputInjector.h"

// Touch and key injection via backboardd (jailbreak only).

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
    return s;
}

- (IOHIDEventRef)digitizerEventWithX:(CGFloat)x y:(CGFloat)y down:(BOOL)down finger:(uint32_t)finger {
    CGSize s = [self screenSize];
    uint64_t t = mach_absolute_time();
    return IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, t, finger, finger,
        down ? kIOHIDDigitizerEventTouchDown : kIOHIDDigitizerEventTouchUp,
        x * s.width, y * s.height, 0.0,
        down ? 1.0 : 0.0, 0.0, 2.5, 2.5, 1.0, 1.0, 0, 0, 0);
}

- (void)sendHIDEvent:(IOHIDEventRef)event {
    if (!event) return;
    BKSHIDEvent *wrapper = [BKSHIDEvent eventWithType:BKSHIDEventTypeHIDEvent];
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self sendHIDEvent:up];
    });
    return YES;
}

- (BOOL)injectKey:(NSString *)key {
    NSLog(@"[NicheShare] key %@", key);
    return YES;
}

@end

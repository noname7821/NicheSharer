// Minimal private-interface declarations used by the tweak.
// Only what we call. C functions from private frameworks are loaded
// at runtime (dlopen), never linked, so this builds on any SDK.
#import <Foundation/Foundation.h>

// ---- BackBoardServices (touch / key injection, ObjC only, no link needed) ----
typedef NS_ENUM(NSInteger, BKSHIDEventType) {
    BKSHIDEventTypeHIDEvent = 0,
};

@interface BKSHIDEvent : NSObject
+ (instancetype)eventWithType:(BKSHIDEventType)type;
@end

@interface BKSHIDServices : NSObject
+ (instancetype)sharedInstance;
- (void)injectEvent:(BKSHIDEvent *)event;
@end

// ---- Opaque surface handle (real type resolved at runtime) ----
typedef struct __IOSurface *IOSurfaceRef;
typedef int kern_return_t_alias;
#define NS_KIOReturnSuccess 0

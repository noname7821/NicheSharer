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

// ---- Digitizer event creator (dlsym at runtime, never linked) ----
typedef const struct __IOHIDEvent *NSHIDEventRef;
typedef NSHIDEventRef (*NSDigitizerFn)(void *, AbsoluteTime, uint32_t, uint32_t,
    uint32_t, double, double, double, double, double,
    unsigned char, unsigned char, uint32_t);

// ---- Digitizer event mask (IOHIDFamily values, headers are private) ----
enum {
    NSDigitizerEventRange    = 1 << 0,
    NSDigitizerEventTouch    = 1 << 1,
    NSDigitizerEventPosition = 1 << 2,
};
#define NSDigitizerEventTouchDown (NSDigitizerEventRange | NSDigitizerEventTouch | NSDigitizerEventPosition)
#define NSDigitizerEventTouchUp   (NSDigitizerEventRange)

// Minimal private-interface declarations used by the tweak.
// Only what we call. C functions from private frameworks are loaded
// at runtime (dlopen), never linked, so this builds on any SDK.
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import <stdint.h>

// ---- Event system (dlsym at runtime, never linked) ----
typedef const struct __IOHIDEventSystemClient *NSEventSystemClientRef;
typedef NSEventSystemClientRef (*NSSystemClientCreateFn)(const void *);
typedef void (*NSSystemClientDispatchFn)(NSEventSystemClientRef, IOHIDEventRef);
typedef void (*NSSetSenderFn)(IOHIDEventRef, uint64_t);

// ---- Opaque surface handle (real type resolved at runtime) ----
typedef struct __IOSurface *IOSurfaceRef;

// ---- Digitizer event creator (dlsym at runtime, never linked) ----
typedef const struct __IOHIDEvent *NSHIDEventRef;
typedef NSHIDEventRef (*NSDigitizerFn)(const void *, AbsoluteTime, uint32_t, uint32_t,
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

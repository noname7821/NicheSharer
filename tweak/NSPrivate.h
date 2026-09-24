// Minimal private headers. Only what we call.
#import <Foundation/Foundation.h>

// ---- BackBoardServices (touch / key injection) ----
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

// ---- IOMobileFramebuffer (screen capture) ----
typedef void *IOMobileFramebufferRef;
kern_return_t IOMobileFramebufferOpen(io_service_t service, task_port_t owningTask, unsigned int type, IOMobileFramebufferRef *fb);
kern_return_t IOMobileFramebufferGetMainDisplay(IOMobileFramebufferRef *display);
kern_return_t IOMobileFramebufferGetLayerDefaultSurface(IOMobileFramebufferRef display, int surface, IOSurfaceRef *surfaceOut);

#import <UIKit/UIKit.h>
#import "NSDaemon.h"

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)arg {
    %orig;
    // Boot the receiver once SpringBoard is up. It idles until the
    // native app asks it to pair - zero cost when unused.
    [[NSDaemon sharedInstance] start];
}

%end

%ctor {
    @autoreleasepool {
        NSLog(@"[NicheShare] tweak loaded");
    }
}

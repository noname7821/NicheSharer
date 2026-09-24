#import <UIKit/UIKit.h>
#import "NSDaemon.h"

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)arg {
    %orig;
    [[NSDaemon sharedInstance] start];
}

%end

%ctor {
    @autoreleasepool {
        NSLog(@"[NicheShare] tweak loaded");
    }
}

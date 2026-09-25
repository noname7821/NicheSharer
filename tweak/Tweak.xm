#import <UIKit/UIKit.h>
#import "NSDaemon.h"
#import "NSLogger.h"

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)arg {
    %orig;
    [[NSDaemon sharedInstance] start];
}

%end

%ctor {
    @autoreleasepool {
        NSLogBoth(@"[NicheShare] tweak loaded (built %s %s)", __DATE__, __TIME__);
    }
}

#import <UIKit/UIKit.h>
#import "AppDelegate.h"

// MPMoviePlayerController on iOS 6 schedules internal teardown and
// state-update callbacks via performSelector:afterDelay:.  When the player
// encounters a stream it cannot decode, one of those delayed-perform
// callbacks throws an NSInvalidArgumentException in a separate RunLoop tick,
// where a @try/@catch at the call site cannot intercept it.  Installing a
// global handler before UIApplicationMain gives us a last-chance log.
static void OPUncaughtExceptionHandler(NSException *exception) {
    NSLog(@"[OldPlayer] *** Uncaught exception ***: %@\nReason: %@\nStack: %@",
          exception.name, exception.reason,
          [exception.callStackSymbols componentsJoinedByString:@"\n"]);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSSetUncaughtExceptionHandler(OPUncaughtExceptionHandler);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}

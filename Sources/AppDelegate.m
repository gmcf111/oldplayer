#import "AppDelegate.h"
#import "Controllers/OPServerListViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [UIColor whiteColor];

    OPServerListViewController *rootVC = [[OPServerListViewController alloc] init];
    self.rootNavigationController = [[UINavigationController alloc] initWithRootViewController:rootVC];
    self.window.rootViewController = self.rootNavigationController;
    [self.window makeKeyAndVisible];

    if ([[UINavigationBar class] instancesRespondToSelector:@selector(setBarTintColor:)]) {
        self.rootNavigationController.navigationBar.barTintColor = [UIColor darkGrayColor];
    }

    NSLog(@"[OldPlayer] Launched");
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
}

- (BOOL)application:(UIApplication *)application handleOpenURL:(NSURL *)url {
    return YES;
}

@end

#import "AppDelegate.h"
#import "ViewController.h"

@implementation AppDelegate

@synthesize window=_window;

- (BOOL)application:(UIApplication *)application
 didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    ViewController *vc = [[[ViewController alloc] init] autorelease];
    UINavigationController *nav =
        [[[UINavigationController alloc] initWithRootViewController:vc] autorelease];
    self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)dealloc {
    [_window release];
    [super dealloc];
}

@end

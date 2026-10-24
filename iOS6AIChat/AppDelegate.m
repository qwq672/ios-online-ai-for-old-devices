//
//  AppDelegate.m
//  iOS6AIChat
//
//  v261024-13 nav restructure — no more UITabBarController:
//    - App opens straight into a fresh ChatViewController (new chat).
//    - DrawerViewController wraps the chat nav; a hamburger button on
//      the chat navbar slides in the menu (新对话 / 历史记录 / 设置).
//    - The chat view now runs edge-to-edge under the navbar (no tab
//      bar strip), like a modern chat app wearing an iOS 6 suit.
//
//  Subscribes to iOS6ThemeDidChangeNotification so dark mode / font size
//  toggles in Settings re-style the navbar globally (the drawer styles
//  its own sidebar).
//

#import "AppDelegate.h"
#import "iOS6Theme.h"
#import "ChatViewController.h"
#import "DrawerViewController.h"

@interface AppDelegate ()
@property (nonatomic, retain) DrawerViewController *drawerController;
@end

@implementation AppDelegate

@synthesize window = _window, drawerController = _drawerController;

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];

    // Chat is the app's home — fresh conversation on every launch.
    ChatViewController *chatVC = [[[ChatViewController alloc] init] autorelease];
    chatVC.title = NSLocalizedString(@"聊天", nil);

    UINavigationController *chatNav =
        [[[UINavigationController alloc] initWithRootViewController:chatVC] autorelease];

    // Rich grey bar background — 1px top highlight + 3-stop gradient
    // + 1px bottom shadow (App Store / Music style, no blue tint).
    [self _applyThemeToNavs:[NSArray arrayWithObject:chatNav]];

    // Status bar — dark bars need white glyphs, light (silver) bars need
    // black glyphs. Switch with the theme.
    application.statusBarStyle = [iOS6Theme isDarkMode]
        ? UIStatusBarStyleBlackOpaque : UIStatusBarStyleDefault;

    DrawerViewController *drawer =
        [[[DrawerViewController alloc] initWithMainViewController:chatNav] autorelease];
    self.drawerController = drawer;

    self.window.rootViewController = drawer;
    [self.window makeKeyAndVisible];

    // Re-style the navbar whenever the theme changes (dark mode toggle,
    // font size change, etc.). The drawer listens for the same
    // notification and re-styles its sidebar itself.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_themeChanged)
                                                 name:@"iOS6ThemeDidChangeNotification"
                                               object:nil];
    return YES;
}

- (void)_applyThemeToNavs:(NSArray *)navs
{
    for (NSUInteger i = 0; i < [navs count]; i++) {
        UINavigationController *nav = [navs objectAtIndex:i];
        UIImage *navBg = [iOS6Theme barBackgroundImageWithHeight:44];
        if (navBg) {
            [nav.navigationBar setBackgroundImage:navBg forBarMetrics:UIBarMetricsDefault];
        }
        nav.navigationBar.barStyle = [iOS6Theme isDarkMode] ? UIBarStyleBlack : UIBarStyleDefault;
        // Bar item tint: steel blue (light) / light grey (dark) — NOT the
        // bright blue tintColor (user said blue navbar buttons look jarring).
        nav.navigationBar.tintColor = [iOS6Theme barItemTintColor];
        nav.navigationBar.translucent = NO;
    }
}

- (void)_themeChanged
{
    UINavigationController *nav = _drawerController.mainNavigationController;
    if (nav) {
        [self _applyThemeToNavs:[NSArray arrayWithObject:nav]];
    }
    // Status bar follows the theme (white text on dark bars, black on silver).
    [UIApplication sharedApplication].statusBarStyle = [iOS6Theme isDarkMode]
        ? UIStatusBarStyleBlackOpaque : UIStatusBarStyleDefault;
    [_drawerController.view setNeedsDisplay];
}

- (void)applicationWillResignActive:(UIApplication *)application {}
- (void)applicationDidEnterBackground:(UIApplication *)application {}
- (void)applicationWillEnterForeground:(UIApplication *)application {}
- (void)applicationWillTerminate:(UIApplication *)application {}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_window release];
    [_drawerController release];
    [super dealloc];
}

@end

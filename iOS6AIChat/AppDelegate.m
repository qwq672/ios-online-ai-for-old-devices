//
//  AppDelegate.m
//  iOS6AIChat
//
//  v261024-15 nav restructure (Plan 2 = iOS "Messages" app style):
//    - App opens into the conversation LIST (HistoryViewController) —
//      NOT directly into a fresh chat. Mirrors the iOS "信息" / Messages
//      app home screen.
//    - Top-left = settings (gear), top-right = "+" new chat.
//    - Tapping a row pushes ChatViewController onto the stack.
//    - No more DrawerViewController (hamburger menu); the drawer source
//      files are kept in-tree for reference but no longer instantiated.
//
//  Subscribes to iOS6ThemeDidChangeNotification so dark mode / font size
//  toggles in Settings re-style the navbar globally.
//

#import "AppDelegate.h"
#import "iOS6Theme.h"
#import "HistoryViewController.h"

@implementation AppDelegate

@synthesize window = _window;

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];

    // Plan 2: home is the conversation list (HistoryViewController).
    HistoryViewController *historyVC =
        [[[HistoryViewController alloc] initWithNibName:nil bundle:nil] autorelease];

    UINavigationController *nav =
        [[[UINavigationController alloc] initWithRootViewController:historyVC] autorelease];
    [self _applyThemeToNavs:[NSArray arrayWithObject:nav]];

    // Status bar — dark bars need white glyphs, light (silver) bars need
    // black glyphs. Switch with the theme.
    application.statusBarStyle = [iOS6Theme isDarkMode]
        ? UIStatusBarStyleBlackOpaque : UIStatusBarStyleDefault;

    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];

    // Re-style the navbar whenever the theme changes (dark mode toggle,
    // font size change, etc.).
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_themeChanged:)
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

- (void)_themeChanged:(NSNotification *)note
{
    UIWindow *win = self.window;
    UINavigationController *nav = (UINavigationController *)win.rootViewController;
    if ([nav isKindOfClass:[UINavigationController class]]) {
        [self _applyThemeToNavs:[NSArray arrayWithObject:nav]];
        // Tell the visible VC to re-style itself — most VCs listen to the
        // same notification, but we also re-style the navbar here so the
        // bar chrome updates synchronously.
        for (UIViewController *vc in nav.viewControllers) {
            [vc.view setNeedsDisplay];
        }
    }
    [UIApplication sharedApplication].statusBarStyle = [iOS6Theme isDarkMode]
        ? UIStatusBarStyleBlackOpaque : UIStatusBarStyleDefault;
}

- (void)applicationWillResignActive:(UIApplication *)application {}
- (void)applicationDidEnterBackground:(UIApplication *)application {}
- (void)applicationWillEnterForeground:(UIApplication *)application {}
- (void)applicationWillTerminate:(UIApplication *)application {}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_window release];
    [super dealloc];
}

@end

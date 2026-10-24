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
    // v261024-17: wrap the launch body in @try/@catch. A single bad
    // _applyThemeToNavs: call (the iOS6Theme barBackgroundImageWithHeight:
    // path involves CGGradientCreateWithColors + (id)CGColor casts into
    // NSArray, which on iOS 6 sometimes trips on the toll-free-bridge)
    // would otherwise black-screen the app and the user would report
    // "主页没有导航栏 / 一进主页就闪退". On failure we still create a
    // bare window+nav+HistoryVC so the user can at least use the app.
    @try {
        self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];

        // Plan 2: home is the conversation list (HistoryViewController).
        HistoryViewController *historyVC =
            [[[HistoryViewController alloc] initWithNibName:nil bundle:nil] autorelease];

        UINavigationController *nav =
            [[[UINavigationController alloc] initWithRootViewController:historyVC] autorelease];
        // v261024-17: explicitly guarantee the nav bar is visible on
        // the home page. Plan 2 only removes the nav bar INSIDE the
        // conversation (ChatVC), not on the home page.
        [nav setNavigationBarHidden:NO animated:NO];
        @try {
            [self _applyThemeToNavs:[NSArray arrayWithObject:nav]];
        } @catch (NSException *themeE) {
            NSLog(@"[AppDelegate] _applyThemeToNavs crashed: %@ — %@", themeE.name, themeE.reason);
            // Fallback: still set a usable bar style so the nav bar isn't
            // a white-on-white invisible bar.
            nav.navigationBar.barStyle = UIBarStyleDefault;
            nav.navigationBar.translucent = NO;
        }

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
    } @catch (NSException *e) {
        // Catastrophic launch failure. Show a bare window with a label so
        // the user at least sees SOMETHING rather than a black screen.
        NSLog(@"[AppDelegate] launch crashed: %@ — %@", e.name, e.reason);
        self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
        UIViewController *bare = [[[UIViewController alloc] initWithNibName:nil bundle:nil] autorelease];
        bare.view.backgroundColor = [UIColor whiteColor];
        UILabel *lbl = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
        lbl.text = [NSString stringWithFormat:@"App launch crashed:\n%@\n%@", e.name, e.reason];
        lbl.numberOfLines = 0;
        lbl.frame = CGRectMake(20, 40, self.window.bounds.size.width - 40, 200);
        lbl.font = [UIFont systemFontOfSize:14];
        [bare.view addSubview:lbl];
        self.window.rootViewController = bare;
        [self.window makeKeyAndVisible];
    }
    return YES;
}

- (void)_applyThemeToNavs:(NSArray *)navs
{
    for (NSUInteger i = 0; i < [navs count]; i++) {
        UINavigationController *nav = [navs objectAtIndex:i];
        // v261024-17: per-iteration @try — if barBackgroundImageWithHeight:
        // throws (CG gradient drawing can fail in low-memory on iOS 6,
        // or if the (id)CGColorRef cast into NSArray confuses the runtime
        // on toll-free-bridge edge cases), don't break the whole restyle.
        // Fall back to plain barStyle, which always works.
        @try {
            UIImage *navBg = [iOS6Theme barBackgroundImageWithHeight:44];
            if (navBg) {
                [nav.navigationBar setBackgroundImage:navBg forBarMetrics:UIBarMetricsDefault];
            }
            nav.navigationBar.barStyle = [iOS6Theme isDarkMode] ? UIBarStyleBlack : UIBarStyleDefault;
            // Bar item tint: steel blue (light) / light grey (dark) — NOT the
            // bright blue tintColor (user said blue navbar buttons look jarring).
            nav.navigationBar.tintColor = [iOS6Theme barItemTintColor];
            nav.navigationBar.translucent = NO;
        } @catch (NSException *e) {
            NSLog(@"[AppDelegate] _applyThemeToNavs iteration %lu crashed: %@ — %@",
                  (unsigned long)i, e.name, e.reason);
            // Defensive fallback: at least set a non-translucent bar so the
            // nav bar IS visible (vs. transparent + invisible background).
            @try {
                nav.navigationBar.barStyle = [iOS6Theme isDarkMode] ? UIBarStyleBlack : UIBarStyleDefault;
                nav.navigationBar.translucent = NO;
            } @catch (NSException *e2) {
                // Giving up — just leave the bar alone.
            }
        }
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

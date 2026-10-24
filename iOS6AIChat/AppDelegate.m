//
//  AppDelegate.m
//  iOS6AIChat
//
//  v261024-18 Plan-1 restore (user fallback after Plan-2 crashes):
//    - App opens straight into a fresh ChatViewController (new chat).
//    - DrawerViewController wraps the chat nav; a hamburger button on
//      the chat navbar slides in the menu:
//        聊天:   新对话 / 历史记录
//        管理:   模型管理 / 角色管理 / 日志 / 设置
//    - The chat view runs edge-to-edge under the navbar, like a modern
//      chat app wearing an iOS 6 suit.
//
//  v261024-17 defensive layers RETAINED:
//    - Launch body wrapped in @try/@catch (bare-window fallback).
//    - _applyThemeToNavs: per-iteration @try + barStyle fallback.
//    - REMOVED: all [nav setNavigationBarHidden:] calls. Calling it
//      during/around first layout on iOS 6 corrupts the nav controller's
//      container geometry (bar invisible + touches dead + watchdog kill)
//      — exactly matching the user's crash report on v261024-17.
//
//  Subscribes to iOS6ThemeDidChangeNotification so dark mode / font size
//  toggles in Settings re-style the navbar globally (the drawer styles
//  its own sidebar).
//

#import "AppDelegate.h"
#import "iOS6Theme.h"
#import "ChatViewController.h"
#import "DrawerViewController.h"

@implementation AppDelegate

@synthesize window = _window;

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // v261024-17 defensive wrapper — RETAINED in the Plan-1 restore.
    @try {
        self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];

        // Plan 1: chat is the app's home — fresh conversation on every
        // launch. The drawer (hamburger menu) carries navigation.
        ChatViewController *chatVC = [[[ChatViewController alloc] init] autorelease];
        chatVC.title = NSLocalizedString(@"聊天", nil);

        UINavigationController *chatNav =
            [[[UINavigationController alloc] initWithRootViewController:chatVC] autorelease];

        // Rich grey bar background — 1px top highlight + 3-stop gradient
        // + 1px bottom shadow (App Store / Music style, no blue tint).
        // NOTE: deliberately NOT calling setNavigationBarHidden here —
        // the bar is visible by default and touching its hidden state
        // before first layout is the suspected v261024-17 crash cause.
        @try {
            [self _applyThemeToNavs:[NSArray arrayWithObject:chatNav]];
        } @catch (NSException *themeE) {
            NSLog(@"[AppDelegate] _applyThemeToNavs crashed: %@ — %@", themeE.name, themeE.reason);
            chatNav.navigationBar.barStyle = UIBarStyleDefault;
            chatNav.navigationBar.translucent = NO;
        }

        // Status bar — dark bars need white glyphs, light (silver) bars need
        // black glyphs. Switch with the theme.
        application.statusBarStyle = [iOS6Theme isDarkMode]
            ? UIStatusBarStyleBlackOpaque : UIStatusBarStyleDefault;

        DrawerViewController *drawer =
            [[[DrawerViewController alloc] initWithMainViewController:chatNav] autorelease];
        self.window.rootViewController = drawer;
        [self.window makeKeyAndVisible];

        // Re-style the navbar whenever the theme changes (dark mode toggle,
        // font size change, etc.). The drawer listens for the same
        // notification and re-styles its sidebar itself.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_themeChanged)
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
        // v261024-17 per-iteration @try — retained.
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
            @try {
                nav.navigationBar.barStyle = [iOS6Theme isDarkMode] ? UIBarStyleBlack : UIBarStyleDefault;
                nav.navigationBar.translucent = NO;
            } @catch (NSException *e2) {
                // Giving up — just leave the bar alone.
            }
        }
    }
}

- (void)_themeChanged
{
    UIWindow *win = self.window;
    // v261024-18 Plan-1: root is the DrawerViewController; the main nav
    // lives inside it (drawer.mainNavigationController).
    UINavigationController *nav = nil;
    if ([win.rootViewController isKindOfClass:[DrawerViewController class]]) {
        nav = ((DrawerViewController *)win.rootViewController).mainNavigationController;
    } else if ([win.rootViewController isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)win.rootViewController;
    }
    if (nav) {
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

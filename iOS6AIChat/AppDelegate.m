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
//  v261024-19: ALL @try/@catch STRIPPED. The Theos + cctools-port +
//    iPhoneOS6.0.sdk toolchain does not emit correct .ARM.exidx /
//    .ARM.extab personality-function tables for armv7 on every wrapped
//    function — function-entry lookups SIGSEGV'd (NOT an NSException →
//    NSSetUncaughtExceptionHandler never fired → user saw zero crash
//    info in the log). Replaced with nil-guards + early-returns.
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
    // v261024-19: no @try — defensive nil-checks inside.
    self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    if (!self.window) {
        // Catastrophic — nothing we can do.
        return NO;
    }

    // Plan 1: chat is the app's home — fresh conversation on every
    // launch. The drawer (hamburger menu) carries navigation.
    ChatViewController *chatVC = [[[ChatViewController alloc] init] autorelease];
    if (!chatVC) {
        // Catastrophic — show a bare window with an error label so the
        // user sees SOMETHING rather than a black screen.
        UILabel *lbl = [[[UILabel alloc] initWithFrame:CGRectMake(20, 40, self.window.bounds.size.width - 40, 200)] autorelease];
        lbl.text = @"App launch failed: ChatViewController alloc returned nil";
        lbl.numberOfLines = 0;
        lbl.font = [UIFont systemFontOfSize:14];
        UIViewController *bare = [[[UIViewController alloc] initWithNibName:nil bundle:nil] autorelease];
        bare.view.backgroundColor = [UIColor whiteColor];
        [bare.view addSubview:lbl];
        self.window.rootViewController = bare;
        [self.window makeKeyAndVisible];
        return YES;
    }
    chatVC.title = NSLocalizedString(@"聊天", nil);

    UINavigationController *chatNav =
        [[[UINavigationController alloc] initWithRootViewController:chatVC] autorelease];
    if (!chatNav) {
        // Similar catastrophic fallback.
        return YES;
    }

    // Rich grey bar background — 1px top highlight + 3-stop gradient
    // + 1px bottom shadow (App Store / Music style, no blue tint).
    // NOTE: deliberately NOT calling setNavigationBarHidden here —
    // the bar is visible by default and touching its hidden state
    // before first layout is the suspected v261024-17 crash cause.
    [self _applyThemeToNavs:[NSArray arrayWithObject:chatNav]];

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
    return YES;
}

- (void)_applyThemeToNavs:(NSArray *)navs
{
    // v261024-19: NO @try. Each nav's bar is themed independently; a
    // single failure leaves the rest unstyled but doesn't kill the call.
    for (NSUInteger i = 0; i < [navs count]; i++) {
        UINavigationController *nav = [navs objectAtIndex:i];
        if (![nav isKindOfClass:[UINavigationController class]]) continue;
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

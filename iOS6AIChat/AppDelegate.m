//
//  AppDelegate.m
//  iOS6AIChat
//
//  Boots a 3-tab UITabBarController:
//    1) Chat       — current conversation
//    2) History    — list of saved conversations
//    3) Settings   — BaseURL / API Key / Model configuration
//
//  Subscribes to iOS6ThemeDidChangeNotification so dark mode / font size
//  toggles in Settings re-style the navbar/tabbar globally.
//

#import "AppDelegate.h"
#import "iOS6Theme.h"
#import "ChatViewController.h"
#import "HistoryViewController.h"
#import "SettingsViewController.h"
#import "IconDrawing.h"

@interface AppDelegate ()
@property (nonatomic, retain) UITabBarController *tabBarController;
@end

@implementation AppDelegate

@synthesize window = _window, tabBarController=_tabBarController;

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];

    ChatViewController    *chatVC    = [[[ChatViewController    alloc] init] autorelease];
    HistoryViewController *historyVC = [[[HistoryViewController alloc] init] autorelease];
    SettingsViewController*settingsVC= [[[SettingsViewController alloc] init] autorelease];

    UINavigationController *chatNav    = [[[UINavigationController alloc] initWithRootViewController:chatVC]    autorelease];
    UINavigationController *historyNav= [[[UINavigationController alloc] initWithRootViewController:historyVC] autorelease];
    UINavigationController *settingsNav= [[[UINavigationController alloc] initWithRootViewController:settingsVC] autorelease];

    // Apply current theme to navbars + tabbar.
    [self _applyThemeToNavs:@[chatNav, historyNav, settingsNav]];

    // Custom-drawn tab icons (system items are too generic for settings).
    UIImage *chatIcon = [IconDrawing imageForType:IconTypeChatBubble size:CGSizeMake(30, 30) color:[UIColor blackColor]];
    chatNav.tabBarItem = [[[UITabBarItem alloc] initWithTitle:NSLocalizedString(@"聊天", nil) image:chatIcon tag:0] autorelease];
    UIImage *historyIcon = [IconDrawing imageForType:IconTypeClock size:CGSizeMake(30, 30) color:[UIColor blackColor]];
    historyNav.tabBarItem = [[[UITabBarItem alloc] initWithTitle:NSLocalizedString(@"历史", nil) image:historyIcon tag:0] autorelease];
    UIImage *gearIcon = [IconDrawing imageForType:IconTypeGear size:CGSizeMake(30, 30) color:[UIColor blackColor]];
    settingsNav.tabBarItem = [[[UITabBarItem alloc] initWithTitle:NSLocalizedString(@"设置", nil) image:gearIcon tag:0] autorelease];
    chatNav.topViewController.title = NSLocalizedString(@"聊天", nil);
    historyNav.topViewController.title = NSLocalizedString(@"历史", nil);
    settingsNav.topViewController.title = NSLocalizedString(@"设置", nil);

    UITabBarController *tbc = [[[UITabBarController alloc] init] autorelease];
    tbc.viewControllers = [NSArray arrayWithObjects:chatNav, historyNav, settingsNav, nil];
    [iOS6Theme styleTabBarController:tbc];
    self.tabBarController = tbc;

    // Status bar — match dark/light theme. iOS 6 only has Default
    // (black text) and LightContent (white text, iOS 7+).
    // On iOS 6, the status bar is always dark text on light bg unless
    // we use UIStatusBarStyleBlackOpaque. For dark mode, that's the
    // closest we can get — combined with a dark navbar it looks OK.
    if ([iOS6Theme isDarkMode]) {
        application.statusBarStyle = UIStatusBarStyleBlackOpaque;
    } else {
        application.statusBarStyle = UIStatusBarStyleDefault;
    }

    self.window.rootViewController = tbc;
    [self.window makeKeyAndVisible];

    // Re-style the navbar + tabbar whenever the theme changes (dark mode
    // toggle, font size change, etc.).
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
        nav.navigationBar.barStyle = [iOS6Theme isDarkMode] ? UIBarStyleBlack : UIBarStyleDefault;
        // Use buttonContentColor (the inverse of tint) for navbar tint —
        // tint is now white/black, which would be invisible on the
        // navbar's light-grey/dark background. buttonContentColor is the
        // visible-on-navbar color (black on light, white on dark).
        nav.navigationBar.tintColor = [iOS6Theme buttonContentColor];
        nav.navigationBar.translucent = NO;
    }
}

- (void)_themeChanged
{
    UITabBarController *tbc = self.tabBarController;
    [self _applyThemeToNavs:tbc.viewControllers];
    [iOS6Theme styleTabBarController:tbc];
    // Status bar follow theme.
    UIApplication *app = [UIApplication sharedApplication];
    if ([iOS6Theme isDarkMode]) {
        app.statusBarStyle = UIStatusBarStyleBlackOpaque;
    } else {
        app.statusBarStyle = UIStatusBarStyleDefault;
    }
    // Force a redraw.
    [tbc.view setNeedsDisplay];
}

- (void)applicationWillResignActive:(UIApplication *)application {}
- (void)applicationDidEnterBackground:(UIApplication *)application {}
- (void)applicationWillEnterForeground:(UIApplication *)application {}
- (void)applicationWillTerminate:(UIApplication *)application {}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_window release];
    [_tabBarController release];
    [super dealloc];
}

@end

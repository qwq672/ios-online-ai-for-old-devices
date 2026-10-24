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

    // Custom-drawn tab icons — 25pt with ~10pt labels matches the App
    // Store reference proportion (icon:text ≈ 2.5:1). The tab bar uses
    // the image ALPHA as a mask, so the drawing color is irrelevant.
    UIImage *chatIcon = [IconDrawing imageForType:IconTypeChatBubble size:CGSizeMake(25, 25) color:[UIColor blackColor]];
    chatNav.tabBarItem = [[[UITabBarItem alloc] initWithTitle:NSLocalizedString(@"聊天", nil) image:chatIcon tag:0] autorelease];
    UIImage *historyIcon = [IconDrawing imageForType:IconTypeClock size:CGSizeMake(25, 25) color:[UIColor blackColor]];
    historyNav.tabBarItem = [[[UITabBarItem alloc] initWithTitle:NSLocalizedString(@"历史", nil) image:historyIcon tag:0] autorelease];
    UIImage *gearIcon = [IconDrawing imageForType:IconTypeGear size:CGSizeMake(25, 25) color:[UIColor blackColor]];
    settingsNav.tabBarItem = [[[UITabBarItem alloc] initWithTitle:NSLocalizedString(@"设置", nil) image:gearIcon tag:0] autorelease];
    chatNav.topViewController.title = NSLocalizedString(@"聊天", nil);
    historyNav.topViewController.title = NSLocalizedString(@"历史", nil);
    settingsNav.topViewController.title = NSLocalizedString(@"设置", nil);

    UITabBarController *tbc = [[[UITabBarController alloc] init] autorelease];
    tbc.viewControllers = [NSArray arrayWithObjects:chatNav, historyNav, settingsNav, nil];
    [iOS6Theme styleTabBarController:tbc];
    self.tabBarController = tbc;

    // Status bar — dark bars need white glyphs, light (silver) bars need
    // black glyphs. Switch with the theme (was always BlackOpaque, which
    // made light-mode status text invisible against the silver navbar).
    application.statusBarStyle = [iOS6Theme isDarkMode]
        ? UIStatusBarStyleBlackOpaque : UIStatusBarStyleDefault;

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
        // Rich grey bar background — 1px top highlight + 3-stop gradient
        // + 1px bottom shadow (App Store / Music style, no blue tint).
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
    UITabBarController *tbc = self.tabBarController;
    [self _applyThemeToNavs:tbc.viewControllers];
    [iOS6Theme styleTabBarController:tbc];
    // Status bar follows the theme (white text on dark bars, black on silver).
    [UIApplication sharedApplication].statusBarStyle = [iOS6Theme isDarkMode]
        ? UIStatusBarStyleBlackOpaque : UIStatusBarStyleDefault;
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

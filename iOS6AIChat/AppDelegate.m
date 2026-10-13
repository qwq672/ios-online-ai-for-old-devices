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

    // Style chat + history with system icons; settings uses a custom-drawn
    // gear icon (UITabBarSystemItemMore is too generic, UITabBarSystemItemContacts
    // is misleading).
    // Create tab bar items with custom images at init time (avoids double-tap bug).
    UIImage *chatIcon = [IconDrawing imageForType:IconTypeChatBubble size:CGSizeMake(30, 30) color:[UIColor blackColor]];
    chatNav.tabBarItem = [[[UITabBarItem alloc] initWithTitle:NSLocalizedString(@"聊天", nil) image:chatIcon tag:0] autorelease];
    chatNav.navigationBar.barStyle = [iOS6Theme isDarkMode] ? UIBarStyleBlack : UIBarStyleDefault;
    chatNav.navigationBar.tintColor = [iOS6Theme tintColor];
    chatNav.navigationBar.translucent = NO;
    chatNav.topViewController.title = NSLocalizedString(@"聊天", nil);
    UIImage *historyIcon = [IconDrawing imageForType:IconTypeClock size:CGSizeMake(30, 30) color:[UIColor blackColor]];
    historyNav.tabBarItem = [[[UITabBarItem alloc] initWithTitle:NSLocalizedString(@"历史", nil) image:historyIcon tag:0] autorelease];
    historyNav.navigationBar.barStyle = [iOS6Theme isDarkMode] ? UIBarStyleBlack : UIBarStyleDefault;
    historyNav.navigationBar.tintColor = [iOS6Theme tintColor];
    historyNav.navigationBar.translucent = NO;
    historyNav.topViewController.title = NSLocalizedString(@"历史", nil);
    UIImage *gearIcon = [IconDrawing imageForType:IconTypeGear size:CGSizeMake(30, 30) color:[UIColor blackColor]];
    settingsNav.tabBarItem = [[[UITabBarItem alloc] initWithTitle:NSLocalizedString(@"设置", nil) image:gearIcon tag:0] autorelease];
    settingsNav.navigationBar.barStyle = [iOS6Theme isDarkMode] ? UIBarStyleBlack : UIBarStyleDefault;
    settingsNav.navigationBar.tintColor = [iOS6Theme tintColor];
    settingsNav.navigationBar.translucent = NO;
    settingsNav.topViewController.title = NSLocalizedString(@"设置", nil);

    UITabBarController *tbc = [[[UITabBarController alloc] init] autorelease];
    tbc.viewControllers = [NSArray arrayWithObjects:chatNav, historyNav, settingsNav, nil];
    [iOS6Theme styleTabBarController:tbc];
    self.tabBarController = tbc;

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

- (void)_themeChanged
{
    // Re-style all three navigation controllers + the tab bar controller
    // with the current theme palette.
    UITabBarController *tbc = self.tabBarController;
    NSArray *navs = tbc.viewControllers;
    for (NSUInteger i = 0; i < [navs count]; i++) {
        UINavigationController *nav = [navs objectAtIndex:i];
        nav.navigationBar.barStyle = [iOS6Theme isDarkMode] ? UIBarStyleBlack : UIBarStyleDefault;
        nav.navigationBar.tintColor = [iOS6Theme tintColor];
    }

    [iOS6Theme styleTabBarController:tbc];
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

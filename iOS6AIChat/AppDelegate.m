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
    [iOS6Theme styleNavigationController:chatNav     title:NSLocalizedString(@"聊天", nil)     systemIcon:UITabBarSystemItemFavorites];
    // Override Chat tab icon with custom drawn speech bubble.
    chatNav.tabBarItem.image = [IconDrawing imageForType:IconTypeChatBubble size:CGSizeMake(30, 30) color:[UIColor blackColor]];
    [iOS6Theme styleNavigationController:historyNav  title:NSLocalizedString(@"历史", nil)     systemIcon:UITabBarSystemItemHistory];
    [iOS6Theme styleNavigationController:settingsNav title:NSLocalizedString(@"设置", nil)     systemIcon:UITabBarSystemItemMore];
    // Override Settings tab icon with custom drawn gear.
    settingsNav.tabBarItem.image = [IconDrawing imageForType:IconTypeGear size:CGSizeMake(30, 30) color:[UIColor blackColor]];

    // Replace the Settings tab icon with a drawn gear.
    UIImage *gearIcon = [IconDrawing imageForType:IconTypeGear
                                              size:CGSizeMake(30, 30)
                                             color:[UIColor blackColor]];
    // UITabBarItem image is treated as an alpha mask — the colour doesn't
    // matter; iOS tints the icon blue when selected, grey when not.
    settingsNav.tabBarItem.image = gearIcon;
    settingsNav.tabBarItem.title = NSLocalizedString(@"设置", nil);

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
    NSArray *titles = @[@"聊天", @"历史", @"设置"];
    NSArray *icons = @[
        [NSNumber numberWithInt:UITabBarSystemItemFavorites],
        [NSNumber numberWithInt:UITabBarSystemItemHistory],
        [NSNumber numberWithInt:UITabBarSystemItemMore],
    ];
    for (NSUInteger i = 0; i < [navs count]; i++) {
        UINavigationController *nav = [navs objectAtIndex:i];
        [iOS6Theme styleNavigationController:nav
                                       title:[titles objectAtIndex:i]
                                  systemIcon:(UITabBarSystemItem)[[icons objectAtIndex:i] intValue]];
    }
    // Re-apply the gear icon for Settings (styleNavigationController resets
    // the tabBarItem).
    UINavigationController *settingsNav = [navs objectAtIndex:2];
    UIImage *gearIcon = [IconDrawing imageForType:IconTypeGear
                                              size:CGSizeMake(30, 30)
                                             color:[UIColor blackColor]];
    settingsNav.tabBarItem.image = gearIcon;

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

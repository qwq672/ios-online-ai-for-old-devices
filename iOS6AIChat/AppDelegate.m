//
//  AppDelegate.m
//  iOS6AIChat
//
//  Boots a 3-tab UITabBarController:
//    1) Chat       — current conversation
//    2) History    — list of saved conversations
//    3) Settings   — BaseURL / API Key / Model configuration
//
//  The tab bar is styled by iOS6Theme to mimic the iOS 6 glass-gloss look.
//

#import "AppDelegate.h"
#import "iOS6Theme.h"
#import "ChatViewController.h"
#import "HistoryViewController.h"
#import "SettingsViewController.h"

@implementation AppDelegate

@synthesize window = _window;

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // Pre-warm the conversation store so the first tab is ready instantly.
    self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];

    ChatViewController    *chatVC    = [[[ChatViewController    alloc] init] autorelease];
    HistoryViewController *historyVC = [[[HistoryViewController alloc] init] autorelease];
    SettingsViewController*settingsVC= [[[SettingsViewController alloc] init] autorelease];

    // Wrap each in a navigation controller so we get the iOS 6 navbar tint.
    UINavigationController *chatNav    = [[[UINavigationController alloc] initWithRootViewController:chatVC]    autorelease];
    UINavigationController *historyNav= [[[UINavigationController alloc] initWithRootViewController:historyVC] autorelease];
    UINavigationController *settingsNav= [[[UINavigationController alloc] initWithRootViewController:settingsVC] autorelease];

    [iOS6Theme styleNavigationController:chatNav     title:NSLocalizedString(@"Chat", nil)    systemIcon:UITabBarSystemItemFavorites];
    [iOS6Theme styleNavigationController:historyNav  title:NSLocalizedString(@"History", nil) systemIcon:UITabBarSystemItemHistory];
    [iOS6Theme styleNavigationController:settingsNav title:NSLocalizedString(@"Settings", nil) systemIcon:UITabBarSystemItemContacts];

    UITabBarController *tbc = [[[UITabBarController alloc] init] autorelease];
    tbc.viewControllers = [NSArray arrayWithObjects:chatNav, historyNav, settingsNav, nil];
    [iOS6Theme styleTabBarController:tbc];

    self.window.rootViewController = tbc;
    [self.window makeKeyAndVisible];

    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {}
- (void)applicationDidEnterBackground:(UIApplication *)application {}
- (void)applicationWillEnterForeground:(UIApplication *)application {}
- (void)applicationWillTerminate:(UIApplication *)application {}

- (void)dealloc
{
    [_window release];
    [super dealloc];
}

@end

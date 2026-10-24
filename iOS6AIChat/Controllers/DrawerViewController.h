//
//  DrawerViewController.h
//  iOS6AIChat
//
//  Slide-out drawer navigation (v261024-13 nav restructure).
//
//  Replaces the old 3-tab UITabBarController:
//    - App opens straight into a fresh ChatViewController (new conversation).
//    - No tab bar — the chat view runs edge-to-edge under the navbar.
//    - A hamburger button on the chat navbar slides this drawer in
//      from the left edge (Facebook / Path style, iOS 6 era authentic).
//
//  Menu rows:
//    1) 新对话  — starts a fresh conversation in the chat root
//    2) 历史记录 — pushes HistoryViewController onto the main nav stack
//    3) 设置     — pushes SettingsViewController onto the main nav stack
//
//  ChatViewController toggles the drawer by posting
//  DrawerViewControllerToggleNotification (no direct coupling).
//

#import <UIKit/UIKit.h>

extern NSString *const DrawerViewControllerToggleNotification;

@interface DrawerViewController : UIViewController

// Designated initializer. mainNav is retained as the drawer's centre
// content — a UINavigationController wrapping ChatViewController.
// History / Settings are pushed onto this same stack.
- (id)initWithMainViewController:(UINavigationController *)mainNav;

- (void)toggleSidebar;
- (void)openSidebar;
- (void)closeSidebarAnimated:(BOOL)animated;

// The drawer's centre content nav (exposed so AppDelegate can re-style
// its navbar on theme changes).
@property (nonatomic, readonly) UINavigationController *mainNavigationController;

// Close the drawer, then push a VC onto the main nav stack once the
// slide-back animation has finished (looks clean rather than chaotic).
- (void)pushViewControllerAfterClose:(UIViewController *)vc;

@end

//
//  DrawerViewController.m
//  iOS6AIChat
//
//  Slide-out drawer navigation (see header for design notes).
//
//  Geometry (Path-style overlay drawer, NOT Facebook main-shift):
//    - The sidebar slides in OVER the dimmed main content — moving the
//      main nav's frame around is fragile (autolayout-era trickery on
//      a manual-layout OS), so we never touch it.
//    - sidebarW = MIN(280, screenW * 0.8)  → 256pt on a 320pt iPhone.
//    - z-order: main nav view (0) < dim overlay (1) < sidebar (2).
//
//  Memory model: MRC (matches the rest of the codebase).
//

#import "DrawerViewController.h"
#import "iOS6Theme.h"
#import "IconDrawing.h"
#import "ChatViewController.h"
#import "HistoryViewController.h"
#import "SettingsViewController.h"

NSString *const DrawerViewControllerToggleNotification = @"DrawerViewControllerToggle";

static NSString *const kMenuCellID = @"DrawerMenuCell";

// Menu model.
enum {
    kMenuRowNewChat = 0,
    kMenuRowHistory = 1,
    kMenuRowSettings = 2,
    kMenuRowCount   = 3
};

static CGFloat const kAnimDuration = 0.25f;
static CGFloat const kDimAlpha     = 0.45f;

@interface DrawerViewController () <UITableViewDataSource, UITableViewDelegate> {
    UINavigationController *_mainNav;
    UIView      *_sidebarView;   // slides left/right
    UIControl   *_dimOverlay;    // tap to close
    UITableView *_menuTable;
    UILabel     *_headerTitle;
    UILabel     *_headerSubtitle;
    UIView      *_headerHairline;
    NSArray     *_menuTitles;
    NSArray     *_menuIcons;     // re-built on theme change (icon tint)
    BOOL         _open;
    CGFloat      _sidebarW;
}
@end

@implementation DrawerViewController

- (UINavigationController *)mainNavigationController
{
    return _mainNav;
}

#pragma mark - Lifecycle

- (id)initWithMainViewController:(UIViewController *)mainVC
{
    if (self = [super initWithNibName:nil bundle:nil]) {
        _mainNav = [mainVC retain];

        CGRect scr = [[UIScreen mainScreen] bounds];
        _sidebarW = MIN(280.0f, scr.size.width * 0.8f);

        _menuTitles = [[NSArray arrayWithObjects:
                        NSLocalizedString(@"新对话", nil),
                        NSLocalizedString(@"历史记录", nil),
                        NSLocalizedString(@"设置", nil), nil] retain];

        // The drawer toggles itself when ChatViewController posts the
        // toggle notification (hamburger button) — no direct coupling.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_onToggleRequest)
                                                     name:DrawerViewControllerToggleNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_mainNav release];
    [_sidebarView release];
    [_dimOverlay release];
    [_menuTable release];
    [_headerTitle release];
    [_headerSubtitle release];
    [_headerHairline release];
    [_menuTitles release];
    [_menuIcons release];
    [super dealloc];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    // Drawer void — visible only as the dimmed strip right of the
    // sidebar while open; black works for both themes.
    self.view.backgroundColor = [UIColor blackColor];

    // --- Main content (child VC, full frame, never moved) --------------
    [self addChildViewController:_mainNav];
    _mainNav.view.frame = self.view.bounds;
    _mainNav.view.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                      UIViewAutoresizingFlexibleHeight);
    [self.view addSubview:_mainNav.view];
    [_mainNav didMoveToParentViewController:self];

    // --- Dim overlay (tap to close) -------------------------------------
    _dimOverlay = [[UIControl alloc] initWithFrame:self.view.bounds];
    _dimOverlay.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                    UIViewAutoresizingFlexibleHeight);
    _dimOverlay.backgroundColor = [UIColor blackColor];
    _dimOverlay.alpha = 0.0f;
    _dimOverlay.userInteractionEnabled = NO;   // closed by default
    [_dimOverlay addTarget:self
                    action:@selector(_overlayTapped)
          forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_dimOverlay];

    // --- Sidebar ---------------------------------------------------------
    CGFloat H = self.view.bounds.size.height;
    _sidebarView = [[UIView alloc] initWithFrame:CGRectMake(-_sidebarW, 0, _sidebarW, H)];
    _sidebarView.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    _sidebarView.backgroundColor = [iOS6Theme pinstripeBackground];
    [self.view addSubview:_sidebarView];

    // Fixed header (does NOT scroll with the menu table).
    // Content starts below the 20pt status bar.
    _headerTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 30, _sidebarW - 32, 24)];
    _headerTitle.text = NSLocalizedString(@"AI 聊天", nil);
    _headerTitle.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:19]];
    _headerTitle.backgroundColor = [UIColor clearColor];
    [_sidebarView addSubview:_headerTitle];

    _headerSubtitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 56, _sidebarW - 32, 16)];
    _headerSubtitle.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:11]];
    _headerSubtitle.backgroundColor = [UIColor clearColor];
    _headerSubtitle.text = [self _versionLine];
    [_sidebarView addSubview:_headerSubtitle];

    _headerHairline = [[UIView alloc] initWithFrame:CGRectMake(0, 80, _sidebarW, 1)];
    [_sidebarView addSubview:_headerHairline];

    // Menu table below the header.
    _menuTable = [[UITableView alloc] initWithFrame:CGRectMake(0, 84, _sidebarW, H - 84)
                                              style:UITableViewStyleGrouped];
    _menuTable.dataSource = self;
    _menuTable.delegate = self;
    _menuTable.backgroundColor = [UIColor clearColor];
    _menuTable.backgroundView = nil;   // strip the iOS 6 default pattern
    _menuTable.opaque = NO;
    _menuTable.rowHeight = 46;
    _menuTable.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    [_sidebarView addSubview:_menuTable];

    // Theme-dependent colors + icons.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_themeChanged)
                                                 name:@"iOS6ThemeDidChangeNotification"
                                               object:nil];

    [self _styleSidebar];
}

- (void)_styleSidebar
{
    _sidebarView.backgroundColor = [iOS6Theme pinstripeBackground];
    _headerTitle.textColor = [iOS6Theme textColor];
    _headerTitle.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:19]];
    _headerSubtitle.textColor = [iOS6Theme secondaryTextColor];
    _headerSubtitle.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:11]];
    _headerHairline.backgroundColor = [iOS6Theme hairlineColor];

    // Menu icons tinted with the saturated tab-selected blue — matches
    // the "selected tab" blue the user liked on the old tab bar.
    UIColor *iconColor = [iOS6Theme tabBarSelectedTintColor];
    NSArray *types = [NSArray arrayWithObjects:
                      [NSNumber numberWithInt:IconTypeChatBubble],
                      [NSNumber numberWithInt:IconTypeClock],
                      [NSNumber numberWithInt:IconTypeGear], nil];
    NSMutableArray *imgs = [NSMutableArray arrayWithCapacity:[types count]];
    for (NSNumber *tn in types) {
        UIImage *img = [IconDrawing imageForType:(IconType)[tn intValue]
                                            size:CGSizeMake(26, 26)
                                           color:iconColor];
        [imgs addObject:img];
    }
    [_menuIcons release];
    _menuIcons = [imgs retain];

    [_menuTable reloadData];
}

- (NSString *)_versionLine
{
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *ver   = [info objectForKey:@"CFBundleShortVersionString"];
    NSString *build = [info objectForKey:@"CFBundleVersion"];
    if (ver && build) {
        return [NSString stringWithFormat:NSLocalizedString(@"iOS 6 · v%@ (%@) · 为老设备而生", nil),
                ver, build];
    }
    return NSLocalizedString(@"iOS 6 · 为老设备而生", nil);
}

#pragma mark - Theme / toggle notifications

- (void)_themeChanged
{
    [self _styleSidebar];
}

- (void)_onToggleRequest
{
    [self toggleSidebar];
}

#pragma mark - Open / close

- (void)toggleSidebar
{
    if (_open) {
        [self closeSidebarAnimated:YES];
    } else {
        [self openSidebar];
    }
}

- (void)openSidebar
{
    if (_open) return;
    _open = YES;
    _dimOverlay.userInteractionEnabled = YES;
    [UIView animateWithDuration:kAnimDuration
                     animations:^{
        _sidebarView.frame = CGRectMake(0, 0, _sidebarW, _sidebarView.bounds.size.height);
        _dimOverlay.alpha  = kDimAlpha;
    }];
}

- (void)closeSidebarAnimated:(BOOL)animated
{
    if (!_open) return;
    _open = NO;
    _dimOverlay.userInteractionEnabled = NO;
    void (^slide)(void) = ^{
        _sidebarView.frame = CGRectMake(-_sidebarW, 0, _sidebarW, _sidebarView.bounds.size.height);
        _dimOverlay.alpha  = 0.0f;
    };
    if (animated) {
        [UIView animateWithDuration:kAnimDuration animations:slide];
    } else {
        slide();
    }
}

- (void)_overlayTapped
{
    [self closeSidebarAnimated:YES];
}

- (void)pushViewControllerAfterClose:(UIViewController *)vc
{
    [self closeSidebarAnimated:YES];
    // Push once the slide-back has finished — concurrent push + slide
    // animations look chaotic.
    [self performSelector:@selector(_pushNow:) withObject:vc afterDelay:kAnimDuration + 0.03];
}

- (void)_pushNow:(UIViewController *)vc
{
    // Defensive: if something is already pushed (shouldn't happen — the
    // hamburger only lives on the chat root), snap to root first.
    if ([_mainNav.viewControllers count] > 1) {
        [_mainNav popToRootViewControllerAnimated:NO];
    }
    [_mainNav pushViewController:vc animated:YES];
}

- (void)_newChatAfterClose
{
    ChatViewController *chat = nil;
    if ([_mainNav.viewControllers count] > 0) {
        chat = [_mainNav.viewControllers objectAtIndex:0];
    }
    if ([chat isKindOfClass:[ChatViewController class]]) {
        [chat startNewConversation];
    }
}

#pragma mark - Menu table (data source)

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return kMenuRowCount;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
          cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kMenuCellID];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:kMenuCellID] autorelease];
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    // Re-applied EVERY configure (not just on creation) — reused cells
    // would otherwise keep the pre-theme-flip background colour.
    // Default grouped cells are white; dark mode needs the charcoal
    // fill or the sidebar looks broken against the dark pinstripe.
    cell.backgroundColor = [iOS6Theme isDarkMode]
        ? [iOS6Theme colorWithHex:@"#26262A"]
        : [UIColor whiteColor];
    NSInteger row = indexPath.row;
    if (row >= 0 && row < (NSInteger)[_menuTitles count]) {
        cell.textLabel.text  = [_menuTitles objectAtIndex:row];
        cell.textLabel.font  = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
        cell.textLabel.textColor = [iOS6Theme textColor];
        if (row < (NSInteger)[_menuIcons count]) {
            cell.imageView.image = [_menuIcons objectAtIndex:row];
        }
    }
    return cell;
}

#pragma mark - Menu table (delegate)

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch (indexPath.row) {
        case kMenuRowNewChat:
            [self closeSidebarAnimated:YES];
            [self performSelector:@selector(_newChatAfterClose)
                       withObject:nil
                       afterDelay:kAnimDuration + 0.03];
            break;
        case kMenuRowHistory: {
            HistoryViewController *history = [[[HistoryViewController alloc] init] autorelease];
            // Its own init sets the English "History" — keep the navbar
            // consistently Chinese like the rest of the chrome.
            history.title = NSLocalizedString(@"历史", nil);
            [self pushViewControllerAfterClose:history];
            break;
        }
        case kMenuRowSettings: {
            SettingsViewController *settings = [[[SettingsViewController alloc] init] autorelease];
            settings.title = NSLocalizedString(@"设置", nil);
            [self pushViewControllerAfterClose:settings];
            break;
        }
    }
}

@end

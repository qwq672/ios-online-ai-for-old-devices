//
//  DrawerViewController.m
//  iOS6AIChat
//
//  Slide-out drawer navigation (v261024-18 Plan-1 restore + upgrade).
//
//  Geometry (Path-style overlay drawer, NOT Facebook main-shift):
//    - The sidebar slides in OVER the dimmed main content — moving the
//      main nav's frame around is fragile (autolayout-era trickery on
//      a manual-layout OS), so we never touch it.
//    - sidebarW = MIN(280, screenW * 0.8)  → 256pt on a 320pt iPhone.
//    - z-order: main nav view (0) < dim overlay (1) < sidebar (2).
//
//  v261024-18 menu (user-requested Plan-1 fallback with upgrades):
//    Section 0 — 聊天:   新对话 / 历史记录
//    Section 1 — 管理:   模型管理 / 角色管理 / 日志 / 设置
//
//  Skeuomorphic styling (user: "界面要好看点,确定所有界面均符合拟物感"):
//    - Sidebar background: drawn LINEN pattern (fine woven texture like
//      the iOS 6 Settings/Notes background — CoreGraphics, no assets).
//    - Sidebar right edge: 1px highlight line + soft drop shadow — reads
//      as a physical panel sliding over the content.
//    - Header block with app name + version line, divided by a hairline.
//    - Grouped menu table, tinted silhouette icons, bold labels.
//
//  Memory model: MRC (matches the rest of the codebase).
//

#import "DrawerViewController.h"
#import "iOS6Theme.h"
#import "IconDrawing.h"
#import "ChatViewController.h"
#import "HistoryViewController.h"
#import "SettingsViewController.h"
#import "ModelManagementViewController.h"
#import "CharacterManagementViewController.h"
#import "LogViewController.h"
#import <QuartzCore/QuartzCore.h>

NSString *const DrawerViewControllerToggleNotification = @"DrawerViewControllerToggle";

static NSString *const kMenuCellID = @"DrawerMenuCell";

// Menu model — two sections.
enum {
    kMenuSectionChat = 0,      // 新对话 / 历史记录
    kMenuSectionManage,        // 模型管理 / 角色管理 / 日志 / 设置
    kMenuSectionCount
};

// Rows per section.
enum {
    kMenuRowNewChat = 0,
    kMenuRowHistory = 1,
    kMenuRowChatCount = 2,

    kMenuRowModels = 0,
    kMenuRowCharacters = 1,
    kMenuRowLogs = 2,
    kMenuRowSettings = 3,
    kMenuRowManageCount = 4
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
    UIView      *_edgeHighlight; // 1px light line on the sidebar's right edge
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

- (id)initWithMainViewController:(UINavigationController *)mainNav
{
    if (self = [super initWithNibName:nil bundle:nil]) {
        _mainNav = [mainNav retain];

        CGRect scr = [[UIScreen mainScreen] bounds];
        _sidebarW = MIN(280.0f, scr.size.width * 0.8f);

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
    [_edgeHighlight release];
    [_menuIcons release];
    [super dealloc];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    // v261024-19: STRIPPED @try — no exception tables on cctools-port
    // armv7. _buildViewHierarchy does its own nil-checks. If anything
    // inside it returns early with a partial setup, the fallback below
    // adds the main chat view so the app stays usable.
    [self _buildViewHierarchy];
    if (!_mainNav.view.superview) {
        // Fallback: at least show the main chat so the app is usable.
        [self addChildViewController:_mainNav];
        _mainNav.view.frame = self.view.bounds;
        [self.view addSubview:_mainNav.view];
        [_mainNav didMoveToParentViewController:self];
    }
}

- (void)_buildViewHierarchy
{
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
    if (H < 200) H = [[UIScreen mainScreen] bounds].size.height; // bounds-zero guard
    _sidebarView = [[UIView alloc] initWithFrame:CGRectMake(-_sidebarW, 0, _sidebarW, H)];
    _sidebarView.autoresizingMask = UIViewAutoresizingFlexibleHeight;

    // Skeuomorphic panel: linen-pattern background (drawn, no assets),
    // drop shadow, and a 1px light bevel on the right edge so it reads
    // as a physical slab sliding over the content.
    // (Background pattern applied in _styleSidebar via
    // colorWithPatternImage: — a repeating 8pt tile.)
    _sidebarView.backgroundColor = [iOS6Theme pinstripeBackground];

    // Physical-panel drop shadow (right edge only via shadow path).
    _sidebarView.layer.shadowColor = [UIColor blackColor].CGColor;
    _sidebarView.layer.shadowOpacity = 0.55f;
    _sidebarView.layer.shadowRadius = 6.0f;
    _sidebarView.layer.shadowOffset = CGSizeMake(4.0f, 0.0f);
    // Shadow path hugging the right edge (cheaper than full-rect shadow).
    CGPathRef shadowPath = CGPathCreateWithRect(
        CGRectMake(_sidebarW - 2.0f, -20.0f, 8.0f, H + 40.0f), NULL);
    _sidebarView.layer.shadowPath = shadowPath;
    CGPathRelease(shadowPath);

    // 1px light bevel line on the right edge (the "lit" side of the slab).
    _edgeHighlight = [[UIView alloc] initWithFrame:CGRectMake(_sidebarW - 1.5f, 0, 1.5f, H)];
    _edgeHighlight.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.35f];
    _edgeHighlight.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    [_sidebarView addSubview:_edgeHighlight];

    [self.view addSubview:_sidebarView];

    // Fixed header (does NOT scroll with the menu table).
    // Content starts below the 20pt status bar.
    _headerTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 28, _sidebarW - 32, 26)];
    _headerTitle.text = NSLocalizedString(@"AI 聊天", nil);
    _headerTitle.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:20]];
    _headerTitle.backgroundColor = [UIColor clearColor];
    // Subtle embossed text shadow (light mode) — classic iOS 6 label look.
    _headerTitle.shadowColor = [iOS6Theme isDarkMode]
        ? [UIColor colorWithWhite:0.0f alpha:0.5f]
        : [UIColor colorWithWhite:1.0f alpha:0.85f];
    _headerTitle.shadowOffset = CGSizeMake(0, 1);
    [_sidebarView addSubview:_headerTitle];

    _headerSubtitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 55, _sidebarW - 32, 16)];
    _headerSubtitle.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:11]];
    _headerSubtitle.backgroundColor = [UIColor clearColor];
    _headerSubtitle.text = [self _versionLine];
    [_sidebarView addSubview:_headerSubtitle];

    _headerHairline = [[UIView alloc] initWithFrame:CGRectMake(0, 80, _sidebarW, 2)];
    // Double-line hairline: dark line under a light line (recessed groove).
    _headerHairline.backgroundColor = [iOS6Theme hairlineColor];
    _headerHairline.autoresizingMask = UIViewAutoresizingFlexibleWidth;
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
    // Light separator color so grouped rows read as separate "tiles".
    _menuTable.separatorColor = [iOS6Theme hairlineColor];
    [_sidebarView addSubview:_menuTable];

    // Theme-dependent colors + icons.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_themeChanged)
                                                 name:@"iOS6ThemeDidChangeNotification"
                                               object:nil];

    [self _styleSidebar];
}

// Draw the linen background pattern — fine woven texture like the iOS 6
// Settings app background. 8x8pt tile, diagonal weave strokes.
- (UIImage *)_linenPatternImage
{
    // v261024-19: NO @try — nil-guards instead.
    CGFloat tile = 8.0f;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(tile, tile), NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }
    BOOL dark = [iOS6Theme isDarkMode];
    // Base fill.
    NSString *baseHex = dark ? @"#151517" : @"#EDEDF0";
    CGContextSetFillColorWithColor(ctx, [iOS6Theme colorWithHex:baseHex].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, tile, tile));
    // Weave strokes: two thin diagonal lines (light + darker) that
    // cross at ~45°, replicated per tile — the classic "linen" look.
    UIColor *hi = dark ? [UIColor colorWithWhite:1.0f alpha:0.045f]
                       : [UIColor colorWithWhite:1.0f alpha:0.75f];
    UIColor *lo = dark ? [UIColor colorWithWhite:0.0f alpha:0.28f]
                       : [UIColor colorWithWhite:0.0f alpha:0.045f];
    CGContextSetLineWidth(ctx, 0.8f);
    // Line A: top-left → bottom-right (+ wrap-around segments so the
    // tile joins seamlessly).
    CGContextSetStrokeColorWithColor(ctx, hi.CGColor);
    CGContextMoveToPoint(ctx, -2, tile + 2);
    CGContextAddLineToPoint(ctx, tile + 2, -2);
    CGContextStrokePath(ctx);
    // Line B: bottom-left → top-right.
    CGContextSetStrokeColorWithColor(ctx, lo.CGColor);
    CGContextMoveToPoint(ctx, -2, -2);
    CGContextAddLineToPoint(ctx, tile + 2, tile + 2);
    CGContextStrokePath(ctx);

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;  // autoreleased
}

- (void)_styleSidebar
{
    // v261024-19: NO @try — each step is independently nil-guarded.
    if (!_headerTitle || !_headerSubtitle || !_headerHairline ||
        !_edgeHighlight || !_sidebarView || !_menuTable) {
        NSLog(@"[DrawerVC] _styleSidebar: missing subview — skip");
        return;
    }
    _headerTitle.textColor = [iOS6Theme textColor];
    _headerTitle.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:20]];
    _headerSubtitle.textColor = [iOS6Theme secondaryTextColor];
    _headerSubtitle.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:11]];
    _headerSubtitle.shadowColor = [iOS6Theme isDarkMode]
        ? [UIColor colorWithWhite:0.0f alpha:0.4f]
        : [UIColor colorWithWhite:1.0f alpha:0.7f];
    _headerSubtitle.shadowOffset = CGSizeMake(0, 1);
    _headerHairline.backgroundColor = [iOS6Theme hairlineColor];
    _edgeHighlight.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.35f];

    // Refresh the linen background (theme-dependent).
    UIImage *linen = [self _linenPatternImage];
    if (linen) {
        // Pattern-color background so the 8pt tile REPEATS.
        UIColor *pattern = [UIColor colorWithPatternImage:linen];
        _sidebarView.backgroundColor = pattern;
    } else {
        _sidebarView.backgroundColor = [iOS6Theme pinstripeBackground];
    }

    // Menu icons tinted with the saturated tab-selected blue — matches
    // the "selected tab" blue the user liked on the old tab bar.
    // Order matches menu rows across both sections:
    //   chat: NewChat / History — manage: Models / Characters / Logs / Settings
    UIColor *iconColor = [iOS6Theme tabBarSelectedTintColor];
    NSArray *types = [NSArray arrayWithObjects:
                      [NSNumber numberWithInt:IconTypeChatBubble],
                      [NSNumber numberWithInt:IconTypeClock],
                      [NSNumber numberWithInt:IconTypeLayers],
                      [NSNumber numberWithInt:IconTypePerson],
                      [NSNumber numberWithInt:IconTypeDoc],
                      [NSNumber numberWithInt:IconTypeGear], nil];
    NSMutableArray *imgs = [NSMutableArray arrayWithCapacity:[types count]];
    for (NSNumber *tn in types) {
        UIImage *img = [IconDrawing imageForType:(IconType)[tn intValue]
                                            size:CGSizeMake(26, 26)
                                           color:iconColor];
        if (img) [imgs addObject:img];
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
    return kMenuSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == kMenuSectionChat) return kMenuRowChatCount;
    return kMenuRowManageCount;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == kMenuSectionChat) {
        return NSLocalizedString(@"聊天", nil);
    }
    return NSLocalizedString(@"管理", nil);
}

- (UITableViewCell *)tableView:(UITableView *)tableView
          cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kMenuCellID];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:kMenuCellID] autorelease];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    }
    // Re-applied EVERY configure (not just on creation) — reused cells
    // would otherwise keep the pre-theme-flip background colour.
    // Default grouped cells are white; dark mode needs the charcoal
    // fill or the sidebar looks broken against the dark linen.
    cell.backgroundColor = [iOS6Theme isDarkMode]
        ? [iOS6Theme colorWithHex:@"#26262A"]
        : [UIColor whiteColor];
    cell.textLabel.textColor = [iOS6Theme textColor];
    cell.textLabel.shadowColor = [iOS6Theme isDarkMode]
        ? [UIColor colorWithWhite:0.0f alpha:0.35f]
        : [UIColor colorWithWhite:1.0f alpha:0.9f];
    cell.textLabel.shadowOffset = CGSizeMake(0, 1);

    // Map (section,row) → flat icon index (chat rows 0-1, manage rows 2-5).
    NSInteger flat = indexPath.section == kMenuSectionChat
        ? indexPath.row
        : kMenuRowChatCount + indexPath.row;
    cell.textLabel.text = [self _titleForFlatIndex:flat];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
    if (flat >= 0 && flat < (NSInteger)[_menuIcons count]) {
        cell.imageView.image = [_menuIcons objectAtIndex:flat];
    }
    return cell;
}

- (NSString *)_titleForFlatIndex:(NSInteger)flat
{
    switch (flat) {
        case 0:  return NSLocalizedString(@"新对话", nil);
        case 1:  return NSLocalizedString(@"历史记录", nil);
        case 2:  return NSLocalizedString(@"模型管理", nil);
        case 3:  return NSLocalizedString(@"角色管理", nil);
        case 4:  return NSLocalizedString(@"日志", nil);
        case 5:  return NSLocalizedString(@"设置", nil);
        default: return @"";
    }
}

#pragma mark - Menu table (delegate)

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == kMenuSectionChat) {
        switch (indexPath.row) {
            case kMenuRowNewChat:
                [self closeSidebarAnimated:YES];
                [self performSelector:@selector(_newChatAfterClose)
                           withObject:nil
                           afterDelay:kAnimDuration + 0.03];
                break;
            case kMenuRowHistory: {
                HistoryViewController *history = [[[HistoryViewController alloc] init] autorelease];
                history.title = NSLocalizedString(@"历史", nil);
                [self pushViewControllerAfterClose:history];
                break;
            }
        }
    } else {
        switch (indexPath.row) {
            case kMenuRowModels: {
                ModelManagementViewController *mm = [[[ModelManagementViewController alloc] init] autorelease];
                [self pushViewControllerAfterClose:mm];
                break;
            }
            case kMenuRowCharacters: {
                CharacterManagementViewController *cm = [[[CharacterManagementViewController alloc] init] autorelease];
                [self pushViewControllerAfterClose:cm];
                break;
            }
            case kMenuRowLogs: {
                LogViewController *lv = [[[LogViewController alloc] init] autorelease];
                [self pushViewControllerAfterClose:lv];
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
}

@end

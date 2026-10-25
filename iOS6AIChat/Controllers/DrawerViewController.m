//
//  DrawerViewController.m
//  iOS6AIChat
//
//  v261025-4 — REMINDERS-STYLE FULL-SCREEN MENU (user decision "选 A",
//  reference screenshots IMG_0442 / IMG_0443).
//
//    The old Path-style left drawer is REPLACED by a full-screen sheet
//    that slides DOWN from the top edge (从上到下全屏). Structure:
//
//      ┌──────────────────────────────┐
//      │ leather top bar  (64pt)      │  ✚ 完成      菜单      新对话 ✚
//      ├──────────────────────────────┤
//      │  recessed search slot        │  搜索对话 (filters the list)
//      │  ┌────────────────────────┐  │
//      │  │ white card rows        │  │  聊天: 新对话 / 历史记录
//      │  │ (grouped, glossy)      │  │  管理: 模型 / 角色 / 日志 / 设置
//      │  └────────────────────────┘  │
//      │  recessed strip + chips      │  最近对话 horizontal scroller
//      └──────────────────────────────┘
//
//    All textures (leather bar, card, slot, chips) are PRE-RENDERED
//    stretchable images cached inside iOS6Theme — no per-frame CG work,
//    which is how this stays smooth on an iPhone 3GS (600 MHz/256 MB).
//
//  Memory model: MRC (matches the rest of the codebase).
//

#import "DrawerViewController.h"
#import "iOS6Theme.h"
#import "IconDrawing.h"
#import "Logger.h"
#import "ConversationStore.h"
#import "ChatViewController.h"
#import "HistoryViewController.h"
#import "SettingsViewController.h"
#import "ModelManagementViewController.h"
#import "CharacterManagementViewController.h"
#import "LogViewController.h"
#import <QuartzCore/QuartzCore.h>

NSString *const DrawerViewControllerToggleNotification = @"DrawerViewControllerToggle";

static NSString *const kMenuCellID = @"MenuSheetCardCell";
static NSString *const kConvCellID  = @"MenuSheetConvCell";

static CGFloat const kSheetAnimDuration = 0.28f;

// Sheet layout (pt).
// v261025-6: kSheetBarH 64 → 50（用户反馈「太宽」）。50 = 状态栏 20 +
// 可见皮革区 30pt，正好放下 30pt 高的按钮 + 标题，不再像 64 时下面留 14pt
// 空白。kSearchY / kTableY 相应上移 14pt，菜单列表多出 14pt 显示内容。
static CGFloat const kSheetBarH     = 50.0f;   // status 20 + nav 30 (compact)
static CGFloat const kSearchY       = 60.0f;   // 50 + 10pt gap
static CGFloat const kSearchH       = 34.0f;
static CGFloat const kTableY        = 102.0f;   // 60 + 34 + 8pt gap
static CGFloat const kRowH          = 42.0f;    // 46→42, slightly more compact
// v261025-5: removed kStripH — the bottom chips strip is gone (user said
// "这也太丑了" + chip text truncated to "你…"); recent conversations
// now live as proper list rows in section 1 of the table.

// Menu model — three sections (search box empty).
// v261025-6: 用户要求把「管理」段放在「最近对话」段前面 — 这样消息多时
// 进设置/模型管理不需要翻过一长串历史。重排后:
//   section 0 = chat (新对话, 1 行)
//   section 1 = manage (模型/角色/日志/设置, 4 行)
//   section 2 = recent (最近对话, 最多 6 行)
enum {
    kMenuSectionChat = 0,        // 新对话
    kMenuSectionManage,          // 模型管理 / 角色管理 / 日志 / 设置
    kMenuSectionRecent,         // 最近对话 — up to kMaxRecent rows of recent convs
    kMenuSectionCount,
    kMenuSectionConv = 0        // search mode: conversation results
};

enum {
    kMenuRowNewChat = 0,
    kMenuRowChatCount = 1,

    kMenuRowModels = 0,
    kMenuRowCharacters = 1,
    kMenuRowLogs = 2,
    kMenuRowSettings = 3,
    kMenuRowExport = 4,         // v261025-6: 导出对话到 JSON
    kMenuRowManageCount = 5     // was 4, now 5 with 导出
};

// v261025-5: cap on recent-conv rows shown in the menu — keeps the
// menu scroll length sane on the iPhone 3GS (320x480 screen).
static NSInteger const kMaxRecent = 6;

@interface DrawerViewController () <UITableViewDataSource, UITableViewDelegate,
                                     UITextFieldDelegate> {
    UINavigationController *_mainNav;

    // Full-screen sheet (slides from above the screen).
    UIView      *_sheetView;
    UIImageView *_sheetBar;        // leather top bar
    UIButton    *_doneButton;
    UIButton    *_newChatButton;
    UILabel     *_sheetTitle;

    // Search.
    UITextField *_searchField;
    UIImageView *_searchSlot;

    // Menu list.
    UITableView *_menuTable;
    NSArray     *_menuIcons;      // re-built on theme change

    // v261025-5: recent conversations displayed as list rows in
    // section kMenuSectionRecent (replaces the bottom chip strip — the
    // user said the chips looked unfinished and the truncated "你…" text
    // was ugly). Snapshot-once-per-open, like the old chip list.
    NSArray     *_recentConversations;

    // Search state.
    NSString    *_searchQuery;    // nil/empty → menu mode
    NSArray     *_searchResults;  // filtered conversations

    UIViewController *_pendingPushVC;  // deferred menu push (v261025-1)
    BOOL         _open;
    UIStatusBarStyle _savedStatusBarStyle;
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

        // The menu toggles itself when ChatViewController posts the
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
    // Cancel the deferred push if the menu is being torn down mid-delay.
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_pendingPushVC release];
    [_mainNav release];
    [_sheetView release];
    [_sheetBar release];
    [_doneButton release];
    [_newChatButton release];
    [_sheetTitle release];
    [_searchField release];
    [_searchSlot release];
    [_menuTable release];
    [_menuIcons release];
    // v261025-5: removed _stripSlot / _stripScroll releases (the chip
    // strip is gone).
    [_recentConversations release];
    [_searchQuery release];
    [_searchResults release];
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
        [self addChildViewController:_mainNav];
        _mainNav.view.frame = self.view.bounds;
        [self.view addSubview:_mainNav.view];
        [_mainNav didMoveToParentViewController:self];
    }
}

- (void)_buildViewHierarchy
{
    self.view.backgroundColor = [UIColor blackColor];

    // --- Main content (child VC, full frame, never moved) --------------
    [self addChildViewController:_mainNav];
    _mainNav.view.frame = self.view.bounds;
    _mainNav.view.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                      UIViewAutoresizingFlexibleHeight);
    [self.view addSubview:_mainNav.view];
    [_mainNav didMoveToParentViewController:self];

    // --- Full-screen menu sheet (parked above the screen) ---------------
    CGFloat W = self.view.bounds.size.width;
    CGFloat H = self.view.bounds.size.height;
    if (H < 200) H = [[UIScreen mainScreen] bounds].size.height;  // bounds-zero guard

    _sheetView = [[UIView alloc] initWithFrame:CGRectMake(0, -H, W, H)];
    _sheetView.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                   UIViewAutoresizingFlexibleHeight);
    _sheetView.backgroundColor = [iOS6Theme pinstripeBackground];
    // One static shadow under the sheet's bottom edge — computed ONCE
    // via shadowPath (never during scrolling), safe for the 3GS.
    _sheetView.layer.shadowColor = [UIColor blackColor].CGColor;
    _sheetView.layer.shadowOpacity = 0.5f;
    _sheetView.layer.shadowRadius = 8.0f;
    _sheetView.layer.shadowOffset = CGSizeMake(0.0f, 6.0f);
    CGPathRef sheetShadow = CGPathCreateWithRect(
        CGRectMake(-10.0f, H - 2.0f, W + 20.0f, 12.0f), NULL);
    _sheetView.layer.shadowPath = sheetShadow;
    CGPathRelease(sheetShadow);
    _sheetView.hidden = YES;
    [self.view addSubview:_sheetView];

    // --- Leather top bar --------------------------------------------------
    _sheetBar = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, W, kSheetBarH)];
    _sheetBar.image = [iOS6Theme menuLeatherBarImage];
    _sheetBar.userInteractionEnabled = YES;
    _sheetBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_sheetView addSubview:_sheetBar];

    // 完成 (Done) — bordered translucent glass bar button, left.
    // v261025-6: 按钮 Y 从 30 → 20 (kSheetBarH=50, status bar 20pt 占据 0-20,
    // 可见皮革区 20-50 共 30pt，按钮高 30pt 恰好填满)。
    _doneButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _doneButton.frame = CGRectMake(8.0f, 20.0f, 64.0f, 30.0f);
    _doneButton.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
    _doneButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_doneButton setTitle:NSLocalizedString(@"完成", nil)
                  forState:UIControlStateNormal];
    [_doneButton setTitleColor:[UIColor whiteColor]
                      forState:UIControlStateNormal];
    [_doneButton setTitleColor:[UIColor colorWithWhite:1.0f alpha:0.55f]
                      forState:UIControlStateHighlighted];
    _doneButton.titleLabel.shadowColor = [UIColor colorWithWhite:0.0f alpha:0.5f];
    _doneButton.titleLabel.shadowOffset = CGSizeMake(0, 1);
    _doneButton.backgroundColor = [UIColor clearColor];
    [_doneButton setBackgroundImage:[self _sheetBarButtonImageOfSize:_doneButton.frame.size]
                          forState:UIControlStateNormal];
    [_doneButton addTarget:self action:@selector(_doneTapped)
          forControlEvents:UIControlEventTouchUpInside];
    [_sheetBar addSubview:_doneButton];

    // 新对话 (New chat) — bordered glass bar button, right.
    // NOTE: plain ASCII "+" — U+271A heavy-cross may lack a glyph in
    // iOS 6 Helvetica; never gamble on exotic codepoints there.
    _newChatButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _newChatButton.frame = CGRectMake(W - 8.0f - 72.0f, 20.0f, 72.0f, 30.0f);
    _newChatButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    _newChatButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_newChatButton setTitle:NSLocalizedString(@"+ 新对话", nil)
                  forState:UIControlStateNormal];
    [_newChatButton setTitleColor:[UIColor whiteColor]
                        forState:UIControlStateNormal];
    [_newChatButton setTitleColor:[UIColor colorWithWhite:1.0f alpha:0.55f]
                        forState:UIControlStateHighlighted];
    _newChatButton.titleLabel.shadowColor = [UIColor colorWithWhite:0.0f alpha:0.5f];
    _newChatButton.titleLabel.shadowOffset = CGSizeMake(0, 1);
    _newChatButton.backgroundColor = [UIColor clearColor];
    [_newChatButton setBackgroundImage:[self _sheetBarButtonImageOfSize:_newChatButton.frame.size]
                          forState:UIControlStateNormal];
    [_newChatButton addTarget:self action:@selector(_newChatTapped)
          forControlEvents:UIControlEventTouchUpInside];
    [_sheetBar addSubview:_newChatButton];

    // Centered embossed title.
    _sheetTitle = [[UILabel alloc] initWithFrame:CGRectMake(80, 20, W - 160, 30)];
    _sheetTitle.text = NSLocalizedString(@"菜单", nil);
    _sheetTitle.textAlignment = NSTextAlignmentCenter;
    _sheetTitle.font = [UIFont boldSystemFontOfSize:19];
    _sheetTitle.backgroundColor = [UIColor clearColor];
    _sheetTitle.textColor = [UIColor whiteColor];
    _sheetTitle.shadowColor = [UIColor colorWithWhite:0.0f alpha:0.65f];
    _sheetTitle.shadowOffset = CGSizeMake(0, 1);
    _sheetTitle.autoresizingMask = (UIViewAutoresizingFlexibleLeftMargin |
                                    UIViewAutoresizingFlexibleRightMargin);
    [_sheetBar addSubview:_sheetTitle];

    // --- Search slot -------------------------------------------------------
    _searchSlot = [[UIImageView alloc] initWithFrame:CGRectMake(10, kSearchY, W - 20, kSearchH)];
    _searchSlot.image = [iOS6Theme stretchableRecessedSlotImage];
    _searchSlot.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_sheetView addSubview:_searchSlot];

    _searchField = [[UITextField alloc] initWithFrame:CGRectMake(14, kSearchY + 4, W - 28, kSearchH - 8)];
    _searchField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _searchField.backgroundColor = [UIColor clearColor];
    _searchField.font = [UIFont systemFontOfSize:15];
    _searchField.placeholder = NSLocalizedString(@"搜索对话…", nil);
    _searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _searchField.returnKeyType = UIReturnKeySearch;
    _searchField.autocorrectionType = UITextAutocorrectionTypeNo;
    _searchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _searchField.delegate = self;
    [_sheetView addSubview:_searchField];

    // --- Menu table (white cards on pinstripe) -----------------------------
    // v261025-5: table now fills ALL the space below the search slot down
    // to the sheet bottom — the bottom chips strip is gone, so there's no
    // reserved strip zone anymore.
    CGFloat tableH = H - kTableY;
    if (tableH < 120) tableH = 120;   // tiny-screen guard
    _menuTable = [[UITableView alloc] initWithFrame:CGRectMake(0, kTableY, W, tableH)
                                             style:UITableViewStyleGrouped];
    _menuTable.dataSource = self;
    _menuTable.delegate = self;
    _menuTable.backgroundColor = [UIColor clearColor];
    _menuTable.backgroundView = nil;
    _menuTable.opaque = NO;
    _menuTable.rowHeight = kRowH;
    _menuTable.separatorStyle = UITableViewCellSeparatorStyleNone;   // cards carry their own edges
    _menuTable.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                   UIViewAutoresizingFlexibleHeight);
    [_sheetView addSubview:_menuTable];

    // Theme-dependent colors + icons.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_themeChanged)
                                                 name:@"iOS6ThemeDidChangeNotification"
                                               object:nil];

    [self _styleSheet];
}

// Bordered translucent-glass bar button for the leather bar. Dark glass
// with a light hairline — matches the graphite bar in BOTH themes
// (the sheet's bar is always graphite, Reminders reference).
- (UIImage *)_sheetBarButtonImageOfSize:(CGSize)size
{
    if (size.width < 4 || size.height < 4) return nil;
    CGFloat scale = [UIScreen mainScreen].scale;
    if (scale < 1) scale = 1;
    UIGraphicsBeginImageContextWithOptions(size, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }
    CGFloat r = 5.0f;
    CGRect rect = CGRectMake(0.5f, 0.5f, size.width - 1.0f, size.height - 1.0f);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:r];

    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path.CGPath);
    CGContextClip(ctx);
    [iOS6Theme drawLinearGradientInRect:rect context:ctx
        topColor:[iOS6Theme colorWithHex:@"#5E5E66"]
        bottomColor:[iOS6Theme colorWithHex:@"#2E2E34"]];
    [iOS6Theme drawGlossInRect:CGRectMake(0, 0, size.width, size.height * 0.5f)
                        context:ctx];
    CGContextRestoreGState(ctx);

    // Light hairline border + inner top highlight.
    CGContextSetStrokeColorWithColor(ctx, [iOS6Theme colorWithHex:@"#8A8A92"].CGColor);
    CGContextSetLineWidth(ctx, 1.0f);
    CGContextAddPath(ctx, path.CGPath);
    CGContextStrokePath(ctx);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0f alpha:0.35f].CGColor);
    CGContextMoveToPoint(ctx, 3, 1.5f);
    CGContextAddLineToPoint(ctx, size.width - 3, 1.5f);
    CGContextStrokePath(ctx);

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;   // autoreleased; drawn once per button creation
}

- (void)_styleSheet
{
    if (!_sheetView || !_menuTable || !_searchField || !_sheetTitle) {
        NSLog(@"[MenuSheet] _styleSheet: missing subview — skip");
        return;
    }
    _sheetView.backgroundColor = [iOS6Theme pinstripeBackground];
    _sheetBar.image = [iOS6Theme menuLeatherBarImage];
    _searchSlot.image = [iOS6Theme stretchableRecessedSlotImage];
    // v261025-5: _stripSlot removed (chips strip gone).

    _searchField.textColor = [iOS6Theme textColor];
    _searchField.placeholder = NSLocalizedString(@"搜索对话…", nil);

    // Menu icons tinted with the saturated selected-blue.
    // v261025-5: removed the clock icon (历史记录 menu row is gone —
    // search + recent-conv list covers that use case). Re-added a
    // dedicated "recent" icon (clock — now used as the section header
    // icon for kMenuSectionRecent, NOT as a row icon) so the icon array
    // stays 1-indexed with the manage-section rows.
    // v261025-6: added IconTypeExport at flat 5 (导出对话).
    UIColor *iconColor = [iOS6Theme tabBarSelectedTintColor];
    // Flat icon order matches the new flat title index (see
    // _titleForFlatIndex: 0=新对话, 1=模型管理, 2=角色管理, 3=日志, 4=设置, 5=导出).
    NSArray *types = [NSArray arrayWithObjects:
                      [NSNumber numberWithInt:IconTypeChatBubble],   // 0 新对话
                      [NSNumber numberWithInt:IconTypeLayers],       // 1 模型管理
                      [NSNumber numberWithInt:IconTypePerson],       // 2 角色管理
                      [NSNumber numberWithInt:IconTypeDoc],          // 3 日志
                      [NSNumber numberWithInt:IconTypeGear],        // 4 设置
                      [NSNumber numberWithInt:IconTypeExport],      // 5 导出
                      nil];
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
    [self _rebuildRecentList];
}

#pragma mark - Theme / toggle notifications

- (void)_themeChanged
{
    [self _styleSheet];
}

- (void)_onToggleRequest
{
    [self toggleSidebar];
}

#pragma mark - Open / close (slide DOWN from the top edge)

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
    _sheetView.hidden = NO;
    // v261025-5: refresh the recent-conv snapshot every open + reload the
    // table so the new snapshot shows up in section kMenuSectionRecent.
    [self _rebuildRecentList];
    [_menuTable reloadData];
    // White status text over the graphite leather bar (iOS 6 global
    // status style — saved so close can restore the pre-open look).
    _savedStatusBarStyle = [UIApplication sharedApplication].statusBarStyle;
    [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleBlackOpaque
                                                animated:NO];
    CGFloat H = _sheetView.bounds.size.height;
    if (H < 200) H = [[UIScreen mainScreen] bounds].size.height;
    // (CI fix: the 4-arg animateWithDuration:delay:options:animations:
    // variant does NOT exist — completion: is mandatory.)
    [UIView animateWithDuration:kSheetAnimDuration
                          delay:0.0f
                        options:(UIViewAnimationOptionCurveEaseInOut |
                                 UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{
        _sheetView.frame = CGRectMake(0, 0, self.view.bounds.size.width, H);
    }
                     completion:nil];
}

- (void)closeSidebarAnimated:(BOOL)animated
{
    if (!_open) return;
    _open = NO;
    // Restore the status bar FIRST so it settles while the sheet slides
    // up over it.
    [[UIApplication sharedApplication] setStatusBarStyle:_savedStatusBarStyle
                                                animated:NO];
    // Drop the keyboard if the search field was focused.
    [_searchField resignFirstResponder];
    CGFloat H = _sheetView.bounds.size.height;
    if (H < 200) H = [[UIScreen mainScreen] bounds].size.height;
    void (^slide)(void) = ^{
        _sheetView.frame = CGRectMake(0, -H, self.view.bounds.size.width, H);
    };
    void (^after)(BOOL) = ^(BOOL finished) {
        if (!_open) _sheetView.hidden = YES;
    };
    if (animated) {
        [UIView animateWithDuration:kSheetAnimDuration
                              delay:0.0f
                            options:(UIViewAnimationOptionCurveEaseInOut |
                                     UIViewAnimationOptionBeginFromCurrentState)
                         animations:slide
                         completion:after];
    } else {
        slide();
        _sheetView.hidden = YES;
    }
}

- (void)_doneTapped
{
    [self closeSidebarAnimated:YES];
}

- (void)_newChatTapped
{
    [self closeSidebarAnimated:YES];
    [self performSelector:@selector(_newChatAfterClose)
               withObject:nil
               afterDelay:kSheetAnimDuration + 0.03];
}

#pragma mark - Deferred push (v261025-1 navigation fix, preserved)

- (void)pushViewControllerAfterClose:(UIViewController *)vc
{
    [self closeSidebarAnimated:YES];
    // Push once the sheet has slid back up — concurrent push + slide
    // animations look chaotic.
    [self performSelector:@selector(_pushNow:) withObject:vc
               afterDelay:kSheetAnimDuration + 0.03];
}

- (void)_pushNow:(UIViewController *)vc
{
    // v261025-1: iOS 6 UINavigationController BUG — popToRootViewControllerAnimated:
    // followed by pushViewController:animated: in the SAME runloop tick
    // corrupts the container's transition state ("nested pop animation"
    // / bar never appears / SIGSEGV inside UINavigationItem layout). The
    // old code did exactly that. Fix: pop without animation AND defer the
    // push to the next runloop turn so the container completes its layout
    // pass in between.
    if (!vc) return;
    if ([_mainNav.viewControllers count] > 1) {
        [_mainNav popToRootViewControllerAnimated:NO];
    }
    // Hold the VC ourselves; the afterDelay retains self, not the VC.
    if (_pendingPushVC != vc) {
        [_pendingPushVC release];
        _pendingPushVC = [vc retain];
    }
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                              selector:@selector(_deferredPushNow)
                                                object:nil];
    [self performSelector:@selector(_deferredPushNow)
               withObject:nil
               afterDelay:0.05];
}

- (void)_deferredPushNow
{
    UIViewController *vc = _pendingPushVC;
    if (!vc) return;
    // Defensive: the menu only ever pushes from the chat root. If the
    // stack somehow grew in between, collapse it first (no animation,
    // then push animated on THIS tick — never pop+push same tick).
    if ([_mainNav.viewControllers count] > 1) {
        [_mainNav popToRootViewControllerAnimated:NO];
    }
    [_mainNav pushViewController:vc animated:YES];
    [_pendingPushVC release];
    _pendingPushVC = nil;
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

// v261025-5: the chip-tap handler `_openConversationAfterClose:` is gone;
// its replacement `_openRecentConvAfterClose:` lives in the
// "Recent-conversations list" section below (same deferred-open behaviour).

#pragma mark - Recent-conversations list (v261025-5 — replaces chips strip)

// Rebuild the snapshot of recent conversations shown in section
// kMenuSectionRecent. Called once per sheet open + once on theme change.
// The list is bounded by kMaxRecent (6) to keep the menu scroll length
// sane on a 320x480 3GS screen.
- (void)_rebuildRecentList
{
    NSArray *convs = [[ConversationStore sharedStore] conversations];
    NSMutableArray *usable = [NSMutableArray arrayWithCapacity:[convs count]];
    for (Conversation *c in convs) {
        if ([c isKindOfClass:[Conversation class]] && [c.messages count] > 0) {
            [usable addObject:c];
        }
    }
    if ([usable count] > kMaxRecent) {
        usable = [[[usable subarrayWithRange:NSMakeRange(0, kMaxRecent)] copy] autorelease];
    }
    [_recentConversations release];
    _recentConversations = [usable retain];
}

- (NSString *)_relativeDateString:(NSDate *)date
{
    if (!date) return @"";
    NSTimeInterval delta = -[date timeIntervalSinceNow];
    if (delta < 60.0)         return @"刚刚";
    if (delta < 3600.0)       return [NSString stringWithFormat:@"%.0f分钟前", delta / 60.0];
    if (delta < 86400.0)      return [NSString stringWithFormat:@"%.0f小时前", delta / 3600.0];
    if (delta < 86400.0 * 7)  return [NSString stringWithFormat:@"%.0f天前", delta / 86400.0];
    NSDateFormatter *df = [[[NSDateFormatter alloc] init] autorelease];
    [df setDateFormat:@"MM-dd"];
    return [df stringFromDate:date];
}

// Tap on a recent-conv row → close the sheet, then load that conversation
// in the root ChatVC. Same deferred-open pattern as the old chip code.
- (void)_openRecentConvAfterClose:(NSNumber *)convIndex
{
    NSInteger idx = convIndex ? [convIndex integerValue] : -1;
    if (idx < 0 || idx >= (NSInteger)[_recentConversations count]) return;
    Conversation *conv = [_recentConversations objectAtIndex:idx];
    if (!conv) return;
    ChatViewController *chat = nil;
    if ([_mainNav.viewControllers count] > 0) {
        chat = [_mainNav.viewControllers objectAtIndex:0];
    }
    if ([chat isKindOfClass:[ChatViewController class]] && conv.conversationID) {
        [[Logger sharedLogger] info:[NSString stringWithFormat:@"MenuSheet recent → conversation %d", (int)idx]];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ChatViewControllerDidLoadConversationNotification
                          object:nil
                        userInfo:@{ChatViewControllerConversationIDKey: conv.conversationID}];
    }
}

#pragma mark - Search (filters conversations)

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    return YES;
}

- (BOOL)textField:(UITextField *)textField
shouldChangeCharactersInRange:(NSRange)range
replacementString:(NSString *)string
{
    NSString *next = [textField.text stringByReplacingCharactersInRange:range
                                                             withString:string];
    [self _applySearchQuery:next];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    [self _applySearchQuery:textField.text];
}

- (void)_applySearchQuery:(NSString *)query
{
    NSString *trimmed = [query stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL changed = YES;
    if ([trimmed isEqualToString:(_searchQuery ?: @"")]) changed = NO;

    if (trimmed.length == 0) {
        if ([_searchQuery length] > 0 || _searchResults) {
            [_searchQuery release];
            _searchQuery = nil;
            [_searchResults release];
            _searchResults = nil;
            changed = YES;
        } else {
            changed = NO;
        }
    } else if (changed) {
        [_searchQuery release];
        _searchQuery = [trimmed retain];
        // Filter by title AND last message content (case-insensitive).
        NSArray *convs = [[ConversationStore sharedStore] conversations];
        NSMutableArray *hits = [NSMutableArray arrayWithCapacity:16];
        NSString *lower = [trimmed lowercaseString];
        for (Conversation *c in convs) {
            if (![c isKindOfClass:[Conversation class]]) continue;
            NSString *hay = [NSString stringWithFormat:@"%@ %@",
                             (c.displayTitle ?: @""),
                             ([[c lastMessage] content] ?: @"")];
            if ([hay.lowercaseString rangeOfString:lower].location != NSNotFound) {
                [hits addObject:c];
            }
            if ([hits count] >= 20) break;   // cap for 3GS
        }
        [_searchResults release];
        _searchResults = [hits retain];
        changed = YES;
    }
    if (changed) {
        [_menuTable reloadData];
        // v261025-6 BUG FIX: 当搜索结果为空时，section 0 的 numberOfRowsInSection
        // 返回 0。调用 scrollToRowAtIndexPath:atScrollPosition:animated: 指向一个
        // 不存在的 row 0 会让 iOS 6 内部抛 NSInternalInconsistencyException —
        // 这是 "两次对话必闪退" 类报告的一个隐藏来源（用户搜索后切换/返回
        // 触发）。先 bounds-check，无可滚动行就只滚到顶部偏移即可。
        NSInteger visibleRows = 0;
        if (_searchQuery.length > 0) {
            visibleRows = (NSInteger)[_searchResults count];
        } else {
            visibleRows = kMenuRowChatCount
                          + (NSInteger)[_recentConversations count]
                          + kMenuRowManageCount;
        }
        if (visibleRows > 0 &&
            [_menuTable respondsToSelector:@selector(scrollToRowAtIndexPath:atScrollPosition:animated:)]) {
            [_menuTable scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]
                            atScrollPosition:UITableViewScrollPositionTop
                                    animated:NO];
        } else {
            // 空结果 — 仅把 contentOffset 拉回顶部，不调用 row 路径。
            [_menuTable setContentOffset:CGPointMake(0, -_menuTable.contentInset.top)
                               animated:NO];
        }
    }
}

#pragma mark - Card cell background (white Reminders-style cards)

// One-off setup (cell creation): a CLEAR container as backgroundView
// with the card image inside, inset 1.5pt top/bottom so adjacent rows
// read as separate physical cards instead of butting rounded corners.
- (void)_installCardBackgroundOnCell:(UITableViewCell *)cell
{
    if (!cell) return;
    UIView *container = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
    container.backgroundColor = [UIColor clearColor];
    container.clipsToBounds = NO;
    UIImageView *cardImg = [[[UIImageView alloc] initWithFrame:CGRectZero] autorelease];
    cardImg.tag = 777;
    [container addSubview:cardImg];
    cell.backgroundView = container;
}

// Per-configure refresh (theme colors are baked into the cached card
// image, so re-pointing the image is all it takes).
- (void)_applyCardBackgroundOnCell:(UITableViewCell *)cell
                         tableView:(UITableView *)tableView
{
    if (!cell || !cell.backgroundView) return;
    UIImageView *cardImg = (UIImageView *)[cell.backgroundView viewWithTag:777];
    if (![cardImg isKindOfClass:[UIImageView class]]) return;
    cardImg.image = [iOS6Theme stretchableCardBackgroundImage];
    if (!cardImg.image) {
        // Fallback: flat grouped fill.
        cell.backgroundView.backgroundColor = [iOS6Theme isDarkMode]
            ? [iOS6Theme colorWithHex:@"#26262A"]
            : [UIColor whiteColor];
        return;
    }
    CGFloat w = cell.backgroundView.bounds.size.width;
    if (w < 50) w = tableView.bounds.size.width - 20.0f;
    if (w < 50) w = [UIScreen mainScreen].bounds.size.width - 20.0f;
    cardImg.frame = CGRectMake(0, 1.5f, w, kRowH - 3.0f);
}

#pragma mark - Menu table (data source)

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return (_searchQuery.length > 0) ? 1 : kMenuSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (_searchQuery.length > 0) {
        return (NSInteger)[_searchResults count];
    }
    // v261025-6: section 顺序重排后:
    //   0 = chat (新对话, 1 行)
    //   1 = manage (模型/角色/日志/设置, 4 行)
    //   2 = recent (最近对话, 0..kMaxRecent 行)
    if (section == kMenuSectionChat)    return kMenuRowChatCount;
    if (section == kMenuSectionManage)  return kMenuRowManageCount;
    return (NSInteger)[_recentConversations count];  // kMenuSectionRecent
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (_searchQuery.length > 0) {
        return NSLocalizedString(@"对话搜索结果", nil);
    }
    if (section == kMenuSectionChat) {
        return NSLocalizedString(@"聊天", nil);
    }
    if (section == kMenuSectionManage) {
        return NSLocalizedString(@"管理", nil);
    }
    // kMenuSectionRecent — hide the section header entirely when there are
    // no recent convs (otherwise we'd get an orphan "最近对话" header floating
    // above the manage section on a fresh install).
    if ([_recentConversations count] == 0) return @"";
    return NSLocalizedString(@"最近对话", nil);
}

- (UITableViewCell *)tableView:(UITableView *)tableView
          cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    // Search mode → conversation rows (subtitle cell: title + last message).
    if (_searchQuery.length > 0) {
        Conversation *conv = nil;
        if (indexPath.row < (NSInteger)[_searchResults count]) {
            conv = [_searchResults objectAtIndex:indexPath.row];
        }
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kConvCellID];
        if (!cell) {
            cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                       reuseIdentifier:kConvCellID] autorelease];
            [self _installCardBackgroundOnCell:cell];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        }
        [self _applyCardBackgroundOnCell:cell tableView:tableView];
        cell.textLabel.text = conv.displayTitle ?: @"(无标题)";
        cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
        cell.textLabel.textColor = [iOS6Theme textColor];
        cell.detailTextLabel.text = [conv.lastMessage content] ?: @"";
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [iOS6Theme secondaryTextColor];
        return cell;
    }

    // v261025-5: section kMenuSectionRecent — recent conversation row
    // (also subtitle cell: title + relative date).
    if (indexPath.section == kMenuSectionRecent) {
        Conversation *conv = nil;
        if (indexPath.row < (NSInteger)[_recentConversations count]) {
            conv = [_recentConversations objectAtIndex:indexPath.row];
        }
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kConvCellID];
        if (!cell) {
            cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                       reuseIdentifier:kConvCellID] autorelease];
            [self _installCardBackgroundOnCell:cell];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        }
        [self _applyCardBackgroundOnCell:cell tableView:tableView];
        cell.textLabel.text = conv.displayTitle ?: @"(无标题)";
        cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
        cell.textLabel.textColor = [iOS6Theme textColor];
        cell.textLabel.shadowColor = [iOS6Theme isDarkMode]
            ? [UIColor colorWithWhite:0.0f alpha:0.35f]
            : [UIColor colorWithWhite:1.0f alpha:0.9f];
        cell.textLabel.shadowOffset = CGSizeMake(0, 1);
        cell.detailTextLabel.text = [self _relativeDateString:conv.updatedAt];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [iOS6Theme secondaryTextColor];
        // Clock icon for recent rows — same tinted tone as the menu icons.
        // Drawn per-call but IconDrawing caches internally so it's cheap.
        cell.imageView.image = [IconDrawing imageForType:IconTypeClock
                                                    size:CGSizeMake(26, 26)
                                                   color:[iOS6Theme tabBarSelectedTintColor]];
        return cell;
    }

    // Normal menu mode (chat section + manage section).
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kMenuCellID];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:kMenuCellID] autorelease];
        [self _installCardBackgroundOnCell:cell];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    }
    [self _applyCardBackgroundOnCell:cell tableView:tableView];
    cell.textLabel.textColor = [iOS6Theme textColor];
    cell.textLabel.shadowColor = [iOS6Theme isDarkMode]
        ? [UIColor colorWithWhite:0.0f alpha:0.35f]
        : [UIColor colorWithWhite:1.0f alpha:0.9f];
    cell.textLabel.shadowOffset = CGSizeMake(0, 1);

    // v261025-5: flat index — chat section row 0 → flat 0 (新对话);
    // manage section row N → flat N+1 (because chat section is just 1
    // row now, no historical "历史记录" row).
    NSInteger flat;
    if (indexPath.section == kMenuSectionChat) {
        flat = indexPath.row;            // 0 → 新对话
    } else {
        flat = indexPath.row + 1;        // 0 → 模型管理, 1 → 角色管理, …
    }
    cell.textLabel.text = [self _titleForFlatIndex:flat];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
    if (flat >= 0 && flat < (NSInteger)[_menuIcons count]) {
        cell.imageView.image = [_menuIcons objectAtIndex:flat];
    }
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView
heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return kRowH;
}

- (NSString *)_titleForFlatIndex:(NSInteger)flat
{
    // v261025-6: renumbered — 历史记录 menu row is gone (search covers it).
    // 0=新对话, 1=模型管理, 2=角色管理, 3=日志, 4=设置, 5=导出对话
    switch (flat) {
        case 0:  return NSLocalizedString(@"新对话", nil);
        case 1:  return NSLocalizedString(@"模型管理", nil);
        case 2:  return NSLocalizedString(@"角色管理", nil);
        case 3:  return NSLocalizedString(@"日志", nil);
        case 4:  return NSLocalizedString(@"设置", nil);
        case 5:  return NSLocalizedString(@"导出对话", nil);
        default: return @"";
    }
}

#pragma mark - Menu table (delegate)

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    // Search mode → open that conversation.
    if (_searchQuery.length > 0) {
        Conversation *conv = nil;
        if (indexPath.row < (NSInteger)[_searchResults count]) {
            conv = [_searchResults objectAtIndex:indexPath.row];
        }
        if (conv.conversationID) {
            [[Logger sharedLogger] info:@"MenuSheet search result → conversation"];
            [self closeSidebarAnimated:YES];
            [self performSelector:@selector(_openConversationByIDAfterClose:)
                       withObject:conv.conversationID
                       afterDelay:kSheetAnimDuration + 0.05];
        }
        return;
    }

    // v261025-5: section kMenuSectionRecent → load that conversation in
    // the root ChatVC (no separate HistoryVC push — the menu IS the
    // history list now).
    if (indexPath.section == kMenuSectionRecent) {
        if (indexPath.row < 0 || indexPath.row >= (NSInteger)[_recentConversations count]) return;
        [[Logger sharedLogger] info:[NSString stringWithFormat:@"MenuSheet recent → row %d", (int)indexPath.row]];
        [self closeSidebarAnimated:YES];
        [self performSelector:@selector(_openRecentConvAfterClose:)
                   withObject:[NSNumber numberWithInteger:indexPath.row]
                   afterDelay:kSheetAnimDuration + 0.05];
        return;
    }

    // v261025-1: one log line per menu navigation — every jump traceable.
    NSInteger flat;
    if (indexPath.section == kMenuSectionChat) {
        flat = indexPath.row;
    } else {
        flat = indexPath.row + 1;   // manage rows start at flat 1 now
    }
    [[Logger sharedLogger] info:[NSString stringWithFormat:@"MenuSheet → %@",
                                  [self _titleForFlatIndex:flat]]];
    if (indexPath.section == kMenuSectionChat) {
        if (indexPath.row == kMenuRowNewChat) {
            [self _newChatTapped];
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
            case kMenuRowExport: {
                // v261025-6: 导出全部对话到 Documents 目录的 JSON 文件。
                // UIFileSharingEnabled=true 在 Info.plist 里已开启，用户可通过
                // iTunes/Finder 文件共享访问。
                [self closeSidebarAnimated:YES];
                [self performSelector:@selector(_exportConversationsAfterClose)
                           withObject:nil
                           afterDelay:kSheetAnimDuration + 0.05];
                break;
            }
        }
    }
}

- (void)_openConversationByIDAfterClose:(NSString *)convID
{
    if (!convID) return;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ChatViewControllerDidLoadConversationNotification
                      object:nil
                    userInfo:@{ChatViewControllerConversationIDKey: convID}];
}

#pragma mark - v261025-6 Export conversations to JSON

// Serialize all conversations to a JSON file in the app's Documents directory.
// File name: iOS6AIChat-export-YYYY-MM-DD-HHmmss.json (timestamp to avoid
// overwriting previous exports).
// UIFileSharingEnabled=true (in Info.plist) lets the user grab this file
// via iTunes/Finder File Sharing panel and import on another device or
// inspect on a desktop.
- (void)_exportConversationsAfterClose
{
    NSArray *convs = [[ConversationStore sharedStore] conversations];
    NSMutableArray *outArr = [NSMutableArray arrayWithCapacity:[convs count]];
    for (Conversation *c in convs) {
        if (![c isKindOfClass:[Conversation class]]) continue;
        NSMutableArray *msgsArr = [NSMutableArray arrayWithCapacity:[c.messages count]];
        for (Message *m in c.messages) {
            if (![m isKindOfClass:[Message class]]) continue;
            // v261025-6: include variants if present.
            NSMutableArray *variantsArr = [NSMutableArray array];
            if ([m.variants isKindOfClass:[NSArray class]]) {
                for (NSDictionary *v in m.variants) {
                    if (![v isKindOfClass:[NSDictionary class]]) continue;
                    [variantsArr addObject:@{
                        @"content":  [v objectForKey:@"content"]  ?: @"",
                        @"thinking": [v objectForKey:@"thinking"] ?: @""
                    }];
                }
            }
            NSDictionary *msgDict = @{
                @"role":      [NSNumber numberWithInteger:(NSInteger)m.role],
                @"content":   m.content ?: @"",
                @"thinking":  m.thinking  ?: @"",
                @"createdAt": [m.createdAt description] ?: @"",
                @"messageID": m.messageID ?: @"",
                @"variants":  variantsArr,
                @"currentVariantIndex": [NSNumber numberWithInteger:(NSInteger)m.currentVariantIndex]
            };
            [msgsArr addObject:msgDict];
        }
        [outArr addObject:@{
            @"id":          c.conversationID ?: @"",
            @"title":       c.title ?: @"",
            @"createdAt":   [c.createdAt description] ?: @"",
            @"updatedAt":   [c.updatedAt description] ?: @"",
            @"messages":    msgsArr
        }];
    }
    NSError *jsonErr = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:outArr
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&jsonErr];
    if (jsonErr || !data) {
        UIAlertView *fail = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"导出失败", nil)
                  message:[NSString stringWithFormat:@"JSON 序列化错误: %@", jsonErr.localizedDescription ?: @"unknown"]
                 delegate:nil
        cancelButtonTitle:NSLocalizedString(@"好", nil)
        otherButtonTitles:nil] autorelease];
        [fail show];
        return;
    }
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    NSDateFormatter *tsFmt = [[[NSDateFormatter alloc] init] autorelease];
    [tsFmt setDateFormat:@"yyyy-MM-dd-HHmmss"];
    NSString *ts = [tsFmt stringFromDate:[NSDate date]];
    NSString *filename = [NSString stringWithFormat:@"iOS6AIChat-export-%@.json", ts];
    NSString *path = [docs stringByAppendingPathComponent:filename];
    NSError *writeErr = nil;
    BOOL ok = [data writeToFile:path options:NSDataWritingAtomic error:&writeErr];
    if (!ok) {
        UIAlertView *fail = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"导出失败", nil)
                  message:[NSString stringWithFormat:@"写入文件错误: %@", writeErr.localizedDescription ?: @"unknown"]
                 delegate:nil
        cancelButtonTitle:NSLocalizedString(@"好", nil)
        otherButtonTitles:nil] autorelease];
        [fail show];
        return;
    }
    NSString *msg = [NSString stringWithFormat:
        NSLocalizedString(@"已导出 %d 个对话到\n%@\n\n通过 iTunes/Finder 文件共享可访问。", nil),
        (int)[outArr count], filename];
    UIAlertView *ok2 = [[[UIAlertView alloc]
        initWithTitle:NSLocalizedString(@"导出成功", nil)
              message:msg
             delegate:nil
    cancelButtonTitle:NSLocalizedString(@"好", nil)
    otherButtonTitles:nil] autorelease];
    [ok2 show];
    [[Logger sharedLogger] info:[NSString stringWithFormat:@"Exported %lu conversations to %@", (unsigned long)[outArr count], path]];
}

@end

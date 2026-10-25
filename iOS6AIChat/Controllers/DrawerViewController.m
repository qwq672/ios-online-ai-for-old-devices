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
static CGFloat const kSheetBarH     = 64.0f;   // status 20 + nav 44
static CGFloat const kSearchY       = 74.0f;
static CGFloat const kSearchH       = 36.0f;
static CGFloat const kTableY        = 118.0f;
static CGFloat const kStripH        = 94.0f;   // bottom recent strip zone
static CGFloat const kRowH          = 46.0f;

// Menu model — two sections (search box empty).
enum {
    kMenuSectionChat = 0,      // 新对话 / 历史记录
    kMenuSectionManage,        // 模型管理 / 角色管理 / 日志 / 设置
    kMenuSectionCount,
    kMenuSectionConv = 0       // search mode: conversation results
};

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

    // Recent-conversations strip.
    UIImageView *_stripSlot;
    UIScrollView *_stripScroll;
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
    [_stripSlot release];
    [_stripScroll release];
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
    _doneButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _doneButton.frame = CGRectMake(8.0f, 30.0f, 64.0f, 30.0f);
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
    _newChatButton.frame = CGRectMake(W - 8.0f - 72.0f, 30.0f, 72.0f, 30.0f);
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
    _sheetTitle = [[UILabel alloc] initWithFrame:CGRectMake(80, 30, W - 160, 30)];
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
    CGFloat tableH = H - kTableY - kStripH;
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

    // --- Recent-conversations strip -----------------------------------------
    _stripSlot = [[UIImageView alloc] initWithFrame:CGRectMake(10, H - kStripH + 8, W - 20, kStripH - 16)];
    _stripSlot.image = [iOS6Theme stretchableRecessedSlotImage];
    _stripSlot.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                   UIViewAutoresizingFlexibleTopMargin);
    [_sheetView addSubview:_stripSlot];

    _stripScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(14, H - kStripH + 12, W - 28, kStripH - 24)];
    _stripScroll.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                     UIViewAutoresizingFlexibleTopMargin);
    _stripScroll.showsHorizontalScrollIndicator = NO;
    _stripScroll.showsVerticalScrollIndicator = NO;
    _stripScroll.alwaysBounceHorizontal = NO;
    [_sheetView addSubview:_stripScroll];

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
    _stripSlot.image = [iOS6Theme stretchableRecessedSlotImage];

    _searchField.textColor = [iOS6Theme textColor];
    _searchField.placeholder = NSLocalizedString(@"搜索对话…", nil);

    // Menu icons tinted with the saturated selected-blue (unchanged from
    // the old drawer — user liked that tone on menu icons).
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
    [self _rebuildRecentStrip];
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
    // Fresh recent-conversations every open (chips are cheap views, and
    // the list may have changed since the last open).
    [self _rebuildRecentStrip];
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

// Chip tap → close, then switch the root chat to that conversation.
- (void)_openConversationAfterClose:(NSNumber *)convIndex
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
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ChatViewControllerDidLoadConversationNotification
                          object:nil
                        userInfo:@{ChatViewControllerConversationIDKey: conv.conversationID}];
    }
}

#pragma mark - Recent-conversations strip (Reminders date-strip style)

- (void)_rebuildRecentStrip
{
    if (!_stripScroll) return;
    // v261025-2 crash class: NEVER mutate subviews while iterating the
    // live array — snapshot first, then tear down. (The old drawer's
    // SIGSEGV family came from exactly this pattern.)
    NSArray *oldChips = [[_stripScroll subviews] copy];
    for (UIView *v in oldChips) {
        [v removeFromSuperview];
    }
    [oldChips release];
    NSArray *convs = [[ConversationStore sharedStore] conversations];
    // Skip a tail-only current conversation: the first entry is usually
    // the just-created empty chat — no value as a chip.
    NSMutableArray *usable = [NSMutableArray arrayWithCapacity:[convs count]];
    for (Conversation *c in convs) {
        if ([c isKindOfClass:[Conversation class]] && [c.messages count] > 0) {
            [usable addObject:c];
        }
    }
    if ([usable count] > 10) {
        usable = [[[usable subarrayWithRange:NSMakeRange(0, 10)] copy] autorelease];
    }
    [_recentConversations release];
    _recentConversations = [usable retain];

    CGFloat chipW = 96.0f, chipH = 56.0f, gap = 8.0f;
    CGFloat x = 0.0f;
    UIImage *chipBg = [iOS6Theme stretchableGlassChipImage];
    NSInteger idx = 0;
    for (Conversation *c in _recentConversations) {
        if (![c isKindOfClass:[Conversation class]]) { idx++; continue; }

        UIButton *chip = [UIButton buttonWithType:UIButtonTypeCustom];
        chip.frame = CGRectMake(x, 2.0f, chipW, chipH);
        if (chipBg) {
            [chip setBackgroundImage:chipBg forState:UIControlStateNormal];
        }
        chip.tag = 1000 + idx;
        // Two-line attributed title: truncated title + relative date.
        NSString *title = c.displayTitle ?: @"(无标题)";
        if ([title length] > 12) {
            title = [[title substringToIndex:12] stringByAppendingString:@"…"];
        }
        NSMutableParagraphStyle *para = [[[NSMutableParagraphStyle alloc] init] autorelease];
        para.lineBreakMode = NSLineBreakByTruncatingTail;
        para.alignment = NSTextAlignmentCenter;
        NSDictionary *line1 = @{NSFontAttributeName: [UIFont boldSystemFontOfSize:11],
                                NSForegroundColorAttributeName: [iOS6Theme textColor],
                                NSParagraphStyleAttributeName: para};
        NSDictionary *line2 = @{NSFontAttributeName: [UIFont systemFontOfSize:9],
                                NSForegroundColorAttributeName: [iOS6Theme secondaryTextColor],
                                NSParagraphStyleAttributeName: para};
        NSString *dateStr = [self _relativeDateString:c.updatedAt];
        NSMutableAttributedString *ts = [[[NSMutableAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"%@\n%@", title, dateStr]
            attributes:line1] autorelease];
        if ([dateStr length] > 0 && [dateStr length] <= [ts length]) {
            [ts addAttributes:line2
                        range:NSMakeRange([ts length] - [dateStr length],
                                          [dateStr length])];
        }
        [chip setAttributedTitle:ts forState:UIControlStateNormal];
        chip.titleLabel.numberOfLines = 2;
        chip.titleLabel.textAlignment = NSTextAlignmentCenter;
        [chip addTarget:self action:@selector(_chipTapped:)
      forControlEvents:UIControlEventTouchUpInside];
        [_stripScroll addSubview:chip];
        x += chipW + gap;
        idx++;
    }
    _stripScroll.contentSize = CGSizeMake(MAX(x - gap, 1.0f), chipH + 4.0f);
    _stripScroll.contentOffset = CGPointZero;
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

- (void)_chipTapped:(UIButton *)sender
{
    NSInteger idx = sender.tag - 1000;
    if (idx < 0 || idx >= (NSInteger)[_recentConversations count]) return;
    [[Logger sharedLogger] info:[NSString stringWithFormat:@"MenuSheet chip → conversation %d", (int)idx]];
    [self closeSidebarAnimated:YES];
    // Let the slide-up finish before the chat swaps content underneath.
    [self performSelector:@selector(_openConversationAfterClose:)
               withObject:[NSNumber numberWithInteger:idx]
               afterDelay:kSheetAnimDuration + 0.05];
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
        // Scroll the (possibly filtered) list back to the top.
        if ([_menuTable respondsToSelector:@selector(scrollToRowAtIndexPath:atScrollPosition:animated:)]) {
            [_menuTable scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]
                            atScrollPosition:UITableViewScrollPositionTop
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
    if (section == kMenuSectionChat) return kMenuRowChatCount;
    return kMenuRowManageCount;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (_searchQuery.length > 0) {
        return NSLocalizedString(@"对话搜索结果", nil);
    }
    if (section == kMenuSectionChat) {
        return NSLocalizedString(@"聊天", nil);
    }
    return NSLocalizedString(@"管理", nil);
}

- (UITableViewCell *)tableView:(UITableView *)tableView
          cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    // Search mode → conversation rows.
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

    // Normal menu mode.
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

    // Map (section,row) → flat icon index (chat rows 0-1, manage rows 2-5).
    NSInteger flat = indexPath.section == kMenuSectionChat
        ? indexPath.row
        : kMenuRowChatCount + indexPath.row;
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

    // v261025-1: one log line per menu navigation — every jump traceable.
    NSInteger flat = indexPath.section == kMenuSectionChat
        ? indexPath.row
        : kMenuRowChatCount + indexPath.row;
    [[Logger sharedLogger] info:[NSString stringWithFormat:@"MenuSheet → %@",
                                  [self _titleForFlatIndex:flat]]];
    if (indexPath.section == kMenuSectionChat) {
        switch (indexPath.row) {
            case kMenuRowNewChat:
                [self _newChatTapped];
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

- (void)_openConversationByIDAfterClose:(NSString *)convID
{
    if (!convID) return;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ChatViewControllerDidLoadConversationNotification
                      object:nil
                    userInfo:@{ChatViewControllerConversationIDKey: convID}];
}

@end

//
//  HistoryViewController.m
//  iOS6AIChat
//
//  v261024-15 nav restructure (Plan 2 = iOS "Messages" app style):
//    This is now the App's HOME. Conversation list with:
//       - Top-left: Edit (delete-mode toggle)
//       - Top-right: + (new chat → push ChatViewController)
//       - Table footer: "⚙️ 管理" button → push ManagementViewController
//    Tapping a row pushes a fresh ChatViewController and loadConversation.
//
//  The old notification-based loadConversation path is no longer used
//  (Plan 2 rootVC is now the history list, not a fresh chat).
//

#import "HistoryViewController.h"
#import "ConversationStore.h"
#import "iOS6Theme.h"
#import "ChatViewController.h"
#import "ManagementViewController.h"
#import "Logger.h"
#import <QuartzCore/QuartzCore.h>

static NSString *const kCellReuseID = @"HistoryCell";

@interface HistoryViewController () {
    NSString *_searchText;
}
@end

@implementation HistoryViewController

@synthesize tableView=_tableView, editButton=_editButton;

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if (self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil]) {
        self.title = NSLocalizedString(@"AI 聊天", nil);
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    // v261024-17: wrap the WHOLE viewDidLoad in @try/@catch.
    // Previously, a single bad call here (Logger init failure,
    // QuartzCore layer.cornerRadius on a missing CALayer ref,
    // UISearchBar barStyle on an unexpected state, etc.) would
    // crash the app at launch and the user would see nothing —
    // they'd report "主页没有导航栏 / 一进主页就闪退". With @try
    // here, even if a sub-step throws, we fall back to a plain
    // (unstyled) table + nav bar instead of killing the app.
    @try {
        [[Logger sharedLogger] info:@"HistoryViewController viewDidLoad"];
        self.view.backgroundColor = [iOS6Theme pinstripeBackground];

        // Use the full bounds — the nav controller's container view already
        // sizes the VC's view to fit below the navbar.
        CGRect frame = self.view.bounds;
        // v261024-17: bounds may be CGRectZero at very first viewDidLoad
        // (the window hasn't sized the rootVC view yet on iOS 6 in some
        // launch orderings). Fall back to screen bounds — the table view's
        // autoresizingMask will re-fit it once the parent sizes us.
        if (frame.size.width < 100 || frame.size.height < 100) {
            frame = [[UIScreen mainScreen] bounds];
        }
        _tableView = [[UITableView alloc] initWithFrame:frame style:UITableViewStyleGrouped];
        _tableView.dataSource = self;
        _tableView.delegate = self;
        _tableView.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                        UIViewAutoresizingFlexibleHeight);
        // Make the table view transparent so the parent's pinstripe shows
        // through between cells (otherwise we get a bright default background
        // bleeding through and the theme looks broken).
        _tableView.backgroundColor = [UIColor clearColor];
        _tableView.backgroundView = nil;  // remove iOS 6 default striped pattern
        _tableView.opaque = NO;
        [self.view addSubview:_tableView];

        // Search bar for filtering conversations.
        UISearchBar *searchBar = [[[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)] autorelease];
        searchBar.placeholder = NSLocalizedString(@"搜索对话", nil);
        searchBar.delegate = self;
        // Dark mode search bar styling: on iOS 6 UISearchBar has limited
        // customization. We set barStyle to UIBarStyleBlack which makes the
        // search field background dark, and tintColor to the theme accent.
        if ([iOS6Theme isDarkMode]) {
            searchBar.barStyle = UIBarStyleBlack;
            searchBar.tintColor = [iOS6Theme tintColor];
        } else {
            searchBar.barStyle = UIBarStyleDefault;
            searchBar.tintColor = [iOS6Theme tintColor];
        }
        _tableView.tableHeaderView = searchBar;

        // Edit button on the left (iOS Messages home style), + on the right.
        self.navigationItem.leftBarButtonItem = self.editButtonItem;
        self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
                                                     initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                     target:self
                                                     action:@selector(startNewConversation)] autorelease];

        // Table footer: "⚙️ 管理" button — entry point into ManagementViewController
        // (设置 / 模型管理 / 角色管理 / 日志). Stays anchored to the bottom of the
        // table content so it scrolls with the list when the list is long.
        [self _installManagementFooter];

        // Listen for theme changes.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_themeChanged)
                                                     name:@"iOS6ThemeDidChangeNotification"
                                                       object:nil];
    } @catch (NSException *e) {
        // Last-resort fallback: at least show the table + nav buttons so
        // the user can still create a new conversation. Without this they'd
        // see a black screen and report "no nav bar / crash".
        NSLog(@"[HistoryVC] viewDidLoad crashed: %@ — %@", e.name, e.reason);
        if (!_tableView) {
            _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
            _tableView.dataSource = self;
            _tableView.delegate = self;
            _tableView.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                            UIViewAutoresizingFlexibleHeight);
            [self.view addSubview:_tableView];
        }
        if (!self.navigationItem.rightBarButtonItem) {
            self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
                initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                target:self action:@selector(startNewConversation)] autorelease];
        }
        if (!self.navigationItem.leftBarButtonItem) {
            self.navigationItem.leftBarButtonItem = self.editButtonItem;
        }
    }
}

- (void)_installManagementFooter
{
    // v261024-17: defensive — CALayer.cornerRadius access on iOS 6
    // sometimes crashes if the layer's been torn down mid-theme-switch.
    // The footer is non-critical (just an entry-point button); skip on
    // failure rather than killing the launch.
    @try {
        CGFloat footerH = 56.0f;
        UIView *footer = [[[UIView alloc] initWithFrame:CGRectMake(0, 0,
                                                                    self.view.bounds.size.width,
                                                                    footerH)] autorelease];
        footer.backgroundColor = [UIColor clearColor];

        // A sub-button styled like a grouped-table cell, centered in the footer.
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(12, 6, self.view.bounds.size.width - 24, footerH - 12);
        btn.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        btn.backgroundColor = [iOS6Theme bubbleAssistantColor];
        btn.layer.cornerRadius = 8.0f;
        btn.layer.masksToBounds = YES;
        [btn setTitle:NSLocalizedString(@"⚙️ 管理", nil)
             forState:UIControlStateNormal];
        [btn setTitleColor:[iOS6Theme textColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
        [btn addTarget:self action:@selector(_openManagement)
          forControlEvents:UIControlEventTouchUpInside];
        [footer addSubview:btn];
        _tableView.tableFooterView = footer;
    } @catch (NSException *e) {
        NSLog(@"[HistoryVC] _installManagementFooter crashed: %@ — %@", e.name, e.reason);
    }
}

- (void)_openManagement
{
    ManagementViewController *mvc = [[[ManagementViewController alloc] initWithNibName:nil bundle:nil] autorelease];
    [self.navigationController pushViewController:mvc animated:YES];
}

- (void)_themeChanged
{
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;
    [_tableView reloadData];
    [self _installManagementFooter];
    // Re-style search bar.
    UISearchBar *sb = (UISearchBar *)_tableView.tableHeaderView;
    if ([sb isKindOfClass:[UISearchBar class]]) {
        if ([iOS6Theme isDarkMode]) {
            sb.barStyle = UIBarStyleBlack;
        } else {
            sb.barStyle = UIBarStyleDefault;
        }
        sb.tintColor = [iOS6Theme tintColor];
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // v261024-18 Plan-1: HistoryVC is PUSHED from the drawer menu onto the
    // chat nav stack — the navbar is naturally visible. The previous
    // explicit [nav setNavigationBarHidden:NO] (v261024-17) is REMOVED:
    // touching the bar's hidden state around appear/layout transitions
    // corrupts the container geometry on iOS 6 (bar invisible + touches
    // dead + watchdog kill — exactly the user's crash report).
    //
    // Re-apply theme in case it changed in Settings.
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    if (_tableView) {
        _tableView.backgroundColor = [UIColor clearColor];
        _tableView.backgroundView = nil;
        [self _installManagementFooter];
        [_tableView reloadData];
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    // Drop a quick log so we can trace the launch sequence in the log file.
    NSUInteger n = [[ConversationStore sharedStore].conversations count];
    [[Logger sharedLogger] info:[NSString stringWithFormat:@"HistoryVC viewDidAppear — %lu conversations", (unsigned long)n]];
}

#pragma mark - New chat (right-bar + button)

- (void)startNewConversation
{
    // v261024-18 Plan-1: HistoryVC lives on the chat nav stack (pushed
    // from the drawer menu). "+" pops back to the chat root and asks it
    // to start a fresh conversation in place. The deferred call is safe:
    // ChatVC's startNewConversation does NO navigation (it only swaps the
    // conversation + reloads), so there's no animation-interval race.
    [[Logger sharedLogger] info:@"HistoryVC startNewConversation → pop to chat root"];
    UINavigationController *nav = self.navigationController;
    if (!nav || [nav.viewControllers count] == 0) {
        // Defensive: no stack — shouldn't happen in Plan 1.
        return;
    }
    UIViewController *root = [nav.viewControllers objectAtIndex:0];
    [nav popToRootViewControllerAnimated:YES];
    if ([root isKindOfClass:[ChatViewController class]]) {
        [root performSelector:@selector(startNewConversation)
                   withObject:nil
                   afterDelay:0.35];
    }
}

#pragma mark - UISearchBarDelegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    [_searchText release];
    _searchText = [searchText copy];
    [_tableView reloadData];
}

- (void)searchBarSearchBarButtonClicked:(UISearchBar *)searchBar
{
    [searchBar resignFirstResponder];
}

#pragma mark - Table data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (_searchText && _searchText.length > 0) {
        NSInteger cnt = 0;
        for (Conversation *conv in [ConversationStore sharedStore].conversations) {
            if ([conv.displayTitle rangeOfString:_searchText options:NSCaseInsensitiveSearch].location != NSNotFound) cnt++;
        }
        return cnt;
    }
    return (NSInteger)[[ConversationStore sharedStore].conversations count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
              cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellReuseID];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                       reuseIdentifier:kCellReuseID] autorelease];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    // Reset theme on reuse.
    cell.backgroundColor = [iOS6Theme bubbleAssistantColor];
    cell.textLabel.textColor = [iOS6Theme textColor];
    cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
    cell.detailTextLabel.textColor = [iOS6Theme secondaryTextColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:12]];

    NSArray *allConvs = [ConversationStore sharedStore].conversations;
    Conversation *c;
    if (_searchText && _searchText.length > 0) {
        NSMutableArray *filtered = [NSMutableArray array];
        for (Conversation *conv in allConvs) {
            if ([conv.displayTitle rangeOfString:_searchText options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [filtered addObject:conv];
            }
        }
        if ((NSInteger)[filtered count] <= indexPath.row) return cell;
        c = [filtered objectAtIndex:indexPath.row];
    } else {
        if ((NSInteger)[allConvs count] <= indexPath.row) return cell;
        c = [allConvs objectAtIndex:indexPath.row];
    }
    cell.textLabel.text = [c displayTitle];
    NSDateFormatter *df = [[[NSDateFormatter alloc] init] autorelease];
    [df setDateFormat: @"yyyy-MM-dd HH:mm"];
    cell.detailTextLabel.text = [df stringFromDate:c.updatedAt];
    return cell;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    if (!title || title.length == 0) return nil;
    UIView *header = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 30)] autorelease];
    header.backgroundColor = [UIColor clearColor];
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectMake(16, 8, tableView.bounds.size.width - 32, 20)] autorelease];
    label.text = title;
    label.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:13]];
    label.textColor = [iOS6Theme secondaryTextColor];
    label.backgroundColor = [UIColor clearColor];
    label.shadowColor = nil;
    label.shadowOffset = CGSizeZero;
    [header addSubview:label];
    return header;
}

- (NSString *)tableView:(UITableView *)tableView
titleForHeaderInSection:(NSInteger)section
{
    NSInteger n = [[ConversationStore sharedStore].conversations count];
    if (n == 0) return NSLocalizedString(@"暂无历史会话", nil);
    return [NSString stringWithFormat:NSLocalizedString(@"共 %d 个会话", nil), (int)n];
}

#pragma mark - Table delegate

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray *allConvs = [ConversationStore sharedStore].conversations;
    Conversation *c;
    if (_searchText && _searchText.length > 0) {
        NSMutableArray *filtered = [NSMutableArray array];
        for (Conversation *conv in allConvs) {
            if ([conv.displayTitle rangeOfString:_searchText options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [filtered addObject:conv];
            }
        }
        if ((NSInteger)[filtered count] <= indexPath.row) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            return;
        }
        c = [filtered objectAtIndex:indexPath.row];
    } else {
        if ((NSInteger)[allConvs count] <= indexPath.row) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            return;
        }
        c = [allConvs objectAtIndex:indexPath.row];
    }
    // Plan 1 (v261024-18): push a fresh ChatViewController and tell it which
    // conversation to load. Direct call, simpler and traceable.
    ChatViewController *chat = [[[ChatViewController alloc] initWithNibName:nil bundle:nil] autorelease];
    [self.navigationController pushViewController:chat animated:YES];
    @try {
        [chat loadConversation:c];
    } @catch (NSException *e) {
        [[Logger sharedLogger] error:[NSString stringWithFormat:@"loadConversation crashed: %@", e]];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        if (indexPath.row < (NSInteger)[[ConversationStore sharedStore].conversations count]) {
            Conversation *c = [[ConversationStore sharedStore].conversations
                                objectAtIndex:indexPath.row];
            [[ConversationStore sharedStore] deleteConversationWithID:c.conversationID];
            [tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath]
                             withRowAnimation:UITableViewRowAnimationLeft];
            [[Logger sharedLogger] info:[NSString stringWithFormat:@"Deleted conversation %@", c.conversationID]];
        }
    }
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_tableView release];
    [_editButton release];
    [_searchText release];
    [super dealloc];
}

@end

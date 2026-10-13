//
//  HistoryViewController.m
//  iOS6AIChat
//
//  Grouped table listing every saved Conversation in the store.
//  Tapping a row:
//     - Posts ChatViewControllerDidLoadConversationNotification
//     - Switches to the Chat tab (index 0)
//

#import "HistoryViewController.h"
#import "ConversationStore.h"
#import "iOS6Theme.h"
#import "ChatViewController.h"

static NSString *const kCellReuseID = @"HistoryCell";

@interface HistoryViewController ()
@end

@implementation HistoryViewController

@synthesize tableView=_tableView, editButton=_editButton;

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if (self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil]) {
        self.title = NSLocalizedString(@"History", nil);
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];

    // Use the full bounds — the nav controller's container view already
    // sizes the VC's view to fit below the navbar.
    CGRect frame = self.view.bounds;
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

    self.navigationItem.rightBarButtonItem = self.editButtonItem;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // Re-apply theme in case it changed in Settings.
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;  // remove iOS 6 default striped pattern
    // Re-style navbar with current palette (dark/light).
    // Tab bar icons are set once at launch — do NOT re-style here
    // (styleNavigationController resets tabBarItem to system icon)
    [_tableView reloadData];
}

#pragma mark - Table data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
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
    Conversation *c = [[[ConversationStore sharedStore].conversations
                          objectAtIndex:indexPath.row] retain];
    cell.textLabel.text       = [c displayTitle];
    NSDateFormatter *df = [[[NSDateFormatter alloc] init] autorelease];
    [df setDateFormat: @"yyyy-MM-dd HH:mm"];
    cell.detailTextLabel.text = [df stringFromDate:c.updatedAt];
    [c release];
    return cell;
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
    Conversation *c = [[ConversationStore sharedStore].conversations objectAtIndex:indexPath.row];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ChatViewControllerDidLoadConversationNotification
                      object:nil
                    userInfo:@{ ChatViewControllerConversationIDKey: c.conversationID }];
    // Switch to chat tab.
    UITabBarController *tbc = (UITabBarController *)self.tabBarController;
    if ([tbc isKindOfClass:[UITabBarController class]]) {
        tbc.selectedIndex = 0;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        Conversation *c = [[ConversationStore sharedStore].conversations
                            objectAtIndex:indexPath.row];
        [[ConversationStore sharedStore] deleteConversationWithID:c.conversationID];
        [tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath]
                         withRowAnimation:UITableViewRowAnimationLeft];
    }
}

- (void)dealloc
{
    [_tableView release];
    [_editButton release];
    [super dealloc];
}

@end

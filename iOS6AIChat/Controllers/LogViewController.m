//
//  LogViewController.m
//  iOS6AIChat
//
//  v261024-15: scrollable in-app log viewer + on/off toggle + clear button.
//    Listens for iOS6LoggerDidWriteNotification so the view live-updates
//    as new log lines come in (this is the most useful when reproducing
//    a crash — watch the last few lines just before the app died).
//

#import "LogViewController.h"
#import "iOS6Theme.h"
#import "Logger.h"

@interface LogViewController ()
@property (nonatomic, retain) UITextView *logView;
@end

@implementation LogViewController

@synthesize tableView=_tableView, logView=_logView;

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if (self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil]) {
        self.title = NSLocalizedString(@"日志", nil);
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_tableView release];
    [_logView release];
    [super dealloc];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    CGRect frame = self.view.bounds;
    _tableView = [[UITableView alloc] initWithFrame:frame style:UITableViewStyleGrouped];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                    UIViewAutoresizingFlexibleHeight);
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;
    _tableView.opaque = NO;
    [self.view addSubview:_tableView];

    // Live-refresh on new log writes.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_logDidWrite)
                                                 name:iOS6LoggerDidWriteNotification
                                                   object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_themeChanged)
                                                 name:@"iOS6ThemeDidChangeNotification"
                                                   object:nil];
}

- (void)_themeChanged
{
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;
    _logView.backgroundColor = [iOS6Theme codeBackgroundColor];
    _logView.textColor = [iOS6Theme textColor];
    [_tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;
    [_tableView reloadData];
}

- (void)_logDidWrite
{
    // Reload — but throttle to avoid spamming the main thread during
    // heavy logging bursts (e.g. SSE streaming chunks fire many writes).
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                            selector:@selector(_reloadLog)
                                              object:nil];
    [self performSelector:@selector(_reloadLog) withObject:nil afterDelay:0.4];
}

- (void)_reloadLog
{
    NSString *text = [[Logger sharedLogger] readAllLog];
    // Cap at last 80KB so we don't choke the text view on huge logs.
    if (text.length > 80000) {
        text = [NSString stringWithFormat:@"%@…\n(truncated — full log: %@)",
                [text substringFromIndex:text.length - 80000],
                [[Logger sharedLogger] logFilePath]];
    }
    _logView.text = text;
    // Scroll to bottom so newest entries are visible.
    NSRange rng = NSMakeRange(text.length - 1, 1);
    if (text.length > 0 && [self.logView respondsToSelector:@selector(scrollRangeToVisible:)]) {
        [self.logView scrollRangeToVisible:rng];
    }
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 3;  // toggle, clear, path
    return 1;  // log content
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return NSLocalizedString(@"控制", nil);
    return NSLocalizedString(@"日志内容", nil);
}

// v261025-7: custom TRANSPARENT header views (dark-mode white-bar fix).
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    return [iOS6Theme groupedSectionHeaderViewWithTitle:title
                                                  width:tableView.bounds.size.width];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    return (title.length > 0) ? 26.0f : 8.0f;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 1) {
        // Log view cell — fill the rest of the screen.
        CGFloat totalH = self.view.bounds.size.height;
        // Subtract approx space taken by section 0 (3 rows × 44 + footer/header).
        CGFloat used = 3 * 44 + 80;
        CGFloat h = totalH - used;
        return h > 200 ? h : 300;
    }
    return 44;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *kID = @"LogCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kID];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:kID] autorelease];
    }
    // v261025-2: snapshot subviews — see CharacterManagementVC for the
    // full root-cause writeup. Mutating subviews while iterating it is
    // SIGSEGV on cctools-port armv7.
    NSArray *oldSubviews = [cell.contentView.subviews copy];
    for (UIView *v in oldSubviews) [v removeFromSuperview];
    [oldSubviews release];
    cell.backgroundColor = [iOS6Theme bubbleAssistantColor];
    // v261025-7: explicit CLEAR label background (dark-mode white-plate fix).
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.textLabel.opaque = NO;
    cell.textLabel.text = @"";
    cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
    cell.textLabel.textColor = [iOS6Theme textColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            // Toggle.
            UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, 200, 44)];
            l.text = NSLocalizedString(@"启用日志", nil);
            l.backgroundColor = [UIColor clearColor];
            l.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
            l.textColor = [iOS6Theme textColor];
            [cell.contentView addSubview:l];
            [l release];
            UISwitch *sw = [[[UISwitch alloc] init] autorelease];
            [sw setOn:[[Logger sharedLogger] isEnabled] animated:NO];
            [sw addTarget:self action:@selector(_toggleLog:)
              forControlEvents:UIControlEventValueChanged];
            sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            CGRect f = cell.contentView.bounds;
            sw.frame = CGRectMake(f.size.width - 79 - 12, (44 - 27) / 2, 79, 27);
            [cell.contentView addSubview:sw];
        } else if (indexPath.row == 1) {
            // Clear button.
            cell.textLabel.text = NSLocalizedString(@"清空日志", nil);
            cell.textLabel.textColor = [iOS6Theme tintColor];
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        } else if (indexPath.row == 2) {
            // Path display.
            cell.textLabel.text = [[Logger sharedLogger] logFilePath];
            cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:11]];
            cell.textLabel.textColor = [iOS6Theme secondaryTextColor];
            cell.textLabel.numberOfLines = 2;
        }
    } else {
        // Log content cell — embed a UITextView for selection + scroll.
        if (!_logView) {
            _logView = [[UITextView alloc] initWithFrame:CGRectZero];
            _logView.editable = NO;
            _logView.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:11]];
            _logView.backgroundColor = [iOS6Theme codeBackgroundColor];
            _logView.textColor = [iOS6Theme textColor];
            _logView.alwaysBounceVertical = YES;
        }
        _logView.frame = cell.contentView.bounds;
        _logView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [cell.contentView addSubview:_logView];
        [self _reloadLog];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0 && indexPath.row == 1) {
        // Clear.
        [[Logger sharedLogger] clearLog];
        [self _reloadLog];
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    }
}

- (IBAction)_toggleLog:(UISwitch *)sw
{
    [[Logger sharedLogger] setEnabled:sw.on];
    // If just turned ON, log it for visibility.
    if (sw.on) [[Logger sharedLogger] info:@"Logging enabled by user"];
}

@end

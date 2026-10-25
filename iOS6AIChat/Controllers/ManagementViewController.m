//
//  ManagementViewController.m
//  iOS6AIChat
//

#import "ManagementViewController.h"
#import "iOS6Theme.h"
#import "SettingsViewController.h"
#import "ModelManagementViewController.h"
#import "CharacterManagementViewController.h"
#import "LogViewController.h"
#import "Logger.h"

enum {
    kMgmtSectionConfig = 0,   // 设置
    kMgmtSectionTools,       // 模型管理 / 角色管理 / 日志
    kMgmtSectionCount
};

@interface ManagementViewController ()
@end

@implementation ManagementViewController

@synthesize tableView=_tableView;

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if (self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil]) {
        self.title = NSLocalizedString(@"管理", nil);
    }
    return self;
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

#pragma mark - Table data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kMgmtSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == kMgmtSectionConfig) return 1;
    return 3;  // 模型 / 角色 / 日志
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == kMgmtSectionConfig) return NSLocalizedString(@"配置", nil);
    return NSLocalizedString(@"工具", nil);
}

- (UITableViewCell *)tableView:(UITableView *)tableView
              cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *kID = @"MgmtCell";
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
    cell.textLabel.textColor = [iOS6Theme textColor];
    cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.text = @"";

    if (indexPath.section == kMgmtSectionConfig) {
        cell.textLabel.text = NSLocalizedString(@"设置", nil);
        cell.imageView.image = nil;
    } else {
        switch (indexPath.row) {
            case 0: cell.textLabel.text = NSLocalizedString(@"模型管理", nil); break;
            case 1: cell.textLabel.text = NSLocalizedString(@"角色管理", nil); break;
            case 2: cell.textLabel.text = NSLocalizedString(@"日志", nil); break;
        }
    }
    return cell;
}

#pragma mark - Table delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    UIViewController *vc = nil;
    if (indexPath.section == kMgmtSectionConfig) {
        vc = [[[SettingsViewController alloc] initWithNibName:nil bundle:nil] autorelease];
    } else {
        switch (indexPath.row) {
            case 0: vc = [[[ModelManagementViewController alloc] initWithNibName:nil bundle:nil] autorelease]; break;
            case 1: vc = [[[CharacterManagementViewController alloc] initWithNibName:nil bundle:nil] autorelease]; break;
            case 2: vc = [[[LogViewController alloc] initWithNibName:nil bundle:nil] autorelease]; break;
        }
    }
    if (vc) [self.navigationController pushViewController:vc animated:YES];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_tableView release];
    [super dealloc];
}

@end

//
//  ModelManagementViewController.m
//  iOS6AIChat
//
//  v261024-15: independent model management page.
//    Sections:
//      0) 当前默认模型 + 搜索 /v1/models 按钮
//      1) 已保存模型列表 (tap = 设为默认, swipe = 删除)
//      2) 添加新模型 (alert 输入)
//      3) 能力开关 (支持图片识别 / 支持思考)
//

#import "ModelManagementViewController.h"
#import "iOS6Theme.h"
#import "SettingsViewController.h"
#import "NetworkService.h"
#import "Logger.h"
#import <QuartzCore/QuartzCore.h>

static NSString *const kCellReuseID = @"ModelMgmtCell";

enum {
    kMMSectionCurrent = 0,   // 当前默认 + 搜索
    kMMSectionList,          // 已保存列表
    kMMSectionAdd,           // 添加新模型
    kMMSectionCaps,          // 能力开关
    kMMSectionCount
};

@interface ModelManagementViewController () {
    NSMutableArray *_availableModels;   // for /v1/models search action sheet
    NSString *_pendingAddModel;          // for tag-300 alert (add model)
    NSString *_pendingDeleteModel;       // for tag-700 alert (confirm delete)
}
@end

@implementation ModelManagementViewController

@synthesize tableView=_tableView, availableModels=_availableModels;

#pragma mark - Model list persistence (class helpers)

// Pull the saved list from NSUserDefaults. Returns the JSON array, or the
// provider defaults on first launch / corrupt storage.
+ (NSArray *)savedModelList
{
    NSString *json = [[NSUserDefaults standardUserDefaults]
                       stringForKey:SettingsKeyModelList];
    NSString *provider = [[NSUserDefaults standardUserDefaults]
                            stringForKey:SettingsKeyProvider] ?: ProviderIDOpenAI;
    NSArray *seed = [SettingsViewController _defaultModelListForProvider:provider];
    if (!json || json.length == 0) {
        // Seed.
        [self saveModelList:seed];
        return seed;
    }
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data
                                                   options:0
                                                     error:&err];
    if (err || ![arr isKindOfClass:[NSArray class]] || [arr count] == 0) {
        [self saveModelList:seed];
        return seed;
    }
    NSMutableArray *out = [NSMutableArray array];
    for (id e in arr) {
        if ([e isKindOfClass:[NSString class]] && [(NSString *)e length] > 0) {
            [out addObject:e];
        }
    }
    if ([out count] == 0) {
        [self saveModelList:seed];
        return seed;
    }
    return out;
}

+ (void)saveModelList:(NSArray *)list
{
    NSMutableArray *seen = [NSMutableArray array];
    for (NSString *m in list) {
        if (![seen containsObject:m]) [seen addObject:m];
    }
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:seen
                                                    options:0
                                                      error:&err];
    if (err || !data) {
        NSString *csv = [seen componentsJoinedByString:@","];
        [[NSUserDefaults standardUserDefaults] setObject:csv
                                                  forKey:SettingsKeyModelList];
    } else {
        NSString *json = [[[NSString alloc] initWithData:data
                                                encoding:NSUTF8StringEncoding] autorelease];
        [[NSUserDefaults standardUserDefaults] setObject:json
                                                  forKey:SettingsKeyModelList];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (void)addModel:(NSString *)model
{
    if (!model || model.length == 0) return;
    NSArray *cur = [self savedModelList];
    if ([cur containsObject:model]) return;
    NSMutableArray *arr = [NSMutableArray arrayWithArray:cur];
    [arr addObject:model];
    [self saveModelList:arr];
}

+ (void)removeModel:(NSString *)model
{
    if (!model || model.length == 0) return;
    NSArray *cur = [self savedModelList];
    NSMutableArray *arr = [NSMutableArray array];
    for (NSString *m in cur) {
        if (![m isEqualToString:model]) [arr addObject:m];
    }
    [self saveModelList:arr];
}

#pragma mark - Lifecycle

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if (self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil]) {
        self.title = NSLocalizedString(@"模型管理", nil);
        _availableModels = [[NSMutableArray array] retain];
    }
    return self;
}

- (void)dealloc
{
    [_tableView release];
    [_availableModels release];
    [_pendingAddModel release];
    [_pendingDeleteModel release];
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
    return kMMSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case kMMSectionCurrent: return 1;     // 显示当前默认 + 搜索按钮
        case kMMSectionList:   return (NSInteger)[[ModelManagementViewController savedModelList] count];
        case kMMSectionAdd:    return 1;
        case kMMSectionCaps:   return 2;       // 图片识别 / 思考
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case kMMSectionCurrent: return NSLocalizedString(@"当前默认模型", nil);
        case kMMSectionList:    return NSLocalizedString(@"已保存模型", nil);
        case kMMSectionAdd:     return NSLocalizedString(@"添加", nil);
        case kMMSectionCaps:    return NSLocalizedString(@"能力（应用到所有模型）", nil);
        default: return @"";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    switch (section) {
        case kMMSectionCurrent:
            return NSLocalizedString(@"点行从 /v1/models 拉取可选用模型。", nil);
        case kMMSectionList:
            return NSLocalizedString(@"点模型设为默认；右滑或编辑模式可删除。删当前默认会自动 fallback 到列表第一项。", nil);
        case kMMSectionAdd:
            return NSLocalizedString(@"弹出输入框,任意填入模型名(如 gpt-4o)。", nil);
        case kMMSectionCaps:
            return NSLocalizedString(@"开关会附加到所有 AI 请求,决定是否携带图片/思考参数。", nil);
        default: return @"";
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
              cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellReuseID];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:kCellReuseID] autorelease];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];
    cell.backgroundColor = [iOS6Theme bubbleAssistantColor];
    cell.textLabel.text = @"";
    cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
    cell.textLabel.textColor = [iOS6Theme textColor];
    cell.textLabel.textAlignment = NSTextAlignmentLeft;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    switch (indexPath.section) {
        case kMMSectionCurrent: {
            // Show current default model name + 搜索 button on the right.
            NSString *def = [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyModel];
            if (!def) def = @"(unset)";
            cell.textLabel.text = def ?: @"(unset)";

            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            [btn setTitle:NSLocalizedString(@"搜索", nil) forState:UIControlStateNormal];
            [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:13]];
            btn.backgroundColor = [iOS6Theme tintColor];
            btn.layer.cornerRadius = 6.0f;
            btn.layer.masksToBounds = YES;
            CGRect f = cell.contentView.bounds;
            btn.frame = CGRectMake(f.size.width - 76 - 12, (44 - 28) / 2, 76, 28);
            btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            [btn addTarget:self action:@selector(_searchAvailableModels)
              forControlEvents:UIControlEventTouchUpInside];
            [cell.contentView addSubview:btn];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case kMMSectionList: {
            NSArray *list = [ModelManagementViewController savedModelList];
            if (indexPath.row >= (NSInteger)[list count]) return cell;
            NSString *m = [list objectAtIndex:indexPath.row];
            cell.textLabel.text = m;
            // Checkmark if this is the current default.
            NSString *def = [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyModel];
            if (def && [def isEqualToString:m]) {
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
            } else {
                cell.accessoryType = UITableViewCellAccessoryNone;
            }
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            break;
        }
        case kMMSectionAdd:
            cell.textLabel.text = NSLocalizedString(@"+ 添加模型", nil);
            cell.textLabel.textColor = [iOS6Theme tintColor];
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            break;
        case kMMSectionCaps: {
            // Build toggle cells (one per capability).
            NSString *label;
            NSString *key;
            if (indexPath.row == 0) {
                label = NSLocalizedString(@"支持图片识别", nil);
                key = SettingsKeyModelSupportsImages;
            } else {
                label = NSLocalizedString(@"支持思考", nil);
                key = SettingsKeyModelSupportsThinking;
            }
            UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, 160, 44)];
            l.text = label;
            l.backgroundColor = [UIColor clearColor];
            l.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
            l.textColor = [iOS6Theme textColor];
            l.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
            [cell.contentView addSubview:l];
            [l release];

            UISwitch *sw = [[[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 79, 27)] autorelease];
            BOOL on = [[NSUserDefaults standardUserDefaults] boolForKey:key];
            [sw setOn:on animated:NO];
            sw.tag = indexPath.row == 0 ? 100 : 101;
            [sw addTarget:self action:@selector(_capToggleChanged:)
              forControlEvents:UIControlEventValueChanged];
            sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            CGRect f = cell.contentView.bounds;
            sw.frame = CGRectMake(f.size.width - 79 - 12, (44 - 27) / 2, 79, 27);
            [cell.contentView addSubview:sw];
            break;
        }
    }
    return cell;
}

- (IBAction)_capToggleChanged:(UISwitch *)sw
{
    NSString *key = sw.tag == 100 ? SettingsKeyModelSupportsImages : SettingsKeyModelSupportsThinking;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[Logger sharedLogger] info:[NSString stringWithFormat:@"capability %@ = %@", key, sw.on ? @"ON" : @"OFF"]];
    if (sw.tag == 100) {
        // Image support affects ComposerView — broadcast theme change.
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"iOS6ThemeDidChangeNotification" object:nil];
    }
}

#pragma mark - Table delegate

- (BOOL)tableView:(UITableView *)tableView
canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == kMMSectionList;
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle == UITableViewCellEditingStyleDelete &&
        indexPath.section == kMMSectionList) {
        NSArray *list = [ModelManagementViewController savedModelList];
        if (indexPath.row >= (NSInteger)[list count]) return;
        NSString *toDel = [list objectAtIndex:indexPath.row];
        // Confirm before deletion (tag 700 alert).
        UIAlertView *av = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"删除模型?", nil)
                  message:[NSString stringWithFormat:@"%@ \"%@\"", NSLocalizedString(@"确定从列表删除", nil), toDel]
                 delegate:self
        cancelButtonTitle:NSLocalizedString(@"取消", nil)
        otherButtonTitles:NSLocalizedString(@"删除", nil), nil] autorelease];
        [av setTag:700];
        self.pendingDeleteModel = toDel;
        [av show];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kMMSectionList) {
        NSArray *list = [ModelManagementViewController savedModelList];
        if (indexPath.row >= (NSInteger)[list count]) { [tableView deselectRowAtIndexPath:indexPath animated:YES]; return; }
        NSString *m = [list objectAtIndex:indexPath.row];
        [[NSUserDefaults standardUserDefaults] setObject:m forKey:SettingsKeyModel];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [[Logger sharedLogger] info:[NSString stringWithFormat:@"Default model set to %@", m]];
        [_tableView reloadData];
    } else if (indexPath.section == kMMSectionAdd) {
        // Pop up an alert to input a new model name.
        UIAlertView *av = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"添加模型", nil)
                  message:NSLocalizedString(@"输入模型名(如 gpt-4o)", nil)
                 delegate:self
        cancelButtonTitle:NSLocalizedString(@"取消", nil)
        otherButtonTitles:NSLocalizedString(@"添加", nil), nil] autorelease];
        // This is the iOS 4+ UIAlertView style — single text field needs
        // the alertViewStyle property which IS available on iOS 5+.
        if ([av respondsToSelector:@selector(setAlertViewStyle:)]) {
            [av setAlertViewStyle:UIAlertViewStylePlainTextInput];
        }
        [av setTag:300];
        [av show];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView
clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (alertView.tag == 300 && buttonIndex == 1) {
        // Add model — read the text field.
        UITextField *tf = nil;
        if ([alertView respondsToSelector:@selector(textFieldAtIndex:)]) {
            tf = [alertView textFieldAtIndex:0];
        }
        NSString *m = tf.text;
        if (m && m.length > 0) {
            [ModelManagementViewController addModel:m];
            // Also set as default? No — just add to list, let user tap to
            // set default. This matches user expectation that adding a
            // model doesn't auto-switch the active one.
            [[Logger sharedLogger] info:[NSString stringWithFormat:@"Added model %@", m]];
            [_tableView reloadData];
        }
    } else if (alertView.tag == 700 && buttonIndex == 1) {
        // v261024-19: per-step logging — the "delete model" path is a
        // 90% crash hotspot. Each call gets its own log line so the next
        // crash log shows the exact last-reached step before SIGSEGV.
        [[Logger sharedLogger] info:@"ModelMgmt delete-confirm: enter"];
        // Confirm delete.
        NSString *m = _pendingDeleteModel;
        if (!m || m.length == 0) {
            [[Logger sharedLogger] info:@"ModelMgmt delete-confirm: pending model nil/empty — abort"];
            self.pendingDeleteModel = nil;
            return;
        }
        [[Logger sharedLogger] info:[NSString stringWithFormat:@"ModelMgmt delete-confirm: target=%@", m]];
        // Defensive type-check (defensive against corrupt storage where a
        // non-string snuck into the pending slot).
        if (![m isKindOfClass:[NSString class]]) {
            [[Logger sharedLogger] error:@"ModelMgmt delete-confirm: pending model is not NSString"];
            self.pendingDeleteModel = nil;
            return;
        }
        [[Logger sharedLogger] info:@"ModelMgmt delete-confirm: calling removeModel"];
        [ModelManagementViewController removeModel:m];
        [[Logger sharedLogger] info:@"ModelMgmt delete-confirm: removeModel returned"];
        // If deleted was the current default, fall back to first item.
        NSString *cur = [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyModel];
        if (cur && [cur isEqualToString:m]) {
            [[Logger sharedLogger] info:@"ModelMgmt delete-confirm: deleted was default, fallback"];
            NSArray *list = [ModelManagementViewController savedModelList];
            NSString *fallback = nil;
            if ([list count] > 0 && [(id)[list objectAtIndex:0] isKindOfClass:[NSString class]]) {
                fallback = [list objectAtIndex:0];
            } else {
                NSString *prov = [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyProvider];
                if (!prov) prov = ProviderIDOpenAI;
                fallback = [SettingsViewController defaultModelForProvider:prov];
            }
            if (fallback && [fallback isKindOfClass:[NSString class]] && fallback.length > 0) {
                [[NSUserDefaults standardUserDefaults] setObject:fallback
                                                          forKey:SettingsKeyModel];
                [[NSUserDefaults standardUserDefaults] synchronize];
                [[Logger sharedLogger] info:[NSString stringWithFormat:@"ModelMgmt delete-confirm: fallback set to %@", fallback]];
            } else {
                // Last-resort: don't leave SettingsKeyModel pointing at a deleted
                // model. Remove the key entirely.
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:SettingsKeyModel];
                [[NSUserDefaults standardUserDefaults] synchronize];
                [[Logger sharedLogger] warn:@"ModelMgmt delete-confirm: no fallback available, removed SettingsKeyModel"];
            }
        }
        [[Logger sharedLogger] info:[NSString stringWithFormat:@"Removed model %@", m]];
        if (_tableView) {
            [_tableView reloadData];
            [[Logger sharedLogger] info:@"ModelMgmt delete-confirm: reload done"];
        }
        self.pendingDeleteModel = nil;
        [[Logger sharedLogger] info:@"ModelMgmt delete-confirm: exit OK"];
    }
}

#pragma mark - Pending property setters (manual retain/release)

- (void)setPendingAddModel:(NSString *)m
{
    if (_pendingAddModel != m) {
        [_pendingAddModel release];
        _pendingAddModel = [m retain];
    }
}

- (void)setPendingDeleteModel:(NSString *)m
{
    if (_pendingDeleteModel != m) {
        [_pendingDeleteModel release];
        _pendingDeleteModel = [m retain];
    }
}

#pragma mark - /v1/models search

- (void)_searchAvailableModels
{
    NSDictionary *settings = [SettingsViewController loadSettings];
    BOOL useTransit = [[settings objectForKey:SettingsKeyUseTransit] boolValue];
    NSString *transitURL = [settings objectForKey:SettingsKeyTransitURL];
    NSString *baseURL = [settings objectForKey:SettingsKeyBaseURL];
    NSString *provider = [settings objectForKey:SettingsKeyProvider];
    NSString *apiKey = [settings objectForKey:SettingsKeyAPIKey];

    UIAlertView *loading = [[[UIAlertView alloc]
        initWithTitle:NSLocalizedString(@"搜索中…", nil)
              message:NSLocalizedString(@"正在从 /v1/models 拉取", nil)
             delegate:nil
    cancelButtonTitle:nil
    otherButtonTitles:nil] autorelease];
    [loading show];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NetworkService *svc = [[[NetworkService alloc] init] autorelease];
        NSError *err = nil;
        NSArray *models = [svc listModelsWithUseTransit:useTransit
                                              transitURL:transitURL
                                                baseURL:baseURL
                                                provider:provider
                                                 apiKey:apiKey
                                                   error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissWithClickedButtonIndex:0 animated:YES];
            if (err || !models || [models count] == 0) {
                UIAlertView *fail = [[[UIAlertView alloc]
                    initWithTitle:NSLocalizedString(@"未拉到模型", nil)
                          message:err.localizedDescription ?: NSLocalizedString(@"服务器无返回,请检查 BaseURL / API Key", nil)
                         delegate:nil
                cancelButtonTitle:NSLocalizedString(@"好", nil)
                otherButtonTitles:nil] autorelease];
                [fail show];
                return;
            }
            UIActionSheet *sheet = [[UIActionSheet alloc]
                initWithTitle:NSLocalizedString(@"选模型 → 加入列表", nil)
                     delegate:self
            cancelButtonTitle:NSLocalizedString(@"取消", nil)
       destructiveButtonTitle:nil
            otherButtonTitles:nil];
            if ([iOS6Theme isDarkMode]) {
                sheet.actionSheetStyle = UIActionSheetStyleBlackOpaque;
            } else {
                sheet.actionSheetStyle = UIActionSheetStyleAutomatic;
            }
            NSInteger limit = MIN([models count], (NSUInteger)8);
            for (NSInteger i = 0; i < limit; i++) {
                NSString *mid = [models objectAtIndex:i];
                [sheet addButtonWithTitle:mid];
            }
            [sheet setTag:400];
            [sheet showInView:self.view];
            [sheet release];
            self.availableModels = [NSMutableArray arrayWithArray:[models subarrayWithRange:NSMakeRange(0, limit)]];
        });
    });
}

- (void)actionSheet:(UIActionSheet *)actionSheet
clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (actionSheet.tag == 400 && buttonIndex >= 0 && buttonIndex < (NSInteger)[_availableModels count]) {
        NSString *m = [_availableModels objectAtIndex:buttonIndex];
        [ModelManagementViewController addModel:m];
        // Also set as default (user picked it explicitly).
        [[NSUserDefaults standardUserDefaults] setObject:m forKey:SettingsKeyModel];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [[Logger sharedLogger] info:[NSString stringWithFormat:@"Search added+default %@", m]];
        [_tableView reloadData];
    }
}

@end

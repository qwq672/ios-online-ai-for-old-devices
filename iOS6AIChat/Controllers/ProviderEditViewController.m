//
//  ProviderEditViewController.m
//  iOS6AIChat
//
//  See the .h for the section layout and the edit-in-place UX.
//

#import "ProviderEditViewController.h"
#import "iOS6Theme.h"
#import "ModelManagementViewController.h"
#import "NetworkService.h"
#import "Logger.h"
#import <QuartzCore/QuartzCore.h>

static NSString *const kCellID     = @"ProvEditCell";
static NSString *const kSegCellID  = @"ProvEditSegCell";
static NSString *const kHeaderID   = @"ProvEditHeader";

enum {
    kPESectionFormat = 0,
    kPESectionTemplate,
    kPESectionConn,
    kPESectionTest,
    kPESectionModels,
    kPESectionDelete,
    kPESectionCount
};

static NSInteger const kPESheetTemplate = 480;
static NSInteger const kPESheetQuickPick = 481;

@interface ProviderEditViewController () {
    // Deep-copied working state (mutated on every edit, persisted immediately).
    NSMutableDictionary *_entry;
    // Persistent text fields (created once, re-attached to cells).
    UITextField *_baseURLField;
    UITextField *_apiKeyField;
    UITextField *_newModelField;
    // Models list view-source (read from _entry, kept as a mutable ref).
    // (We don't keep a separate ivar — we always read/write [entry models].)
    // Pending alert state.
    NSString *_pendingDeleteModelID;
    NSString *_pendingDeleteProviderID;
    BOOL _deleteProviderConfirmStage2;  // YES when destructive-alert is the second tap
    // /v1/models search state.
    NSMutableArray *_searchResults;
    BOOL _searchInProgress;
    BOOL _searchCancelled;
}
@end

@implementation ProviderEditViewController

#pragma mark - Lifecycle

- (id)initWithProviderEntry:(NSDictionary *)entry
{
    if (self = [super initWithNibName:nil bundle:nil]) {
        // Deep copy so we can mutate without touching the live store until save.
        _entry = [[NSMutableDictionary alloc] initWithDictionary:entry];
        // Ensure required keys exist.
        if (![_entry objectForKey:@"id"]) {
            [_entry setObject:[ModelManagementViewController newProviderUUID] forKey:@"id"];
        }
        if (![_entry objectForKey:@"format"]) {
            [_entry setObject:ProviderFormatOpenAI forKey:@"format"];
        }
        if (![_entry objectForKey:@"template"]) {
            [_entry setObject:ProviderTemplateCustom forKey:@"template"];
        }
        if (![_entry objectForKey:@"displayName"]) {
            [_entry setObject:[SettingsViewController displayNameForTemplate:
                              [_entry objectForKey:@"template"]] forKey:@"displayName"];
        }
        if (![_entry objectForKey:@"baseURL"]) {
            [_entry setObject:@"" forKey:@"baseURL"];
        }
        if (![_entry objectForKey:@"apiKey"]) {
            [_entry setObject:@"" forKey:@"apiKey"];
        }
        if (![_entry objectForKey:@"collapsed"]) {
            [_entry setObject:[NSNumber numberWithBool:NO] forKey:@"collapsed"];
        }
        if (![_entry objectForKey:@"models"]) {
            [_entry setObject:[NSMutableArray array] forKey:@"models"];
        }
        self.title = NSLocalizedString(@"编辑供应商", nil);
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_entry release];
    [_baseURLField release];
    [_apiKeyField release];
    [_newModelField release];
    [_pendingDeleteModelID release];
    [_pendingDeleteProviderID release];
    [_searchResults release];
    [super dealloc];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    CGRect frame = self.view.bounds;
    UITableView *tv = [[UITableView alloc] initWithFrame:frame style:UITableViewStyleGrouped];
    tv.dataSource = self;
    tv.delegate = self;
    tv.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                           UIViewAutoresizingFlexibleHeight);
    tv.backgroundColor = [UIColor clearColor];
    tv.backgroundView = nil;
    tv.opaque = NO;
    [tv registerClass:[UITableViewCell class] forCellReuseIdentifier:kCellID];
    [self.view addSubview:tv];
    self.tableView = tv;
    [tv release];
    _searchResults = [[NSMutableArray array] retain];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_themeChanged)
                                                 name:@"iOS6ThemeDidChangeNotification"
                                                   object:nil];
}

@synthesize tableView=_tableView;

- (void)setTableView:(UITableView *)tv
{
    if (_tableView != tv) {
        [_tableView release];
        _tableView = [tv retain];
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;
    [_tableView reloadData];
}

- (void)_themeChanged
{
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;
    for (UITextField *f in [NSArray arrayWithObjects:_baseURLField, _apiKeyField, _newModelField, nil]) {
        if (![f isKindOfClass:[UITextField class]]) continue;
        f.backgroundColor = [iOS6Theme inputFieldBackgroundColor];
        f.textColor = [iOS6Theme inputFieldTextColor];
    }
    [_tableView reloadData];
}

#pragma mark - Persistence (edit-in-place)

- (void)_persist
{
    // Save the current _entry back to the provider list.
    [ModelManagementViewController replaceProviderWithID:[_entry objectForKey:@"id"]
                                              newEntry:_entry];
}

- (void)_persistAndReload
{
    [self _persist];
    [_tableView reloadData];
}

#pragma mark - Format / template helpers

- (NSString *)_currentFormat   { return [_entry objectForKey:@"format"]; }
- (NSString *)_currentTemplate { return [_entry objectForKey:@"template"]; }

- (void)_applyFormat:(NSString *)fmt
{
    if (![fmt isKindOfClass:[NSString class]] || fmt.length == 0) return;
    [_entry setObject:fmt forKey:@"format"];
    // If the current template doesn't belong to this format, fall back to
    // the first template that matches the new format.
    if (![[SettingsViewController formatForTemplate:[_entry objectForKey:@"template"]]
            isEqualToString:fmt]) {
        NSArray *matching = [SettingsViewController templatesForFormat:fmt];
        NSString *newTpl = ([matching count] > 0)
            ? [matching objectAtIndex:0] : ProviderTemplateCustom;
        [self _applyTemplate:newTpl];
    }
    [self _persistAndReload];
}

- (void)_applyTemplate:(NSString *)tpl
{
    if (![tpl isKindOfClass:[NSString class]] || tpl.length == 0) return;
    [_entry setObject:tpl forKey:@"template"];
    [_entry setObject:[SettingsViewController displayNameForTemplate:tpl] forKey:@"displayName"];
    // Auto-fill baseURL when the field is empty or still holds another
    // template's default URL.
    if (_baseURLField) {
        NSString *cur = [_baseURLField.text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        BOOL isOtherDefault = NO;
        if (cur.length == 0) {
            isOtherDefault = YES;
        } else {
            for (NSString *t in [SettingsViewController availableTemplateIDs]) {
                if ([t isEqualToString:tpl]) continue;
                NSString *d = [SettingsViewController defaultBaseURLForTemplate:t];
                if (d.length > 0 && [cur isEqualToString:d]) {
                    isOtherDefault = YES;
                    break;
                }
            }
        }
        if (isOtherDefault) {
            _baseURLField.text = [SettingsViewController defaultBaseURLForTemplate:tpl];
            [_entry setObject:_baseURLField.text forKey:@"baseURL"];
        }
    }
    // Update format if it doesn't match the new template's canonical format.
    NSString *canonFmt = [SettingsViewController formatForTemplate:tpl];
    if (![canonFmt isEqualToString:[_entry objectForKey:@"format"]]) {
        [_entry setObject:canonFmt forKey:@"format"];
    }
    [self _persistAndReload];
}

#pragma mark - Table data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kPESectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == kPESectionFormat)   return 1;
    if (section == kPESectionTemplate) return 1;
    if (section == kPESectionConn)    return 2;   // BaseURL + API Key
    if (section == kPESectionTest)    return 1;
    if (section == kPESectionModels)  return (NSInteger)[[_entry objectForKey:@"models"] count] + 2;  // models + 添加 + 搜索
    if (section == kPESectionDelete)  return 1;
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == kPESectionFormat)   return NSLocalizedString(@"提供商格式", nil);
    if (section == kPESectionTemplate) return NSLocalizedString(@"提供商模板", nil);
    if (section == kPESectionConn)    return NSLocalizedString(@"连接", nil);
    if (section == kPESectionTest)    return @"";
    if (section == kPESectionModels)  return NSLocalizedString(@"模型", nil);
    return @"";
}

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

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == kPESectionFormat) {
        return NSLocalizedString(@"openai=/v1/chat/completions; anthropic=/v1/messages; ollama 原生 /api/chat (本轮按 openai 兼容)。", nil);
    }
    if (section == kPESectionTemplate) {
        return NSLocalizedString(@"模板仅预设 baseURL，不会自动改 format。选自定义可手动填任意 URL。", nil);
    }
    if (section == kPESectionConn) {
        return NSLocalizedString(@"改完即存；不需要点保存。API Key 留空沿用全局 Key。", nil);
    }
    if (section == kPESectionModels) {
        return NSLocalizedString(@"★ = 加入加号菜单快捷列表；左滑删除单个模型；点行设为当前激活。", nil);
    }
    return @"";
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section
{
    NSString *title = [self tableView:tableView titleForFooterInSection:section];
    return [iOS6Theme groupedSectionFooterViewWithTitle:title
                                                  width:tableView.bounds.size.width];
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    NSString *title = [self tableView:tableView titleForFooterInSection:section];
    return [iOS6Theme groupedSectionFooterHeightForTitle:title
                                                   width:tableView.bounds.size.width];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
          cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellID];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:kCellID] autorelease];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSArray *old = [cell.contentView.subviews copy];
    for (UIView *v in old) [v removeFromSuperview];
    [old release];
    cell.backgroundColor = [iOS6Theme bubbleAssistantColor];
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.textLabel.opaque = NO;
    cell.textLabel.text = @"";
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (indexPath.section == kPESectionFormat) {
        // Segmented control: openai / anthropic / ollama.
        CGFloat w = cell.contentView.bounds.size.width;
        UISegmentedControl *seg = [[[UISegmentedControl alloc]
            initWithItems:[NSArray arrayWithObjects:
                @"openai", @"anthropic", @"ollama", nil]] autorelease];
        seg.frame = CGRectMake(12, (44 - 30) / 2.0f, w - 24, 30);
        seg.segmentedControlStyle = UISegmentedControlStyleBar;
        seg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        NSString *fmt = [self _currentFormat];
        if ([fmt isEqualToString:ProviderFormatAnthropic]) {
            seg.selectedSegmentIndex = 1;
        } else if ([fmt isEqualToString:ProviderFormatOllama]) {
            seg.selectedSegmentIndex = 2;
        } else {
            seg.selectedSegmentIndex = 0;
        }
        [seg addTarget:self action:@selector(_formatSegChanged:)
          forControlEvents:UIControlEventValueChanged];
        [cell.contentView addSubview:seg];
        return cell;
    }

    if (indexPath.section == kPESectionTemplate) {
        cell.textLabel.text = NSLocalizedString(@"模板", nil);
        cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        cell.textLabel.textColor = [iOS6Theme textColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;

        UILabel *val = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
        val.text = [SettingsViewController displayNameForTemplate:[self _currentTemplate]];
        val.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        val.textColor = [iOS6Theme secondaryTextColor];
        val.backgroundColor = [UIColor clearColor];
        val.textAlignment = NSTextAlignmentRight;
        val.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        CGFloat w = cell.contentView.bounds.size.width;
        val.frame = CGRectMake(12 + 80 + 4, 0, w - 12 - 80 - 4 - 12 - 22, 44);
        [cell.contentView addSubview:val];
        return cell;
    }

    if (indexPath.section == kPESectionConn) {
        static CGFloat const kLabelW = 80.0f;
        NSString *label = nil;
        UITextField *field = nil;
        NSString *placeholder = nil;
        BOOL secure = NO;
        UIKeyboardType kbd = UIKeyboardTypeDefault;
        if (indexPath.row == 0) {
            label = NSLocalizedString(@"BaseURL", nil);
            field = [self _makeField:&_baseURLField
                           seedValue:[_entry objectForKey:@"baseURL"]
                          secureText:NO
                        keyboardType:UIKeyboardTypeURL];
            placeholder = [SettingsViewController defaultBaseURLForTemplate:[self _currentTemplate]];
            if (placeholder.length == 0) placeholder = @"https://your-endpoint/v1";
        } else {
            label = NSLocalizedString(@"API Key", nil);
            field = [self _makeField:&_apiKeyField
                           seedValue:[_entry objectForKey:@"apiKey"]
                          secureText:YES
                        keyboardType:UIKeyboardTypeDefault];
            placeholder = NSLocalizedString(@"留空沿用全局 Key", nil);
        }
        // Add tag for identify in textFieldDidEndEditing:.
        field.tag = (indexPath.row == 0) ? 100 : 101;
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, kLabelW, 44)];
        l.text = label;
        l.backgroundColor = [UIColor clearColor];
        l.opaque = NO;
        l.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        l.textColor = [iOS6Theme textColor];
        l.adjustsFontSizeToFitWidth = YES;
        l.minimumScaleFactor = 0.7f;
        l.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
        [cell.contentView addSubview:l];
        [l release];
        CGFloat w = cell.contentView.bounds.size.width;
        field.placeholder = placeholder;
        field.frame = CGRectMake(12 + kLabelW + 4, 7, w - 12 - kLabelW - 4 - 12, 30);
        field.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [cell.contentView addSubview:field];
        return cell;
    }

    if (indexPath.section == kPESectionTest) {
        cell.textLabel.text = NSLocalizedString(@"测试连接 (GET /v1/models)", nil);
        cell.textLabel.textColor = [iOS6Theme tintColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        return cell;
    }

    if (indexPath.section == kPESectionModels) {
        NSArray *models = [_entry objectForKey:@"models"];
        NSInteger modelCount = (NSInteger)[models count];
        if (indexPath.row < modelCount) {
            NSDictionary *m = [models objectAtIndex:indexPath.row];
            NSString *mid = [m objectForKey:@"id"];
            cell.textLabel.text = mid ?: @"?";
            cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
            cell.textLabel.textColor = [iOS6Theme textColor];
            // Star toggle button on the right.
            BOOL starred = [[m objectForKey:@"starred"] boolValue];
            UIButton *star = [UIButton buttonWithType:UIButtonTypeCustom];
            [star setTitle:starred ? @"\u2605" : @"\u2606"
                   forState:UIControlStateNormal];
            [star setTitleColor:starred
                            ? [UIColor colorWithRed:0.95f green:0.7f blue:0.1f alpha:1.0f]
                            : [iOS6Theme secondaryTextColor]
                     forState:UIControlStateNormal];
            star.titleLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:20]];
            CGFloat cw = cell.contentView.bounds.size.width;
            star.frame = CGRectMake(cw - 12 - 36, (44 - 30) / 2, 36, 30);
            star.tag = 6000 + indexPath.row;
            star.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            [star addTarget:self action:@selector(_starTapped:)
              forControlEvents:UIControlEventTouchUpInside];
            [cell.contentView addSubview:star];
            // Kind badge if image.
            if ([[m objectForKey:@"kind"] isEqualToString:@"image"]) {
                UILabel *b = [[[UILabel alloc]
                    initWithFrame:CGRectMake(cw - 12 - 36 - 6 - 40, (44 - 18) / 2, 40, 18)] autorelease];
                b.text = NSLocalizedString(@"生图", nil);
                b.textColor = [UIColor whiteColor];
                b.backgroundColor = [iOS6Theme tintColor];
                b.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:10]];
                b.textAlignment = NSTextAlignmentCenter;
                b.layer.cornerRadius = 4.0f;
                b.layer.masksToBounds = YES;
                b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
                [cell.contentView addSubview:b];
            }
            // Active checkmark.
            NSString *def = [[m objectForKey:@"kind"] isEqualToString:@"image"]
                ? [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyImageGenModel]
                : [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyModel];
            if (def && [def isEqualToString:mid]) {
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
            }
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            return cell;
        }
        if (indexPath.row == modelCount) {
            // 添加模型 row (manual entry via alert).
            cell.textLabel.text = NSLocalizedString(@"+ 添加模型 (手动输入 ID)", nil);
            cell.textLabel.textColor = [iOS6Theme tintColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            return cell;
        }
        // 搜索模型 row.
        cell.textLabel.text = NSLocalizedString(@"搜索模型 (/v1/models → 加入)", nil);
        cell.textLabel.textColor = [iOS6Theme tintColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        return cell;
    }

    if (indexPath.section == kPESectionDelete) {
        cell.textLabel.text = NSLocalizedString(@"删除整个供应商", nil);
        cell.textLabel.textColor = [UIColor redColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        return cell;
    }
    return cell;
}

#pragma mark - Field factory

- (UITextField *)_makeField:(UITextField **)slot
                  seedValue:(NSString *)seed
                 secureText:(BOOL)secure
                 keyboardType:(UIKeyboardType)kbd
{
    if (*slot) return *slot;
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectZero];
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:14]];
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.returnKeyType = UIReturnKeyDone;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.keyboardType = kbd;
    f.secureTextEntry = secure;
    f.delegate = self;
    f.backgroundColor = [iOS6Theme inputFieldBackgroundColor];
    f.textColor = [iOS6Theme inputFieldTextColor];
    if ([iOS6Theme isDarkMode] && [f respondsToSelector:@selector(setKeyboardAppearance:)]) {
        [f setKeyboardAppearance:UIKeyboardAppearanceAlert];
    }
    if (seed.length > 0) f.text = seed;
    *slot = f;
    return f;
}

#pragma mark - Table delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == kPESectionTemplate) {
        [self _presentTemplateSheet];
    } else if (indexPath.section == kPESectionTest) {
        [self _testConnection];
    } else if (indexPath.section == kPESectionModels) {
        NSArray *models = [_entry objectForKey:@"models"];
        NSInteger mc = (NSInteger)[models count];
        if (indexPath.row < mc) {
            // Tap a model row = set active.
            NSDictionary *m = [models objectAtIndex:indexPath.row];
            NSString *mid = [m objectForKey:@"id"];
            if (mid.length > 0) {
                [ModelManagementViewController setActiveModel:mid];
                [_tableView reloadData];
            }
        } else if (indexPath.row == mc) {
            // + 添加模型 (alert).
            UIAlertView *av = [[[UIAlertView alloc]
                initWithTitle:NSLocalizedString(@"添加模型", nil)
                      message:NSLocalizedString(@"输入模型 ID（如 deepseek-chat）：", nil)
                     delegate:self
            cancelButtonTitle:NSLocalizedString(@"取消", nil)
            otherButtonTitles:NSLocalizedString(@"添加", nil), nil] autorelease];
            [av setAlertViewStyle:UIAlertViewStylePlainTextInput];
            [av setTag:600];
            [av show];
        } else {
            // 搜索模型.
            [self _searchModels];
        }
    } else if (indexPath.section == kPESectionDelete) {
        if (_deleteProviderConfirmStage2) {
            // Stage 2: do it.
            _deleteProviderConfirmStage2 = NO;
            NSString *pid = [_entry objectForKey:@"id"];
            [ModelManagementViewController removeProviderWithID:pid];
            [self.navigationController popViewControllerAnimated:YES];
            return;
        }
        // Stage 1: confirm.
        _deleteProviderConfirmStage2 = YES;
        UIAlertView *av = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"删除整个供应商?", nil)
                  message:NSLocalizedString(@"此操作将删除该供应商及其所有模型，不可撤销。再次点击列表里的「删除整个供应商」确认。", nil)
                 delegate:self
        cancelButtonTitle:NSLocalizedString(@"取消", nil)
        otherButtonTitles:NSLocalizedString(@"明白了", nil), nil] autorelease];
        [av setTag:610];
        [av show];
    }
}

- (BOOL)tableView:(UITableView *)tableView
canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    // Only models (rows 0..N-1) are swipe-deletable.
    return (indexPath.section == kPESectionModels) &&
           (indexPath.row < (NSInteger)[[_entry objectForKey:@"models"] count]);
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.section != kPESectionModels) return;
    NSArray *models = [_entry objectForKey:@"models"];
    if (indexPath.row >= (NSInteger)[models count]) return;
    NSDictionary *m = [models objectAtIndex:indexPath.row];
    NSString *mid = [m objectForKey:@"id"];
    if (!mid.length) return;
    UIAlertView *av = [[[UIAlertView alloc]
        initWithTitle:NSLocalizedString(@"删除模型?", nil)
              message:[NSString stringWithFormat:@"%@ \"%@\"", NSLocalizedString(@"确定从该供应商下删除", nil), mid]
             delegate:self
    cancelButtonTitle:NSLocalizedString(@"取消", nil)
    otherButtonTitles:NSLocalizedString(@"删除", nil), nil] autorelease];
    [av setTag:620];
    self.pendingDeleteModelID = mid;
    [av show];
}

#pragma mark - Property setters (manual retain/release)

- (void)setPendingDeleteModelID:(NSString *)m
{
    if (_pendingDeleteModelID != m) {
        [_pendingDeleteModelID release];
        _pendingDeleteModelID = [m retain];
    }
}

- (void)setPendingDeleteProviderID:(NSString *)m
{
    if (_pendingDeleteProviderID != m) {
        [_pendingDeleteProviderID release];
        _pendingDeleteProviderID = [m retain];
    }
}

#pragma mark - Alerts

- (void)alertView:(UIAlertView *)alertView
clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (alertView.tag == 600 && buttonIndex == 1) {
        // Add model manually.
        UITextField *tf = [alertView textFieldAtIndex:0];
        NSString *mid = [tf.text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (mid.length == 0) return;
        // Determine kind from the user — we default to chat here. If they
        // need image kind they can edit it later (future: kind picker).
        NSMutableArray *models = [[_entry objectForKey:@"models"] mutableCopy];
        // De-dupe.
        for (NSDictionary *m in models) {
            if ([[m objectForKey:@"id"] isEqualToString:mid]) {
                [models release];
                return;
            }
        }
        NSMutableDictionary *nm = [NSMutableDictionary dictionary];
        [nm setObject:mid forKey:@"id"];
        [nm setObject:[NSNumber numberWithBool:NO] forKey:@"starred"];
        [nm setObject:@"chat" forKey:@"kind"];
        [models addObject:nm];
        [_entry setObject:models forKey:@"models"];
        [models release];
        [self _persistAndReload];
        return;
    }
    if (alertView.tag == 610) {
        if (buttonIndex != 1) _deleteProviderConfirmStage2 = NO;
        // If user confirmed (stage 1), the flag stays YES; next tap on the
        // delete row triggers actual deletion.
        return;
    }
    if (alertView.tag == 620 && buttonIndex == 1) {
        NSString *mid = _pendingDeleteModelID;
        if (!mid.length) { self.pendingDeleteModelID = nil; return; }
        NSMutableArray *models = [[_entry objectForKey:@"models"] mutableCopy];
        NSMutableArray *clean = [NSMutableArray array];
        for (NSDictionary *m in models) {
            if ([[m objectForKey:@"id"] isEqualToString:mid]) continue;
            [clean addObject:m];
        }
        [_entry setObject:clean forKey:@"models"];
        [models release];
        // Clear active pointers if they referenced the removed model.
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if ([[d stringForKey:SettingsKeyModel] isEqualToString:mid]) {
            [d removeObjectForKey:SettingsKeyModel];
        }
        if ([[d stringForKey:SettingsKeyImageGenModel] isEqualToString:mid]) {
            [d removeObjectForKey:SettingsKeyImageGenModel];
        }
        [d synchronize];
        [self _persistAndReload];
        self.pendingDeleteModelID = nil;
    }
}

#pragma mark - Format / template pickers

- (void)_formatSegChanged:(UISegmentedControl *)seg
{
    NSString *fmt = ProviderFormatOpenAI;
    if (seg.selectedSegmentIndex == 1) fmt = ProviderFormatAnthropic;
    else if (seg.selectedSegmentIndex == 2) fmt = ProviderFormatOllama;
    [self _applyFormat:fmt];
}

- (void)_presentTemplateSheet
{
    UIActionSheet *sheet = [[[UIActionSheet alloc]
        initWithTitle:NSLocalizedString(@"选择模板", nil)
                 delegate:self
        cancelButtonTitle:NSLocalizedString(@"取消", nil)
    destructiveButtonTitle:nil
        otherButtonTitles:nil] autorelease];
    if ([iOS6Theme isDarkMode]) sheet.actionSheetStyle = UIActionSheetStyleBlackOpaque;
    else sheet.actionSheetStyle = UIActionSheetStyleAutomatic;
    // Filter by current format (so the list shows only matching templates).
    NSArray *templates = [SettingsViewController templatesForFormat:[self _currentFormat]];
    for (NSString *t in templates) {
        [sheet addButtonWithTitle:[SettingsViewController displayNameForTemplate:t]];
    }
    // Always include 自定义.
    if (![templates containsObject:ProviderTemplateCustom]) {
        [sheet addButtonWithTitle:[SettingsViewController displayNameForTemplate:ProviderTemplateCustom]];
    }
    [sheet setTag:kPESheetTemplate];
    [sheet showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)actionSheet
clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == actionSheet.cancelButtonIndex) return;
    if (actionSheet.tag == kPESheetTemplate) {
        NSArray *templates = [SettingsViewController templatesForFormat:[self _currentFormat]];
        // The sheet may have an extra 自定义 button appended when the
        // current format doesn't include custom (it always does, since
        // custom maps to openai — but we add it defensively anyway).
        NSInteger idx = buttonIndex - 1;
        NSString *picked = nil;
        if (idx < (NSInteger)[templates count]) {
            picked = [templates objectAtIndex:idx];
        } else if (idx == (NSInteger)[templates count]) {
            picked = ProviderTemplateCustom;
        }
        if (picked) {
            [self _applyTemplate:picked];
        }
        return;
    }
    if (actionSheet.tag == kPESheetQuickPick) {
        // v261025-9: search results picker — add the picked model to the
        // provider's models list.
        NSInteger idx = buttonIndex - 1;
        if (idx < 0 || idx >= (NSInteger)[_searchResults count]) return;
        NSString *mid = [_searchResults objectAtIndex:idx];
        if (!mid.length) return;
        NSMutableArray *models = [[_entry objectForKey:@"models"] mutableCopy];
        for (NSDictionary *m in models) {
            if ([[m objectForKey:@"id"] isEqualToString:mid]) {
                [models release];
                return;
            }
        }
        NSMutableDictionary *nm = [NSMutableDictionary dictionary];
        [nm setObject:mid forKey:@"id"];
        [nm setObject:[NSNumber numberWithBool:NO] forKey:@"starred"];
        [nm setObject:@"chat" forKey:@"kind"];
        [models addObject:nm];
        [_entry setObject:models forKey:@"models"];
        [models release];
        [self _persistAndReload];
        return;
    }
}

#pragma mark - Star toggle (model)

- (void)_starTapped:(UIButton *)btn
{
    UIView *v = btn;
    while (v && ![v isKindOfClass:[UITableViewCell class]]) v = v.superview;
    if (!v) return;
    NSIndexPath *ip = [_tableView indexPathForCell:(UITableViewCell *)v];
    if (!ip || ip.section != kPESectionModels) return;
    NSArray *models = [_entry objectForKey:@"models"];
    if (ip.row >= (NSInteger)[models count]) return;
    NSDictionary *m = [models objectAtIndex:ip.row];
    NSString *mid = [m objectForKey:@"id"];
    if (!mid.length) return;
    // Toggle starred in the working entry, then persist.
    NSMutableArray *modelsM = [models mutableCopy];
    for (NSInteger i = 0; i < (NSInteger)[modelsM count]; i++) {
        NSDictionary *mm = [modelsM objectAtIndex:i];
        if (![[mm objectForKey:@"id"] isEqualToString:mid]) continue;
        NSMutableDictionary *mc = [NSMutableDictionary dictionaryWithDictionary:mm];
        BOOL was = [[mc objectForKey:@"starred"] boolValue];
        [mc setObject:[NSNumber numberWithBool:!was] forKey:@"starred"];
        [modelsM replaceObjectAtIndex:i withObject:mc];
        break;
    }
    [_entry setObject:modelsM forKey:@"models"];
    [modelsM release];
    [self _persistAndReload];
}

#pragma mark - Text field delegate (BaseURL / API Key commit on end)

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    // Commit BaseURL / API Key edits to the entry.
    if (textField.tag == 100) {
        NSString *v = [textField.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [_entry setObject:v forKey:@"baseURL"];
        // Re-derive template from the typed URL if it matches a known one.
        NSString *inferredTpl = [SettingsViewController templateForBaseURL:v];
        if (![inferredTpl isEqualToString:[_entry objectForKey:@"template"]]) {
            [_entry setObject:inferredTpl forKey:@"template"];
            [_entry setObject:[SettingsViewController displayNameForTemplate:inferredTpl]
                       forKey:@"displayName"];
            // Re-derive format too.
            [_entry setObject:[SettingsViewController formatForTemplate:inferredTpl]
                       forKey:@"format"];
        }
    } else if (textField.tag == 101) {
        NSString *v = [textField.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [_entry setObject:v forKey:@"apiKey"];
    }
    [self _persist];
    // Reload to refresh the template row + displayName.
    [_tableView reloadData];
}

#pragma mark - Test connection

- (void)_testConnection
{
    // Use the form's current values (not the persisted entry) so the user
    // can test before committing a change.
    [_baseURLField resignFirstResponder];
    [_apiKeyField resignFirstResponder];
    NSString *baseURL = [[_baseURLField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"" copy];
    NSString *apiKey  = [[_apiKeyField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"" copy];
    NSString *provider = [_entry objectForKey:@"template"];
    [baseURL autorelease];
    [apiKey autorelease];

    if (baseURL.length == 0) {
        baseURL = [[SettingsViewController defaultBaseURLForTemplate:provider] copy];
        [baseURL autorelease];
    }
    if (baseURL.length == 0) {
        UIAlertView *av = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"缺少 BaseURL", nil)
                  message:NSLocalizedString(@"自定义模板需手动填写 BaseURL。", nil)
                 delegate:nil
        cancelButtonTitle:NSLocalizedString(@"好", nil)
        otherButtonTitles:nil] autorelease];
        [av show];
        return;
    }

    NSDictionary *settings = [SettingsViewController loadSettings];
    BOOL useTransit = [[settings objectForKey:SettingsKeyUseTransit] boolValue];
    NSString *transitURL = [settings objectForKey:SettingsKeyTransitURL];

    UIAlertView *loading = [[[UIAlertView alloc]
        initWithTitle:NSLocalizedString(@"测试中…", nil)
              message:NSLocalizedString(@"正在发起 GET /v1/models", nil)
             delegate:nil
    cancelButtonTitle:nil
    otherButtonTitles:nil] autorelease];
    [loading show];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NetworkService *svc = [[[NetworkService alloc] init] autorelease];
            NSError *err = nil;
            NSArray *models = [svc listModelsWithUseTransit:useTransit
                                                  transitURL:transitURL
                                                    baseURL:baseURL
                                                    provider:provider
                                                     apiKey:apiKey
                                                       error:&err];
            NSArray *rc = [models retain];
            NSError *ec = [err retain];
            dispatch_async(dispatch_get_main_queue(), ^{
                [loading dismissWithClickedButtonIndex:-1 animated:NO];
                if (ec || !rc || [rc count] == 0) {
                    NSString *desc = [ec localizedDescription];
                    [[Logger sharedLogger] error:[NSString stringWithFormat:
                        @"ProvEdit test FAIL - %@", desc ?: @"(no response)"]];
                    UIAlertView *fail = [[[UIAlertView alloc]
                        initWithTitle:NSLocalizedString(@"连接失败", nil)
                              message:desc ?: NSLocalizedString(@"无返回,请检查 BaseURL / API Key / 中转 URL", nil)
                             delegate:nil
                    cancelButtonTitle:NSLocalizedString(@"好", nil)
                    otherButtonTitles:nil] autorelease];
                    [fail show];
                } else {
                    [[Logger sharedLogger] info:[NSString stringWithFormat:
                        @"ProvEdit test OK - %lu models", (unsigned long)[rc count]]];
                    UIAlertView *ok = [[[UIAlertView alloc]
                        initWithTitle:NSLocalizedString(@"连接成功", nil)
                              message:[NSString stringWithFormat:
                                  NSLocalizedString(@"服务器返回 %d 个可用模型。", nil),
                                  (int)[rc count]]
                             delegate:nil
                    cancelButtonTitle:NSLocalizedString(@"好", nil)
                    otherButtonTitles:nil] autorelease];
                    [ok show];
                }
                [ec release];
                [rc release];
            });
        }
    });
}

#pragma mark - Search models

- (void)_searchModels
{
    if (_searchInProgress) return;
    [_baseURLField resignFirstResponder];
    [_apiKeyField resignFirstResponder];
    [_newModelField resignFirstResponder];
    NSString *baseURL = [[_baseURLField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"" copy];
    NSString *apiKey  = [[_apiKeyField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"" copy];
    NSString *provider = [_entry objectForKey:@"template"];
    [baseURL autorelease]; [apiKey autorelease];
    if (baseURL.length == 0) baseURL = [[SettingsViewController defaultBaseURLForTemplate:provider] copy];
    if (baseURL.length == 0) {
        UIAlertView *av = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"缺少 BaseURL", nil)
                  message:NSLocalizedString(@"自定义模板需手动填写 BaseURL。", nil)
                 delegate:nil
        cancelButtonTitle:NSLocalizedString(@"好", nil)
        otherButtonTitles:nil] autorelease];
        [av show];
        return;
    }
    _searchInProgress = YES;
    _searchCancelled = NO;

    NSDictionary *settings = [SettingsViewController loadSettings];
    BOOL useTransit = [[settings objectForKey:SettingsKeyUseTransit] boolValue];
    NSString *transitURL = [settings objectForKey:SettingsKeyTransitURL];

    UIAlertView *loading = [[[UIAlertView alloc]
        initWithTitle:NSLocalizedString(@"搜索中…", nil)
              message:NSLocalizedString(@"正在从 /v1/models 拉取", nil)
             delegate:self
    cancelButtonTitle:NSLocalizedString(@"取消", nil)
    otherButtonTitles:nil] autorelease];
    [loading setTag:500];
    [loading show];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NetworkService *svc = [[[NetworkService alloc] init] autorelease];
            NSError *err = nil;
            NSArray *models = [svc listModelsWithUseTransit:useTransit
                                                  transitURL:transitURL
                                                    baseURL:baseURL
                                                    provider:provider
                                                     apiKey:apiKey
                                                       error:&err];
            NSArray *rc = [models retain];
            NSError *ec = [err retain];
            dispatch_async(dispatch_get_main_queue(), ^{
                _searchInProgress = NO;
                [loading dismissWithClickedButtonIndex:-1 animated:NO];
                if (_searchCancelled) {
                    _searchCancelled = NO;
                    [ec release]; [rc release];
                    return;
                }
                if (ec || !rc || [rc count] == 0) {
                    NSString *desc = [ec localizedDescription];
                    [[Logger sharedLogger] error:[NSString stringWithFormat:
                        @"ProvEdit search FAIL - %@", desc ?: @"(no response)"]];
                    UIAlertView *fail = [[[UIAlertView alloc]
                        initWithTitle:NSLocalizedString(@"未拉到模型", nil)
                              message:desc ?: NSLocalizedString(@"服务器无返回,请检查 BaseURL / API Key", nil)
                             delegate:nil
                    cancelButtonTitle:NSLocalizedString(@"好", nil)
                    otherButtonTitles:nil] autorelease];
                    [fail show];
                    [ec release]; [rc release];
                    return;
                }
                [_searchResults removeAllObjects];
                NSInteger limit = MIN([rc count], (NSUInteger)8);
                for (NSInteger i = 0; i < limit; i++) {
                    NSString *mid = [rc objectAtIndex:i];
                    if ([mid isKindOfClass:[NSString class]]) [_searchResults addObject:mid];
                }
                [ec release]; [rc release];
                [self performSelector:@selector(_presentQuickPickSheet)
                           withObject:nil
                           afterDelay:0.1];
            });
        }
    });
}

// v261025-9: UIAlertView cancel delegate for the search loading alert.
- (void)alertViewCancel:(UIAlertView *)alertView
{
    if (alertView.tag == 500) {
        _searchCancelled = YES;
    }
}

- (void)_presentQuickPickSheet
{
    if ([_searchResults count] == 0) return;
    UIActionSheet *sheet = [[[UIActionSheet alloc]
        initWithTitle:NSLocalizedString(@"选模型 → 加入供应商", nil)
             delegate:self
    cancelButtonTitle:NSLocalizedString(@"取消", nil)
destructiveButtonTitle:nil
        otherButtonTitles:nil] autorelease];
    if ([iOS6Theme isDarkMode]) sheet.actionSheetStyle = UIActionSheetStyleBlackOpaque;
    else sheet.actionSheetStyle = UIActionSheetStyleAutomatic;
    for (NSString *mid in _searchResults) {
        [sheet addButtonWithTitle:mid];
    }
    [sheet setTag:kPESheetQuickPick];
    [sheet showInView:self.view];
}

@end

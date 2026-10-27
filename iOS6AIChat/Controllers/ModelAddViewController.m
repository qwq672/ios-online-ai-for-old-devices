//
//  ModelAddViewController.m
//  iOS6AIChat
//
//  v261025-9: REWRITE as "添加模型供应商" — full two-tier provider-entry form.
//    Section 0: 提供商格式 (format segmented: openai / anthropic / ollama)
//    Section 1: 提供商模板 (template picker row → action sheet filtered by format;
//               选模板自动填 baseURL，填其他 URL 自动 = 自定义)
//    Section 2: 连接 (BaseURL + API Key text fields)
//    Section 3: 测试 (button — GET {baseURL}/v1/models with current field values)
//    Section 4: 模型 (search results list / manually added — multi-select)
//               + 「搜索模型」 button row (GET /v1/models → action sheet picker)
//               + 「+ 手动添加模型」 button row (alert 输入 ID)
//    Section 5: 保存 (button — builds a provider entry, appends to the store)
//
//  All edits stay in ivars until the user taps 保存 — testing and search
//  use the current field values so the user can verify before committing.
//
//  Memory model: MRC. Every convenience-constructor result assigned to an
//  ivar is RETAINED (see ChatMessageCell v261025-7 root-cause writeup).
//

#import "ModelAddViewController.h"
#import "iOS6Theme.h"
#import "ModelManagementViewController.h"
#import "SettingsViewController.h"
#import "NetworkService.h"
#import "Logger.h"
#import <QuartzCore/QuartzCore.h>

static NSString *const kCellID    = @"ModelAddCell";
static NSString *const kSegCellID  = @"ModelAddSegCell";

static CGFloat const kRowH = 44.0f;
static CGFloat const kPad  = 12.0f;
static CGFloat const kLabelW = 84.0f;

enum {
    kAASectionFormat = 0,
    kAASectionTemplate,
    kAASectionConn,
    kAASectionTest,
    kAASectionModels,
    kAASectionSave,
    kAASectionCount
};

static NSInteger const kAASheetTemplate = 460;
static NSInteger const kAASheetQuickPick = 461;

@interface ModelAddViewController () <UIActionSheetDelegate, UIAlertViewDelegate> {
    UITableView *_formTable;

    // Form state.
    NSString *_format;            // ProviderFormatOpenAI / Anthropic / Ollama
    NSString *_template;          // ProviderID* / ProviderTemplateCustom
    NSMutableArray *_models;      // working list of model dicts ({id, starred, kind})

    // Persistent text fields (created once, re-attached to cells).
    UITextField *_baseURLField;
    UITextField *_apiKeyField;

    // Search results state.
    NSMutableArray *_searchResults;
    BOOL _searchInProgress;
    BOOL _searchCancelled;

    // Pending alert state.
    NSString *_pendingManualAddModelID;   // tag 600 alert
}

@end

@implementation ModelAddViewController

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_formTable release];
    [_format release];
    [_template release];
    [_models release];
    [_baseURLField release];
    [_apiKeyField release];
    [_searchResults release];
    [_pendingManualAddModelID release];
    [super dealloc];
}

- (id)init
{
    return [self initWithNibName:nil bundle:nil];
}

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if (self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil]) {
        self.title = NSLocalizedString(@"添加模型供应商", nil);
        _format = [ProviderFormatOpenAI retain];
        _template = [ProviderIDOpenAI retain];
        _models = [[NSMutableArray array] retain];
        _searchResults = [[NSMutableArray array] retain];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    CGRect frame = self.view.bounds;
    _formTable = [[UITableView alloc] initWithFrame:frame style:UITableViewStyleGrouped];
    _formTable.dataSource = self;
    _formTable.delegate = self;
    _formTable.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                   UIViewAutoresizingFlexibleHeight);
    _formTable.backgroundColor = [UIColor clearColor];
    _formTable.backgroundView = nil;
    _formTable.opaque = NO;
    [_formTable registerClass:[UITableViewCell class] forCellReuseIdentifier:kCellID];
    [_formTable registerClass:[UITableViewCell class] forCellReuseIdentifier:kSegCellID];
    [self.view addSubview:_formTable];

    // Pre-fill the BaseURL field with the template's default (matches the
    // current _template which defaulted to openai → https://api.openai.com).
    if (!_baseURLField) {
        (void)[self _makeBaseURLField];
        _baseURLField.text = [SettingsViewController defaultBaseURLForTemplate:_template];
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_themeChanged)
                                                 name:@"iOS6ThemeDidChangeNotification"
                                                   object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    _formTable.backgroundColor = [UIColor clearColor];
    _formTable.backgroundView = nil;
}

- (void)_themeChanged
{
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    _formTable.backgroundColor = [UIColor clearColor];
    _formTable.backgroundView = nil;
    for (UITextField *f in [NSArray arrayWithObjects:_baseURLField, _apiKeyField, nil]) {
        if (![f isKindOfClass:[UITextField class]]) continue;
        f.backgroundColor = [iOS6Theme inputFieldBackgroundColor];
        f.textColor = [iOS6Theme inputFieldTextColor];
    }
    [_formTable reloadData];
}

#pragma mark - Helpers

- (void)_applyFormat:(NSString *)fmt
{
    if (![fmt isKindOfClass:[NSString class]] || fmt.length == 0) return;
    [_format release];
    _format = [fmt retain];
    // If the current template doesn't belong to the new format, fall back to
    // the first template that does (and update baseURL accordingly).
    if (![[SettingsViewController formatForTemplate:_template] isEqualToString:_format]) {
        NSArray *matching = [SettingsViewController templatesForFormat:_format];
        NSString *newTpl = ([matching count] > 0)
            ? [matching objectAtIndex:0] : ProviderTemplateCustom;
        [self _applyTemplate:newTpl];
    }
    [_formTable reloadData];
}

- (void)_applyTemplate:(NSString *)tpl
{
    if (![tpl isKindOfClass:[NSString class]] || tpl.length == 0) return;
    [_template release];
    _template = [tpl retain];
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
        }
    }
    // Sync format to the template's canonical format.
    NSString *canonFmt = [SettingsViewController formatForTemplate:tpl];
    if (![_format isEqualToString:canonFmt]) {
        [_format release];
        _format = [canonFmt retain];
    }
    [_formTable reloadData];
}

- (UITextField *)_makeBaseURLField
{
    if (_baseURLField) return _baseURLField;
    _baseURLField = [[UITextField alloc] initWithFrame:CGRectZero];
    _baseURLField.borderStyle = UITextBorderStyleRoundedRect;
    _baseURLField.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:14]];
    _baseURLField.autocorrectionType = UITextAutocorrectionTypeNo;
    _baseURLField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _baseURLField.returnKeyType = UIReturnKeyDone;
    _baseURLField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _baseURLField.keyboardType = UIKeyboardTypeURL;
    _baseURLField.delegate = self;
    _baseURLField.backgroundColor = [iOS6Theme inputFieldBackgroundColor];
    _baseURLField.textColor = [iOS6Theme inputFieldTextColor];
    _baseURLField.tag = 100;
    _baseURLField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    if ([iOS6Theme isDarkMode] && [_baseURLField respondsToSelector:@selector(setKeyboardAppearance:)]) {
        [_baseURLField setKeyboardAppearance:UIKeyboardAppearanceAlert];
    }
    return _baseURLField;
}

- (UITextField *)_makeAPIKeyField
{
    if (_apiKeyField) return _apiKeyField;
    _apiKeyField = [[UITextField alloc] initWithFrame:CGRectZero];
    _apiKeyField.borderStyle = UITextBorderStyleRoundedRect;
    _apiKeyField.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:14]];
    _apiKeyField.autocorrectionType = UITextAutocorrectionTypeNo;
    _apiKeyField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _apiKeyField.returnKeyType = UIReturnKeyDone;
    _apiKeyField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _apiKeyField.keyboardType = UIKeyboardTypeDefault;
    _apiKeyField.secureTextEntry = YES;
    _apiKeyField.delegate = self;
    _apiKeyField.backgroundColor = [iOS6Theme inputFieldBackgroundColor];
    _apiKeyField.textColor = [iOS6Theme inputFieldTextColor];
    _apiKeyField.tag = 101;
    _apiKeyField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    if ([iOS6Theme isDarkMode] && [_apiKeyField respondsToSelector:@selector(setKeyboardAppearance:)]) {
        [_apiKeyField setKeyboardAppearance:UIKeyboardAppearanceAlert];
    }
    return _apiKeyField;
}

#pragma mark - Table data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kAASectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == kAASectionFormat)  return 1;
    if (section == kAASectionTemplate) return 1;
    if (section == kAASectionConn)    return 2;   // BaseURL + API Key
    if (section == kAASectionTest)    return 1;
    if (section == kAASectionModels)  return (NSInteger)[_models count] + 2;  // + 搜索 + 手动添加
    if (section == kAASectionSave)    return 1;
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == kAASectionFormat)   return NSLocalizedString(@"提供商格式", nil);
    if (section == kAASectionTemplate) return NSLocalizedString(@"提供商模板", nil);
    if (section == kAASectionConn)     return NSLocalizedString(@"连接", nil);
    if (section == kAASectionTest)     return @"";
    if (section == kAASectionModels)   return NSLocalizedString(@"模型", nil);
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
    if (section == kAASectionFormat) {
        return NSLocalizedString(@"openai=/v1/chat/completions; anthropic=/v1/messages; ollama 原生 /api/chat (本轮按 openai 兼容)。", nil);
    }
    if (section == kAASectionTemplate) {
        return NSLocalizedString(@"模板仅预设 baseURL，不会自动改 format。选自定义可手动填任意 URL。", nil);
    }
    if (section == kAASectionConn) {
        return NSLocalizedString(@"留空 API Key 沿用全局 Key；BaseURL 选模板后自动填，可手动改。", nil);
    }
    if (section == kAASectionModels) {
        return NSLocalizedString(@"搜索 → action sheet → 选模型加入；手动添加 → 输入框输入模型 ID。点行可切换生图/对话类型。", nil);
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

    if (indexPath.section == kAASectionFormat) {
        CGFloat w = cell.contentView.bounds.size.width;
        UISegmentedControl *seg = [[[UISegmentedControl alloc]
            initWithItems:[NSArray arrayWithObjects:
                @"openai", @"anthropic", @"ollama", nil]] autorelease];
        seg.frame = CGRectMake(kPad, (kRowH - 30) / 2.0f, w - 2 * kPad, 30);
        seg.segmentedControlStyle = UISegmentedControlStyleBar;
        seg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        if ([_format isEqualToString:ProviderFormatAnthropic]) seg.selectedSegmentIndex = 1;
        else if ([_format isEqualToString:ProviderFormatOllama]) seg.selectedSegmentIndex = 2;
        else seg.selectedSegmentIndex = 0;
        [seg addTarget:self action:@selector(_formatSegChanged:)
          forControlEvents:UIControlEventValueChanged];
        [cell.contentView addSubview:seg];
        return cell;
    }

    if (indexPath.section == kAASectionTemplate) {
        cell.textLabel.text = NSLocalizedString(@"模板", nil);
        cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        cell.textLabel.textColor = [iOS6Theme textColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        UILabel *val = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
        val.text = [SettingsViewController displayNameForTemplate:_template];
        val.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        val.textColor = [iOS6Theme secondaryTextColor];
        val.backgroundColor = [UIColor clearColor];
        val.textAlignment = NSTextAlignmentRight;
        val.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        CGFloat w = cell.contentView.bounds.size.width;
        val.frame = CGRectMake(kPad + kLabelW + 4, 0, w - kPad - kLabelW - 4 - kPad - 22, kRowH);
        [cell.contentView addSubview:val];
        return cell;
    }

    if (indexPath.section == kAASectionConn) {
        NSString *label = nil;
        UITextField *field = nil;
        NSString *placeholder = nil;
        if (indexPath.row == 0) {
            label = NSLocalizedString(@"BaseURL", nil);
            field = [self _makeBaseURLField];
            placeholder = [SettingsViewController defaultBaseURLForTemplate:_template];
            if (placeholder.length == 0) placeholder = @"https://your-endpoint/v1";
        } else {
            label = NSLocalizedString(@"API Key", nil);
            field = [self _makeAPIKeyField];
            placeholder = NSLocalizedString(@"留空沿用全局 Key", nil);
        }
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(kPad, 0, kLabelW, kRowH)];
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
        field.frame = CGRectMake(kPad + kLabelW + 4, 7, w - kPad - kLabelW - 4 - kPad, kRowH - 14);
        [cell.contentView addSubview:field];
        return cell;
    }

    if (indexPath.section == kAASectionTest) {
        cell.textLabel.text = NSLocalizedString(@"测试连接 (GET /v1/models)", nil);
        cell.textLabel.textColor = [iOS6Theme tintColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        return cell;
    }

    if (indexPath.section == kAASectionModels) {
        NSInteger mc = (NSInteger)[_models count];
        if (indexPath.row < mc) {
            NSDictionary *m = [_models objectAtIndex:indexPath.row];
            NSString *mid = [m objectForKey:@"id"];
            cell.textLabel.text = mid ?: @"?";
            cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
            cell.textLabel.textColor = [iOS6Theme textColor];
            // Kind badge on the right if image.
            CGFloat cw = cell.contentView.bounds.size.width;
            BOOL isImage = [[m objectForKey:@"kind"] isEqualToString:@"image"];
            if (isImage) {
                UILabel *b = [[[UILabel alloc]
                    initWithFrame:CGRectMake(cw - 12 - 40, (44 - 18) / 2, 40, 18)] autorelease];
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
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            return cell;
        }
        if (indexPath.row == mc) {
            // 搜索模型 button row.
            cell.textLabel.text = NSLocalizedString(@"搜索模型 (/v1/models → 加入)", nil);
            cell.textLabel.textColor = [iOS6Theme tintColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            return cell;
        }
        // + 手动添加 row.
        cell.textLabel.text = NSLocalizedString(@"+ 手动添加模型 (输入 ID)", nil);
        cell.textLabel.textColor = [iOS6Theme tintColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        return cell;
    }

    if (indexPath.section == kAASectionSave) {
        cell.textLabel.text = NSLocalizedString(@"保存（设为当前对话模型）", nil);
        cell.textLabel.textColor = [iOS6Theme tintColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:17]];
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        return cell;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == kAASectionTemplate) {
        [self _presentTemplateSheet];
        return;
    }
    if (indexPath.section == kAASectionTest) {
        [self _testConnection];
        return;
    }
    if (indexPath.section == kAASectionModels) {
        NSInteger mc = (NSInteger)[_models count];
        if (indexPath.row < mc) {
            // Toggle the model's kind between chat / image.
            NSMutableDictionary *m = [[_models objectAtIndex:indexPath.row] mutableCopy];
            NSString *curKind = [m objectForKey:@"kind"];
            NSString *newKind = [curKind isEqualToString:@"image"] ? @"chat" : @"image";
            [m setObject:newKind forKey:@"kind"];
            [_models replaceObjectAtIndex:indexPath.row withObject:m];
            [m release];
            [_formTable reloadData];
            return;
        }
        if (indexPath.row == mc) {
            [self _searchModels];
            return;
        }
        // Manual add via alert.
        UIAlertView *av = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"添加模型", nil)
                  message:NSLocalizedString(@"输入模型 ID（如 deepseek-chat）：", nil)
                 delegate:self
        cancelButtonTitle:NSLocalizedString(@"取消", nil)
        otherButtonTitles:NSLocalizedString(@"添加", nil), nil] autorelease];
        [av setAlertViewStyle:UIAlertViewStylePlainTextInput];
        [av setTag:600];
        [av show];
        return;
    }
    if (indexPath.section == kAASectionSave) {
        [self _saveTapped];
        return;
    }
}

- (BOOL)tableView:(UITableView *)tableView
canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return (indexPath.section == kAASectionModels) &&
           (indexPath.row < (NSInteger)[_models count]);
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.section != kAASectionModels) return;
    if (indexPath.row >= (NSInteger)[_models count]) return;
    [_models removeObjectAtIndex:indexPath.row];
    [_formTable reloadData];
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
    NSArray *templates = [SettingsViewController templatesForFormat:_format];
    for (NSString *t in templates) {
        [sheet addButtonWithTitle:[SettingsViewController displayNameForTemplate:t]];
    }
    [sheet setTag:kAASheetTemplate];
    [sheet showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)actionSheet
clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == actionSheet.cancelButtonIndex) return;
    if (actionSheet.tag == kAASheetTemplate) {
        NSArray *templates = [SettingsViewController templatesForFormat:_format];
        NSInteger idx = buttonIndex - 1;
        if (idx >= 0 && idx < (NSInteger)[templates count]) {
            [self _applyTemplate:[templates objectAtIndex:idx]];
        }
        return;
    }
    if (actionSheet.tag == kAASheetQuickPick) {
        NSInteger idx = buttonIndex - 1;
        if (idx < 0 || idx >= (NSInteger)[_searchResults count]) return;
        NSString *mid = [_searchResults objectAtIndex:idx];
        if (!mid.length) return;
        // De-dupe.
        for (NSDictionary *m in _models) {
            if ([[[m objectForKey:@"id"] isEqualToString:mid] boolValue]) return;
        }
        NSMutableDictionary *nm = [NSMutableDictionary dictionary];
        [nm setObject:mid forKey:@"id"];
        [nm setObject:[NSNumber numberWithBool:NO] forKey:@"starred"];
        [nm setObject:@"chat" forKey:@"kind"];
        [_models addObject:nm];
        [_formTable reloadData];
        return;
    }
}

#pragma mark - Alert view

- (void)alertView:(UIAlertView *)alertView
clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (alertView.tag == 600 && buttonIndex == 1) {
        UITextField *tf = [alertView textFieldAtIndex:0];
        NSString *mid = [tf.text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (mid.length == 0) return;
        for (NSDictionary *m in _models) {
            if ([[[m objectForKey:@"id"] isEqualToString:mid] boolValue]) return;
        }
        NSMutableDictionary *nm = [NSMutableDictionary dictionary];
        [nm setObject:mid forKey:@"id"];
        [nm setObject:[NSNumber numberWithBool:NO] forKey:@"starred"];
        [nm setObject:@"chat" forKey:@"kind"];
        [_models addObject:nm];
        [_formTable reloadData];
        return;
    }
}

#pragma mark - Text field delegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    if (textField.tag == 100) {
        // BaseURL edited — re-derive template.
        NSString *v = [textField.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *inferredTpl = [SettingsViewController templateForBaseURL:v];
        if (![inferredTpl isEqualToString:_template]) {
            [self _applyTemplate:inferredTpl];
        }
    }
}

#pragma mark - Test connection

- (void)_testConnection
{
    [_baseURLField resignFirstResponder];
    [_apiKeyField resignFirstResponder];
    NSString *baseURL = [[_baseURLField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"" copy];
    NSString *apiKey  = [[_apiKeyField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"" copy];
    NSString *provider = _template;
    [baseURL autorelease];
    [apiKey autorelease];

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
                        @"ModelAdd test FAIL - %@", desc ?: @"(no response)"]];
                    UIAlertView *fail = [[[UIAlertView alloc]
                        initWithTitle:NSLocalizedString(@"连接失败", nil)
                              message:desc ?: NSLocalizedString(@"无返回,请检查 BaseURL / API Key / 中转 URL", nil)
                             delegate:nil
                    cancelButtonTitle:NSLocalizedString(@"好", nil)
                    otherButtonTitles:nil] autorelease];
                    [fail show];
                } else {
                    [[Logger sharedLogger] info:[NSString stringWithFormat:
                        @"ModelAdd test OK - %lu models", (unsigned long)[rc count]]];
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
    NSString *baseURL = [[_baseURLField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"" copy];
    NSString *apiKey  = [[_apiKeyField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"" copy];
    NSString *provider = _template;
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
                        @"ModelAdd search FAIL - %@", desc ?: @"(no response)"]];
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
    [sheet setTag:kAASheetQuickPick];
    [sheet showInView:self.view];
}

#pragma mark - Save

- (void)_saveTapped
{
    [_baseURLField resignFirstResponder];
    [_apiKeyField resignFirstResponder];
    NSString *baseURL = [[_baseURLField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"" copy];
    NSString *apiKey  = [[_apiKeyField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"" copy];
    [baseURL autorelease]; [apiKey autorelease];

    if ([_models count] == 0) {
        UIAlertView *av = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"未添加任何模型", nil)
                  message:NSLocalizedString(@"请至少添加一个模型（手动输入 ID 或点「搜索模型」从 /v1/models 拉取）。", nil)
                 delegate:nil
        cancelButtonTitle:NSLocalizedString(@"好", nil)
        otherButtonTitles:nil] autorelease];
        [av show];
        return;
    }
    // For non-custom templates, baseURL may be left blank (use template default).
    if (baseURL.length == 0 && ![_template isEqualToString:ProviderTemplateCustom]) {
        baseURL = [[SettingsViewController defaultBaseURLForTemplate:_template] copy];
        [baseURL autorelease];
    }
    if (baseURL.length == 0) {
        UIAlertView *av = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"缺少 BaseURL", nil)
                  message:NSLocalizedString(@"自定义模板必须填写 BaseURL。", nil)
                 delegate:nil
        cancelButtonTitle:NSLocalizedString(@"好", nil)
        otherButtonTitles:nil] autorelease];
        [av show];
        return;
    }

    // Build the new provider entry.
    NSString *pid = [ModelManagementViewController newProviderUUID];
    NSDictionary *newEntry = [NSDictionary dictionaryWithObjectsAndKeys:
                               pid, @"id",
                               _format, @"format",
                               _template, @"template",
                               [SettingsViewController displayNameForTemplate:_template], @"displayName",
                               baseURL, @"baseURL",
                               apiKey, @"apiKey",
                               [NSNumber numberWithBool:NO], @"collapsed",
                               _models, @"models",
                               nil];
    // Append to the saved providers list.
    NSMutableArray *existing = [[ModelManagementViewController savedProviders] mutableCopy];
    [existing addObject:newEntry];
    [ModelManagementViewController saveProviders:existing];
    [existing release];

    // Mark the first model as the active chat / image model — the user
    // added this provider because they want to use it.
    NSDictionary *firstModel = [_models objectAtIndex:0];
    NSString *firstID = [firstModel objectForKey:@"id"];
    if ([firstID isKindOfClass:[NSString class]] && firstID.length > 0) {
        if ([[firstModel objectForKey:@"kind"] isEqualToString:@"image"]) {
            [[NSUserDefaults standardUserDefaults] setObject:firstID
                                                     forKey:SettingsKeyImageGenModel];
        } else {
            [[NSUserDefaults standardUserDefaults] setObject:firstID
                                                     forKey:SettingsKeyModel];
        }
        [[NSUserDefaults standardUserDefaults] synchronize];
    }

    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"ModelAdd saved provider id=%@ format=%@ template=%@ baseURL=%@ keyLen=%lu models=%lu",
        pid, _format, _template, baseURL,
        (unsigned long)apiKey.length, (unsigned long)[_models count]]];

    [self.navigationController popViewControllerAnimated:YES];
}

@end

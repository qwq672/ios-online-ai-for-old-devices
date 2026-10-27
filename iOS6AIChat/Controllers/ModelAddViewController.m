//
//  ModelAddViewController.m
//  iOS6AIChat
//
//  v261025-8: full model-add form page (replaces the old single-field
//  alert). The user picks a provider, fills in the endpoint/key/model,
//  and saves a complete "provider profile" entry that the chat path
//  resolves via +[ModelManagementViewController resolvedConnectionForChat].
//
//    Section 0 — 提供商: tappable row + action-sheet picker
//                (智谱 / DeepSeek / Kimi / OpenAI / Anthropic / Ollama /
//                 自定义). Switching auto-fills the BaseURL field with the
//                provider's default when the field is empty or still holds
//                another provider's default. Anthropic entries are sent
//                with the /v1/messages protocol by NetworkService.
//    Section 1 — 模型类型: segmented (对话模型 / 生图模型) + a 常用模型
//                quick-pick row (provider's well-known models, filtered
//                by the selected kind). 生图 only works on 智谱/OpenAI/
//                自定义 endpoints.
//    Section 2 — 连接: BaseURL row + API Key row (text fields).
//    Section 3 — 模型: 模型 ID row (e.g. "glm-4-flash") + 显示名 row
//                (optional friendly name shown in the management list).
//    Section 4 — 保存: one blue row. Validates the model ID, builds the
//                entry dict, saves via +addModelEntry:, pops back.
//
//  The four text fields are created ONCE and held in ivars, then re-attached
//  to their row's cell on every cellForRowAtIndexPath — the app-wide
//  "rebuild cell subviews" pattern would otherwise destroy the fields (and
//  the user's input with them) on every cell reuse.
//
//  Edit mode: fields are pre-filled from the entry passed to
//  -initWithEntry:; saving replaces the entry in place (same id) or
//  adds a new one when the id changed.
//
//  Memory model: MRC (matches the rest of the codebase).
//  CRITICAL MRC note: every convenience-constructor result assigned to an
//  ivar is RETAINED (see ChatMessageCell's v261025-7 writeup — the
//  un-retained buttonWithType: assignment was the "两轮对话必闪退"
//  over-release crash root cause). alloc/init views are owned by BOTH the
//  ivar and their cell's content view — released once in dealloc, once by
//  the view teardown.
//

#import "ModelAddViewController.h"
#import "iOS6Theme.h"
#import "ModelManagementViewController.h"
#import "SettingsViewController.h"
#import "Logger.h"

static NSString *const kFormCellID = @"ModelAddFormCell";
static NSString *const kSegCellID  = @"ModelAddSegCell";

// Form layout (pt).
static CGFloat const kAARowH = 44.0f;
static CGFloat const kAAPad  = 12.0f;
static CGFloat const kAALabelW = 84.0f;

enum {
    kAASectionProvider = 0,
    kAASectionKind,          // v261025-8: 模型类型 + 常用模型快选
    kAASectionConn,
    kAASectionModel,
    kAASectionSave,
    kAASectionCount
};

// Action-sheet tags.
static NSInteger const kAASheetProvider = 460;   // provider picker
static NSInteger const kAASheetQuickPick = 461;  // 常用模型 quick pick

@interface ModelAddViewController () <UIActionSheetDelegate> {
    UITableView *_formTable;

    // Provider state (v261025-8: string id — includes "custom").
    NSString *_providerID;

    // Model kind: NO = 对话模型 (chat), YES = 生图模型 (image).
    BOOL _kindIsImage;

    // Quick-pick model list (rebuilt when provider/kind changes).
    NSArray *_quickPickModels;

    // Seed values applied to the fields at CREATION time (first build).
    // Released in dealloc. After creation the fields themselves are the
    // source of truth.
    NSString *_seedBaseURL;
    NSString *_seedAPIKey;
    NSString *_seedModelID;
    NSString *_seedDisplayName;

    // Persistent form fields (created once, re-attached to their cells).
    UITextField *_baseURLField;
    UITextField *_apiKeyField;
    UITextField *_modelField;
    UITextField *_displayNameField;

    // Edit-mode state (nil when adding fresh).
    NSDictionary *_editingEntry;
}
@end

@implementation ModelAddViewController

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_formTable release];
    [_providerID release];
    [_quickPickModels release];
    [_seedBaseURL release];
    [_seedAPIKey release];
    [_seedModelID release];
    [_seedDisplayName release];
    // Persistent fields — owned by the ivars (their cells ALSO retain them
    // while attached; by dealloc time the table is already released above,
    // so the cells are gone and we hold the only refs).
    [_baseURLField release];
    [_apiKeyField release];
    [_modelField release];
    [_displayNameField release];
    [_editingEntry release];
    [super dealloc];
}

- (id)initWithEntry:(NSDictionary *)entry
{
    if (self = [super initWithNibName:nil bundle:nil]) {
        if ([entry isKindOfClass:[NSDictionary class]]) {
            _editingEntry = [entry retain];
        }
        self.title = (_editingEntry != nil)
            ? NSLocalizedString(@"编辑模型", nil)
            : NSLocalizedString(@"添加模型", nil);
        [self _loadSeedState];
    }
    return self;
}

- (id)init
{
    return [self initWithEntry:nil];
}

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    // Route everything through initWithEntry: so setup always runs.
    return [self initWithEntry:nil];
}

// Pre-fill the form state from the edit-mode entry (or, when adding fresh,
// from the ACTIVE resolved connection — better defaults than blanks).
- (void)_loadSeedState
{
    NSDictionary *src = _editingEntry;
    if (!src) {
        src = [ModelManagementViewController resolvedConnectionForChat];
    }
    NSString *prov = [src objectForKey:@"provider"];
    if (![prov isKindOfClass:[NSString class]] || prov.length == 0) {
        prov = ProviderIDOpenAI;
    }
    _providerID = [prov copy];

    // v261025-8: kind — from the editing entry, else chat.
    NSString *kind = [_editingEntry objectForKey:@"kind"];
    _kindIsImage = [kind isKindOfClass:[NSString class]] && [kind isEqualToString:@"image"];

    _seedBaseURL = [[src objectForKey:@"baseURL"] copy];
    _seedAPIKey  = [[src objectForKey:@"apiKey"] copy];
    if (_editingEntry) {
        _seedModelID = [[_editingEntry objectForKey:@"id"] copy];
    } else {
        _seedModelID = [[src objectForKey:@"model"] copy];
        if (_seedModelID.length == 0) _seedModelID = @"";
    }
    _seedDisplayName = [[_editingEntry objectForKey:@"displayName"] copy];

    [self _rebuildQuickPickList];
}

// The 常用模型 list for the current provider + kind.
- (void)_rebuildQuickPickList
{
    NSArray *models = [SettingsViewController commonModelsForProvider:_providerID
                                                                 kind:_kindIsImage ? @"image" : @"chat"];
    [_quickPickModels release];
    _quickPickModels = [models retain];
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
    [self.view addSubview:_formTable];

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
    // The persistent fields re-style themselves here (theme colors).
    for (UITextField *f in [NSArray arrayWithObjects:
                            _baseURLField, _apiKeyField, _modelField, _displayNameField, nil]) {
        if (![f isKindOfClass:[UITextField class]]) continue;
        f.backgroundColor = [iOS6Theme inputFieldBackgroundColor];
        f.textColor = [iOS6Theme inputFieldTextColor];
    }
    [_formTable reloadData];
}

#pragma mark - Provider helpers

- (NSString *)_defaultBaseURLForSelectedProvider
{
    if ([_providerID isEqualToString:@"custom"]) return @"";
    return [SettingsViewController defaultBaseURLForProvider:_providerID];
}

- (NSString *)_defaultModelHintForSelectedProvider
{
    if ([_providerID isEqualToString:@"custom"]) return @"自定义模型 ID";
    if (_kindIsImage) {
        NSArray *imgModels = [SettingsViewController commonModelsForProvider:_providerID kind:@"image"];
        if ([imgModels count] > 0) return [imgModels objectAtIndex:0];
        return @"cogview-3plus";
    }
    return [SettingsViewController defaultModelForProvider:_providerID];
}

// Every known provider's default endpoint — used to decide whether the
// BaseURL field still holds an untouched default (auto-replaceable).
- (BOOL)_isDefaultBaseURL:(NSString *)url
{
    if (![url isKindOfClass:[NSString class]]) return NO;
    if (url.length == 0) return YES;   // empty counts as replaceable
    for (NSString *p in [SettingsViewController availableProviderIDs]) {
        if ([url isEqualToString:[SettingsViewController defaultBaseURLForProvider:p]]) {
            return YES;
        }
    }
    return NO;
}

- (void)_applyProvider:(NSString *)newProv
{
    if (![newProv isKindOfClass:[NSString class]] || newProv.length == 0) return;
    [_providerID release];
    _providerID = [newProv retain];
    // Auto-fill BaseURL when it's empty or still an untouched default of
    // a DIFFERENT provider. A user-typed custom URL is never touched.
    if (_baseURLField) {
        NSString *cur = [_baseURLField.text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([self _isDefaultBaseURL:cur]) {
            _baseURLField.text = [self _defaultBaseURLForSelectedProvider];
        }
    }
    [self _rebuildQuickPickList];
    if (_modelField) {
        _modelField.placeholder = [NSString stringWithFormat:
            NSLocalizedString(@"如 %@", nil),
            [self _defaultModelHintForSelectedProvider]];
    }
    [_formTable reloadData];
}

- (void)_kindSegChanged:(UISegmentedControl *)seg
{
    _kindIsImage = (seg.selectedSegmentIndex == 1);
    [self _rebuildQuickPickList];
    if (_modelField) {
        _modelField.placeholder = [NSString stringWithFormat:
            NSLocalizedString(@"如 %@", nil),
            [self _defaultModelHintForSelectedProvider]];
    }
    [_formTable reloadData];
}

#pragma mark - Action sheets (provider picker + quick pick)

- (void)_presentProviderSheet
{
    UIActionSheet *sheet = [[[UIActionSheet alloc]
        initWithTitle:NSLocalizedString(@"选择提供商", nil)
                 delegate:self
        cancelButtonTitle:NSLocalizedString(@"取消", nil)
    destructiveButtonTitle:nil
        otherButtonTitles:nil] autorelease];
    if ([iOS6Theme isDarkMode]) {
        sheet.actionSheetStyle = UIActionSheetStyleBlackOpaque;
    } else {
        sheet.actionSheetStyle = UIActionSheetStyleAutomatic;
    }
    for (NSString *pid in [SettingsViewController availableProviderIDs]) {
        [sheet addButtonWithTitle:[SettingsViewController displayNameForProvider:pid]];
    }
    [sheet addButtonWithTitle:NSLocalizedString(@"自定义", nil)];
    [sheet setTag:kAASheetProvider];
    [sheet showInView:self.view];
}

- (void)_presentQuickPickSheet
{
    if ([_quickPickModels count] == 0) return;
    UIActionSheet *sheet = [[[UIActionSheet alloc]
        initWithTitle:NSLocalizedString(@"常用模型", nil)
                 delegate:self
        cancelButtonTitle:NSLocalizedString(@"取消", nil)
    destructiveButtonTitle:nil
        otherButtonTitles:nil] autorelease];
    if ([iOS6Theme isDarkMode]) {
        sheet.actionSheetStyle = UIActionSheetStyleBlackOpaque;
    } else {
        sheet.actionSheetStyle = UIActionSheetStyleAutomatic;
    }
    for (NSString *m in _quickPickModels) {
        [sheet addButtonWithTitle:m];
    }
    [sheet setTag:kAASheetQuickPick];
    [sheet showInView:self.view];
}

// iOS 6 action sheets: cancel occupies buttonIndex 0; options live at 1..N.
- (void)actionSheet:(UIActionSheet *)actionSheet
clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == actionSheet.cancelButtonIndex) return;
    if (actionSheet.tag == kAASheetProvider) {
        NSArray *providers = [SettingsViewController availableProviderIDs];
        NSInteger idx = buttonIndex - 1;
        NSString *newProv = nil;
        if (idx >= 0 && idx < (NSInteger)[providers count]) {
            newProv = [providers objectAtIndex:idx];
        } else if (idx == (NSInteger)[providers count]) {
            newProv = @"custom";
        }
        if (newProv) {
            [self _applyProvider:newProv];
            [[Logger sharedLogger] info:[NSString stringWithFormat:
                @"ModelAdd provider → %@", newProv]];
        }
        return;
    }
    if (actionSheet.tag == kAASheetQuickPick) {
        NSInteger idx = buttonIndex - 1;
        if (idx >= 0 && idx < (NSInteger)[_quickPickModels count]) {
            NSString *m = [_quickPickModels objectAtIndex:idx];
            if (_modelField && [m isKindOfClass:[NSString class]]) {
                _modelField.text = m;
            }
        }
        return;
    }
}

#pragma mark - Field factory (created once, seeded at creation)

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
    f.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    if (seed.length > 0) f.text = seed;
    *slot = f;
    return f;
}

- (void)_layoutField:(UITextField *)f inCell:(UITableViewCell *)cell
{
    CGFloat w = cell.contentView.bounds.size.width;
    f.frame = CGRectMake(kAAPad + kAALabelW + 4, 7,
                         w - kAAPad - kAALabelW - 8, kAARowH - 14);
    [cell.contentView addSubview:f];
}

#pragma mark - Save

- (void)_saveTapped
{
    // Drop the keyboard first so field values are committed.
    [_baseURLField resignFirstResponder];
    [_apiKeyField resignFirstResponder];
    [_modelField resignFirstResponder];
    [_displayNameField resignFirstResponder];

    NSString *baseURL = [[_baseURLField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    NSString *apiKey  = [[_apiKeyField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    NSString *modelID = [[_modelField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    NSString *display = _displayNameField.text;   // display name keeps spaces

    if (modelID.length == 0) {
        UIAlertView *av = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"缺少模型 ID", nil)
                  message:NSLocalizedString(@"请填写模型 ID（如 glm-4-flash / deepseek-chat / cogview-3plus）。", nil)
                 delegate:nil
        cancelButtonTitle:NSLocalizedString(@"好", nil)
        otherButtonTitles:nil] autorelease];
        [av show];
        [baseURL release];
        [apiKey release];
        [modelID release];
        return;
    }
    BOOL isCustom = [_providerID isEqualToString:@"custom"];
    if (baseURL.length == 0 && !isCustom) {
        [baseURL release];
        baseURL = [[self _defaultBaseURLForSelectedProvider] copy];
    }
    if (baseURL.length == 0) {
        // custom provider with no URL — cannot route the request.
        UIAlertView *av = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"缺少 BaseURL", nil)
                  message:NSLocalizedString(@"自定义提供商必须填写 BaseURL（OpenAI 兼容端点或 Anthropic 端点）。", nil)
                 delegate:nil
        cancelButtonTitle:NSLocalizedString(@"好", nil)
        otherButtonTitles:nil] autorelease];
        [av show];
        [baseURL release];
        [apiKey release];
        [modelID release];
        return;
    }
    // v261025-8: image kind on a provider without an image API — warn but
    // allow (custom endpoints might still be an OpenAI-compat image API).
    if (_kindIsImage && ![SettingsViewController providerSupportsImageGen:_providerID] && !isCustom) {
        UIAlertView *warn = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"该提供商无生图 API", nil)
                  message:NSLocalizedString(@"DeepSeek / Kimi / Anthropic / Ollama 没有公开生图端点。建议改用 智谱 (CogView) 或 OpenAI。仍要保存吗？", nil)
                 delegate:self
        cancelButtonTitle:NSLocalizedString(@"取消", nil)
        otherButtonTitles:NSLocalizedString(@"仍然保存", nil), nil] autorelease];
        [warn setTag:470];
        [warn show];
        return;
    }
    [self _performSaveWithBaseURL:baseURL apiKey:apiKey modelID:modelID display:display];
    [baseURL release];
    [apiKey release];
    [modelID release];
}

// v261025-8: split out so the "provider has no image API" confirm alert
// can re-enter the save path after the user taps 仍然保存.
- (void)_performSaveWithBaseURL:(NSString *)baseURL
                         apiKey:(NSString *)apiKey
                        modelID:(NSString *)modelID
                         display:(NSString *)display
{
    // Build the entry. Only attach the keys that are actually set — an
    // entry without provider/baseURL/apiKey resolves from global settings.
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                  modelID, @"id",
                                  @"user", @"source", nil];
    [entry setObject:(_providerID ?: ProviderIDOpenAI) forKey:@"provider"];
    if (baseURL.length > 0) [entry setObject:baseURL forKey:@"baseURL"];
    if (apiKey.length > 0)  [entry setObject:apiKey forKey:@"apiKey"];
    if (display.length > 0) [entry setObject:display forKey:@"displayName"];
    // v261025-8: model kind — "chat" (default, may be omitted for back-
    // compat) or "image" (生图模型, selectable in the composer).
    if (_kindIsImage) {
        [entry setObject:@"image" forKey:@"kind"];
    }

    [ModelManagementViewController addModelEntry:entry];
    // v261025-8 UX: a freshly added profile becomes the ACTIVE model of its
    // kind — the user added it because they want to use it.
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (_kindIsImage) {
        [d setObject:modelID forKey:SettingsKeyImageGenModel];
    } else {
        [d setObject:modelID forKey:SettingsKeyModel];
    }
    [d synchronize];

    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"ModelAdd saved entry id=%@ provider=%@ kind=%@ baseURL=%@ keyLen=%lu display=%@",
        modelID, _providerID, _kindIsImage ? @"image" : @"chat", baseURL,
        (unsigned long)apiKey.length, display ?: @"(none)"]];

    [self.navigationController popViewControllerAnimated:YES];
}

#pragma mark - Table data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kAASectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == kAASectionProvider) return 1;
    if (section == kAASectionKind)     return 2;   // 模型类型 + 常用模型
    if (section == kAASectionConn)     return 2;   // BaseURL + API Key
    if (section == kAASectionModel)    return 2;   // 模型 ID + 显示名
    if (section == kAASectionSave)     return 1;
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == kAASectionProvider) return NSLocalizedString(@"提供商", nil);
    if (section == kAASectionKind)     return NSLocalizedString(@"类型", nil);
    if (section == kAASectionConn)     return NSLocalizedString(@"连接", nil);
    if (section == kAASectionModel)    return NSLocalizedString(@"模型", nil);
    return @"";
}

// v261025-7: custom TRANSPARENT header/footer views (dark-mode white-bar fix).
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
    if (section == kAASectionProvider) {
        if ([_providerID isEqualToString:ProviderIDAnthropic]) {
            return NSLocalizedString(@"Anthropic 使用原生 /v1/messages 协议（自动适配）。经中转使用需中转服务器 v261025-8 及以上（转发 anthropic 头）。", nil);
        }
        if ([_providerID isEqualToString:@"custom"]) {
            return NSLocalizedString(@"自定义 OpenAI 兼容或 Anthropic 端点。需自行填写 BaseURL。", nil);
        }
        return nil;
    }
    if (section == kAASectionKind) {
        if (_kindIsImage) {
            return NSLocalizedString(@"生图模型 (beta)：发送时走生图端点，提示词直接生成图片。目前智谱 CogView 与 OpenAI 提供。", nil);
        }
        return NSLocalizedString(@"对话模型：常规聊天/推理。点「常用模型」可快速填入该提供商的知名模型。", nil);
    }
    if (section == kAASectionConn) {
        return NSLocalizedString(@"留空 API Key 表示沿用全局设置的 Key；BaseURL 留空自动填该提供商默认端点。", nil);
    }
    if (section == kAASectionModel) {
        return NSLocalizedString(@"显示名仅用于列表展示，可留空。", nil);
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
    // ---- Provider row (tap → action-sheet picker) ------------------------
    if (indexPath.section == kAASectionProvider) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kSegCellID];
        if (!cell) {
            cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:kSegCellID] autorelease];
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        }
        NSArray *oldSubviews = [cell.contentView.subviews copy];
        for (UIView *v in oldSubviews) [v removeFromSuperview];
        [oldSubviews release];
        cell.backgroundColor = [iOS6Theme bubbleAssistantColor];
        cell.textLabel.backgroundColor = [UIColor clearColor];
        cell.textLabel.opaque = NO;
        cell.textLabel.text = NSLocalizedString(@"提供商", nil);
        cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        cell.textLabel.textColor = [iOS6Theme textColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

        // Right-side value label showing the selected provider name.
        UILabel *val = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
        val.text = [SettingsViewController displayNameForProvider:_providerID];
        val.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        val.textColor = [iOS6Theme secondaryTextColor];
        val.backgroundColor = [UIColor clearColor];
        val.textAlignment = NSTextAlignmentRight;
        val.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        CGFloat w = cell.contentView.bounds.size.width;
        val.frame = CGRectMake(kAAPad + kAALabelW + 4, 0,
                               w - kAAPad - kAALabelW - 8 - kAAPad - 22, kAARowH);
        [cell.contentView addSubview:val];
        return cell;
    }

    // ---- Kind section: segmented type + quick-pick row -------------------
    if (indexPath.section == kAASectionKind) {
        if (indexPath.row == 0) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kSegCellID];
            if (!cell) {
                cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                           reuseIdentifier:kSegCellID] autorelease];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            }
            NSArray *oldSubviews = [cell.contentView.subviews copy];
            for (UIView *v in oldSubviews) [v removeFromSuperview];
            [oldSubviews release];
            cell.backgroundColor = [iOS6Theme bubbleAssistantColor];
            cell.textLabel.backgroundColor = [UIColor clearColor];
            cell.textLabel.opaque = NO;
            cell.textLabel.text = NSLocalizedString(@"模型类型", nil);
            cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
            cell.textLabel.textColor = [iOS6Theme textColor];
            cell.accessoryType = UITableViewCellAccessoryNone;

            CGFloat w = cell.contentView.bounds.size.width;
            CGFloat segW = 190.0f;
            UISegmentedControl *seg = [[[UISegmentedControl alloc]
                initWithItems:[NSArray arrayWithObjects:
                    NSLocalizedString(@"对话模型", nil),
                    NSLocalizedString(@"生图模型", nil), nil]] autorelease];
            seg.frame = CGRectMake(w - segW - kAAPad, (kAARowH - 30) / 2.0f, segW, 30);
            seg.segmentedControlStyle = UISegmentedControlStyleBar;
            seg.selectedSegmentIndex = _kindIsImage ? 1 : 0;
            seg.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            [seg addTarget:self action:@selector(_kindSegChanged:)
              forControlEvents:UIControlEventValueChanged];
            [cell.contentView addSubview:seg];
            return cell;
        }
        // Quick-pick row.
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kFormCellID];
        if (!cell) {
            cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:kFormCellID] autorelease];
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        }
        cell.backgroundColor = [iOS6Theme bubbleAssistantColor];
        cell.textLabel.backgroundColor = [UIColor clearColor];
        cell.textLabel.opaque = NO;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if ([_quickPickModels count] > 0) {
            cell.textLabel.text = NSLocalizedString(@"常用模型", nil);
            cell.textLabel.textColor = [iOS6Theme textColor];
            cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        } else {
            cell.textLabel.text = NSLocalizedString(@"常用模型（该提供商暂无）", nil);
            cell.textLabel.textColor = [iOS6Theme secondaryTextColor];
            cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:14]];
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        return cell;
    }

    // ---- Save row ---------------------------------------------------------
    if (indexPath.section == kAASectionSave) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kFormCellID];
        if (!cell) {
            cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:kFormCellID] autorelease];
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        }
        cell.backgroundColor = [iOS6Theme bubbleAssistantColor];
        cell.textLabel.backgroundColor = [UIColor clearColor];
        cell.textLabel.opaque = NO;
        cell.textLabel.text = _kindIsImage
            ? NSLocalizedString(@"保存（设为当前生图模型）", nil)
            : NSLocalizedString(@"保存（设为当前对话模型）", nil);
        cell.textLabel.textColor = [iOS6Theme tintColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:17]];
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    // ---- Text-field rows (BaseURL / API Key / 模型 ID / 显示名) ------------
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kFormCellID];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                   reuseIdentifier:kFormCellID] autorelease];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSArray *oldSubviews = [cell.contentView.subviews copy];
    for (UIView *v in oldSubviews) [v removeFromSuperview];
    [oldSubviews release];
    cell.backgroundColor = [iOS6Theme bubbleAssistantColor];
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.textLabel.opaque = NO;
    cell.textLabel.text = @"";
    cell.accessoryType = UITableViewCellAccessoryNone;

    NSString *label = nil;
    UITextField *field = nil;
    NSString *placeholder = nil;

    if (indexPath.section == kAASectionConn) {
        if (indexPath.row == 0) {
            label = NSLocalizedString(@"BaseURL", nil);
            field = [self _makeField:&_baseURLField
                           seedValue:_seedBaseURL
                          secureText:NO
                        keyboardType:UIKeyboardTypeURL];
            placeholder = [self _defaultBaseURLForSelectedProvider];
            if (placeholder.length == 0) placeholder = @"https://your-endpoint/v1";
        } else {
            label = NSLocalizedString(@"API Key", nil);
            field = [self _makeField:&_apiKeyField
                           seedValue:_seedAPIKey
                          secureText:YES
                        keyboardType:UIKeyboardTypeDefault];
            placeholder = NSLocalizedString(@"留空沿用全局 Key", nil);
        }
    } else if (indexPath.section == kAASectionModel) {
        if (indexPath.row == 0) {
            label = NSLocalizedString(@"模型 ID", nil);
            field = [self _makeField:&_modelField
                           seedValue:_seedModelID
                          secureText:NO
                        keyboardType:UIKeyboardTypeDefault];
            placeholder = [NSString stringWithFormat:
                NSLocalizedString(@"如 %@", nil),
                [self _defaultModelHintForSelectedProvider]];
        } else {
            label = NSLocalizedString(@"显示名", nil);
            field = [self _makeField:&_displayNameField
                           seedValue:_seedDisplayName
                          secureText:NO
                        keyboardType:UIKeyboardTypeDefault];
            placeholder = NSLocalizedString(@"可留空", nil);
        }
    } else {
        return cell;
    }

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(kAAPad, 0, kAALabelW, kAARowH)];
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

    field.placeholder = placeholder;
    [self _layoutField:field inCell:cell];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == kAASectionProvider) {
        [self _presentProviderSheet];
    } else if (indexPath.section == kAASectionKind && indexPath.row == 1) {
        if ([_quickPickModels count] > 0) {
            [self _presentQuickPickSheet];
        }
    } else if (indexPath.section == kAASectionSave) {
        [self _saveTapped];
    }
}

#pragma mark - UIAlertViewDelegate (v261025-8 image-kind confirm)

- (void)alertView:(UIAlertView *)alertView
clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (alertView.tag != 470) return;
    if (buttonIndex != 1) return;   // 取消 → do nothing (fields keep values)
    // 仍然保存 — re-enter the save path.
    [self _saveTappedForce];
}

// Re-run the save with the warning bypassed (user explicitly confirmed).
- (void)_saveTappedForce
{
    NSString *baseURL = [[_baseURLField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    NSString *apiKey  = [[_apiKeyField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    NSString *modelID = [[_modelField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    NSString *display = _displayNameField.text;
    if (modelID.length == 0) {
        [baseURL release]; [apiKey release]; [modelID release];
        return;
    }
    if (baseURL.length == 0 && ![_providerID isEqualToString:@"custom"]) {
        [baseURL release];
        baseURL = [[self _defaultBaseURLForSelectedProvider] copy];
    }
    [self _performSaveWithBaseURL:baseURL apiKey:apiKey modelID:modelID display:display];
    [baseURL release];
    [apiKey release];
    [modelID release];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    return YES;
}

@end

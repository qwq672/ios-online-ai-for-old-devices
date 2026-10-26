//
//  ModelAddViewController.m
//  iOS6AIChat
//
//  v261025-7: full model-add form page.
//
//    Section 0 — 提供商: one row with a segmented control
//                (智谱 / OpenAI / Ollama). Switching auto-fills the
//                BaseURL field with the provider's default when the field
//                is empty or still holds another provider's default.
//    Section 1 — 连接: BaseURL row + API Key row (text fields).
//    Section 2 — 模型: 模型 ID row (e.g. "glm-4-flash") + 显示名 row
//                (optional friendly name shown in the management list).
//    Section 3 — 保存: one blue row. Validates the model ID, builds the
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
    kAASectionConn,
    kAASectionModel,
    kAASectionSave,
    kAASectionCount
};

@interface ModelAddViewController () {
    UITableView *_formTable;

    // Provider state.
    NSArray *_providerIDs;        // {zhipu, openai, ollama}
    NSArray *_providerNames;      // {智谱, OpenAI, Ollama}
    NSInteger _providerIndex;     // selected segment index

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
    [_providerIDs release];
    [_providerNames release];
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
        _providerIDs = [[NSArray arrayWithObjects:
                         ProviderIDZhipu, ProviderIDOpenAI, ProviderIDOllama, nil] retain];
        _providerNames = [[NSArray arrayWithObjects:
                           NSLocalizedString(@"智谱", nil),
                           NSLocalizedString(@"OpenAI", nil),
                           NSLocalizedString(@"Ollama", nil), nil] retain];
        _providerIndex = 1;  // OpenAI default; corrected below.
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
    if (![prov isKindOfClass:[NSString class]]) prov = ProviderIDOpenAI;
    _providerIndex = [_providerIDs indexOfObject:prov];
    if (_providerIndex == NSNotFound) _providerIndex = 1;

    _seedBaseURL = [[src objectForKey:@"baseURL"] copy];
    _seedAPIKey  = [[src objectForKey:@"apiKey"] copy];
    if (_editingEntry) {
        _seedModelID = [[_editingEntry objectForKey:@"id"] copy];
    } else {
        _seedModelID = [[src objectForKey:@"model"] copy];
        if (_seedModelID.length == 0) _seedModelID = @"";
    }
    _seedDisplayName = [[_editingEntry objectForKey:@"displayName"] copy];
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

- (NSString *)_selectedProviderID
{
    if (_providerIndex < 0 || _providerIndex >= (NSInteger)[_providerIDs count]) {
        return ProviderIDOpenAI;
    }
    return [_providerIDs objectAtIndex:_providerIndex];
}

- (NSString *)_defaultBaseURLForSelectedProvider
{
    return [SettingsViewController defaultBaseURLForProvider:[self _selectedProviderID]];
}

- (NSString *)_defaultModelHintForSelectedProvider
{
    return [SettingsViewController defaultModelForProvider:[self _selectedProviderID]];
}

// Every known provider's default endpoint — used to decide whether the
// BaseURL field still holds an untouched default (auto-replaceable).
- (BOOL)_isDefaultBaseURL:(NSString *)url
{
    if (![url isKindOfClass:[NSString class]]) return NO;
    for (NSString *p in _providerIDs) {
        if ([url isEqualToString:[SettingsViewController defaultBaseURLForProvider:p]]) {
            return YES;
        }
    }
    return NO;
}

- (void)_providerSegChanged:(UISegmentedControl *)seg
{
    _providerIndex = seg.selectedSegmentIndex;
    // Auto-fill BaseURL when it's empty or still an untouched default of
    // a DIFFERENT provider. A user-typed custom URL is never touched.
    if (_baseURLField) {
        NSString *cur = [_baseURLField.text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (cur.length == 0 || [self _isDefaultBaseURL:cur]) {
            _baseURLField.text = [self _defaultBaseURLForSelectedProvider];
        }
    }
    // Update the model field placeholder hint.
    if (_modelField) {
        _modelField.placeholder = [NSString stringWithFormat:
            NSLocalizedString(@"如 %@", nil),
            [self _defaultModelHintForSelectedProvider]];
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
                  message:NSLocalizedString(@"请填写模型 ID（如 gpt-4o / glm-4-flash / llama3.2）。", nil)
                 delegate:nil
        cancelButtonTitle:NSLocalizedString(@"好", nil)
        otherButtonTitles:nil] autorelease];
        [av show];
        [baseURL release];
        [apiKey release];
        [modelID release];
        return;
    }
    if (baseURL.length == 0) {
        [baseURL release];
        baseURL = [[self _defaultBaseURLForSelectedProvider] copy];
    }

    // Build the entry. Only attach the keys that are actually set — an
    // entry without provider/baseURL/apiKey resolves from global settings.
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                  modelID, @"id",
                                  @"user", @"source", nil];
    [entry setObject:[self _selectedProviderID] forKey:@"provider"];
    if (baseURL.length > 0) [entry setObject:baseURL forKey:@"baseURL"];
    if (apiKey.length > 0)  [entry setObject:apiKey forKey:@"apiKey"];
    if (display.length > 0) [entry setObject:display forKey:@"displayName"];

    [ModelManagementViewController addModelEntry:entry];
    // v261025-7 UX decision: a freshly added profile becomes the ACTIVE
    // model — the user added it because they want to use it.
    [[NSUserDefaults standardUserDefaults] setObject:modelID forKey:SettingsKeyModel];
    [[NSUserDefaults standardUserDefaults] synchronize];

    [[Logger sharedLogger] info:[NSString stringWithFormat:
        @"ModelAdd saved entry id=%@ provider=%@ baseURL=%@ keyLen=%lu display=%@",
        modelID, [self _selectedProviderID], baseURL,
        (unsigned long)apiKey.length, display ?: @"(none)"]];

    [baseURL release];
    [apiKey release];
    [modelID release];
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
    if (section == kAASectionConn)     return 2;   // BaseURL + API Key
    if (section == kAASectionModel)    return 2;   // 模型 ID + 显示名
    if (section == kAASectionSave)     return 1;
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == kAASectionProvider) return NSLocalizedString(@"提供商", nil);
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
    // Provider row has its own reuse id (segmented control cell).
    if (indexPath.section == kAASectionProvider) {
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
        cell.textLabel.text = NSLocalizedString(@"提供商", nil);
        cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        cell.textLabel.textColor = [iOS6Theme textColor];

        CGFloat w = cell.contentView.bounds.size.width;
        CGFloat segW = w - kAAPad * 2 - kAALabelW;
        if (segW < 150) segW = w - kAAPad * 2 - 60;
        UISegmentedControl *seg = [[[UISegmentedControl alloc]
            initWithItems:_providerNames] autorelease];
        seg.frame = CGRectMake(kAAPad + kAALabelW, (kAARowH - 30) / 2.0f, segW, 30);
        seg.segmentedControlStyle = UISegmentedControlStyleBar;
        seg.selectedSegmentIndex = _providerIndex;
        seg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [seg addTarget:self action:@selector(_providerSegChanged:)
          forControlEvents:UIControlEventValueChanged];
        [cell.contentView addSubview:seg];
        return cell;
    }

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
        cell.textLabel.text = NSLocalizedString(@"保存", nil);
        cell.textLabel.textColor = [iOS6Theme tintColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:17]];
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    // Text-field rows (BaseURL / API Key / 模型 ID / 显示名).
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
    if (indexPath.section == kAASectionSave) {
        [self _saveTapped];
    }
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    return YES;
}

@end

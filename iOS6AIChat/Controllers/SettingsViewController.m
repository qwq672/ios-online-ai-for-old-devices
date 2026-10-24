//
//  SettingsViewController.m
//  iOS6AIChat
//
//  Complete rewrite with cleaner layout per user feedback:
//    - Each row: left label + right control (clearly separated)
//    - Text fields use UITextBorderStyleRoundedRect (visible borders)
//    - Provider is an inline UISegmentedControl (3 segments), NOT a popup alert
//    - Font size is a UISegmentedControl (5 segments)
//    - Tavily max results is a UIStepper with live value label
//    - All controls have autoresizingMask for flexible width
//
//  Sections:
//    0) 主题       — dark mode toggle, font size segmented
//    1) 中转       — toggle, transit URL, provider segmented
//    2) 直连       — BaseURL, API Key (hidden when transit ON)
//    3) 模型       — model text field + 搜索 button
//    4) 联网搜索   — toggle, Tavily key, result count stepper
//    5) 提示词     — system prompt
//    6) 关于       — author / email / version / github / license
//    7) 重置
//

#import "SettingsViewController.h"
#import "iOS6Theme.h"
#import "NetworkService.h"
#import <QuartzCore/QuartzCore.h>

NSString *const SettingsKeyDarkMode           = @"darkMode";
NSString *const SettingsKeyFontSize           = @"fontSize";
NSString *const SettingsKeyUseTransit         = @"useTransit";
NSString *const SettingsKeyTransitURL          = @"transitURL";
NSString *const SettingsKeyProvider            = @"provider";
NSString *const SettingsKeyBaseURL              = @"baseURL";
NSString *const SettingsKeyAPIKey              = @"apiKey";
NSString *const SettingsKeyModel               = @"model";
NSString *const SettingsKeyModelList           = @"modelList";
NSString *const SettingsKeyTemperature         = @"temperature";
NSString *const SettingsKeySystemPrompt       = @"systemPrompt";
NSString *const SettingsKeyWebSearchEnabled = @"webSearchEnabled";
NSString *const SettingsKeyTavilyAPIKey      = @"tavilyAPIKey";
NSString *const SettingsKeyTavilyMaxResults  = @"tavilyMaxResults";
NSString *const SettingsKeyImageMaxDim = @"imageMaxDim";
NSString *const SettingsKeyModelSupportsImages = @"modelSupportsImages";
NSString *const SettingsKeyModelSupportsThinking = @"modelSupportsThinking";
NSString *const SettingsKeyStreamingOutput = @"streamingOutput";

NSString *const ProviderIDZhipu  = @"zhipu";
NSString *const ProviderIDOpenAI = @"openai";
NSString *const ProviderIDOllama = @"ollama";

NSString *const iOS6ThemeDidChangeNotification = @"iOS6ThemeDidChangeNotification";

static NSString *const kDefaultTransitURL = @"https://ai-transit.awa.lat";

// Layout constants.
static CGFloat const kLabelWidth = 80.0f;
static CGFloat const kPad = 12.0f;
static CGFloat const kRowH = 44.0f;

enum {
    kSectionTheme = 0,
    kSectionTransit,
    kSectionDirect,
    kSectionModel,
    kSectionWebSearch,
    kSectionPrompt,
    kSectionAdvanced,   // 流式输出 + 使用中转服务器模型 + 支持思考
    kSectionAbout,
    kSectionReset,
    kSectionCount
};

@interface SettingsViewController ()
@property (nonatomic, retain) NSMutableDictionary *fields;        // key -> UITextField
@property (nonatomic, assign) BOOL useTransit;
@property (nonatomic, copy)   NSString *provider;
@property (nonatomic, retain) NSMutableArray *availableModels;
@property (nonatomic, retain) NSString *pendingDeleteModel;  // tag-700 deletion target
@end

@implementation SettingsViewController

@synthesize tableView=_tableView, fields=_fields, useTransit=_useTransit,
            provider=_provider, availableModels=_availableModels,
            pendingDeleteModel=_pendingDeleteModel;

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if (self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil]) {
        self.title = NSLocalizedString(@"设置", nil);
        _fields = [[NSMutableDictionary alloc] init];
        _availableModels = [[NSMutableArray array] retain];
        NSDictionary *loaded = [SettingsViewController loadSettings];
        _useTransit = [[loaded objectForKey:SettingsKeyUseTransit] boolValue];
        self.provider = [loaded objectForKey:SettingsKeyProvider];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_tableView release];
    [_fields release];
    [_provider release];
    [_availableModels release];
    [_pendingDeleteModel release];
    [super dealloc];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self _applyTheme];
    CGRect frame = self.view.bounds;
    _tableView = [[UITableView alloc] initWithFrame:frame style:UITableViewStyleGrouped];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                    UIViewAutoresizingFlexibleHeight);
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;  // remove iOS 6 default striped pattern
    _tableView.opaque = NO;
    [self.view addSubview:_tableView];

    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self action:@selector(resetToDefaults)] autorelease];

    // Subscribe to theme-change notifications so dark mode / font size
    // toggles refresh this view immediately.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_themeChanged)
                                                 name:iOS6ThemeDidChangeNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self _applyTheme];
    [_tableView reloadData];
}

- (void)_applyTheme
{
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;  // remove iOS 6 default striped pattern
    // Re-style the nav bar with the current dark/light mode.
    // Tab bar icons are set once at launch — do NOT re-style here
    // (styleNavigationController resets tabBarItem to system icon)
}

- (void)_themeChanged
{
    [self _applyTheme];
    [_tableView reloadData];
}

#pragma mark - Persistence helpers

+ (NSDictionary *)loadSettings
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSNumber *useTransitNum = [d objectForKey:SettingsKeyUseTransit];
    BOOL useTransit = useTransitNum ? [useTransitNum boolValue] : NO;
    NSNumber *darkNum = [d objectForKey:SettingsKeyDarkMode];
    BOOL dark = darkNum ? [darkNum boolValue] : NO;
    NSInteger fontSize = [d integerForKey:SettingsKeyFontSize];
    if (fontSize < 0 || fontSize > 4) fontSize = 1;
    NSInteger tavMax = [d integerForKey:SettingsKeyTavilyMaxResults];
    if (tavMax < 1 || tavMax > 8) tavMax = 4;

    return @{
        SettingsKeyDarkMode:           @(dark),
        SettingsKeyFontSize:           @(fontSize),
        SettingsKeyUseTransit:         @(useTransit),
        SettingsKeyTransitURL:          [d stringForKey:SettingsKeyTransitURL] ?: kDefaultTransitURL,
        SettingsKeyProvider:            [d stringForKey:SettingsKeyProvider]   ?: ProviderIDOpenAI,
        SettingsKeyBaseURL:             [d stringForKey:SettingsKeyBaseURL]    ?: @"https://api.openai.com",
        SettingsKeyAPIKey:              [d stringForKey:SettingsKeyAPIKey]     ?: @"",
        SettingsKeyModel:               [d stringForKey:SettingsKeyModel]      ?: [self defaultModelForProvider:[d stringForKey:SettingsKeyProvider] ?: ProviderIDOpenAI],
        SettingsKeyTemperature:         @([d objectForKey:SettingsKeyTemperature] ? [[d stringForKey:SettingsKeyTemperature] floatValue] : 0.7f),
        SettingsKeySystemPrompt:        [d stringForKey:SettingsKeySystemPrompt] ?: NSLocalizedString(@"You are a helpful assistant.", nil),
        SettingsKeyWebSearchEnabled:    @([d boolForKey:SettingsKeyWebSearchEnabled]),
        SettingsKeyTavilyAPIKey:        [d stringForKey:SettingsKeyTavilyAPIKey] ?: @"",
        SettingsKeyTavilyMaxResults:    @(tavMax)
    };
}

+ (void)saveSettings:(NSDictionary *)dict
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for (NSString *key in dict.allKeys) {
        id v = [dict objectForKey:key];
        if ([v isKindOfClass:[NSString class]]) {
            [d setObject:v forKey:key];
        } else if ([v isKindOfClass:[NSNumber class]]) {
            NSNumber *num = (NSNumber *)v;
            if (strcmp([num objCType], @encode(BOOL)) == 0) {
                [d setBool:[num boolValue] forKey:key];
            } else if (strcmp([num objCType], @encode(float)) == 0 ||
                       strcmp([num objCType], @encode(double)) == 0) {
                [d setFloat:[num floatValue] forKey:key];
            } else {
                [d setObject:num forKey:key];
            }
        }
    }
    [d synchronize];
}

+ (NSArray *)availableProviderIDs
{
    return @[ProviderIDOpenAI, ProviderIDZhipu, ProviderIDOllama];
}

+ (NSString *)displayNameForProvider:(NSString *)providerID
{
    if ([providerID isEqualToString:ProviderIDZhipu])  return @"智谱";
    if ([providerID isEqualToString:ProviderIDOpenAI]) return @"OpenAI";
    if ([providerID isEqualToString:ProviderIDOllama]) return @"Ollama";
    return providerID ?: @"Custom";
}

+ (NSString *)defaultModelForProvider:(NSString *)providerID
{
    if ([providerID isEqualToString:ProviderIDZhipu])  return @"glm-4-flash";
    if ([providerID isEqualToString:ProviderIDOpenAI]) return @"gpt-4o-mini";
    if ([providerID isEqualToString:ProviderIDOllama]) return @"llama3.2";
    return @"gpt-4o-mini";
}

- (void)resetToDefaults
{
    UIAlertView *av = [[[UIAlertView alloc]
                        initWithTitle:NSLocalizedString(@"重置设置", nil)
                              message:NSLocalizedString(@"确定要把所有设置恢复默认吗？", nil)
                             delegate:self
                    cancelButtonTitle:NSLocalizedString(@"取消", nil)
                    otherButtonTitles:NSLocalizedString(@"确定", nil), nil] autorelease];
    // Dark mode alert style — UIActionSheetStyle and UIAlertView don't
    // have a "dark" mode on iOS 6, but using the alertSheet style
    // (available via the private delegate) is risky. Best we can do
    // is leave the system default which still contrasts OK on dark.
    [av setTag:100];
    [av show];
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView
clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (alertView.tag == 100 && buttonIndex == 1) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        for (NSString *key in @[SettingsKeyDarkMode, SettingsKeyFontSize,
                                SettingsKeyUseTransit, SettingsKeyTransitURL,
                                SettingsKeyProvider, SettingsKeyBaseURL,
                                SettingsKeyAPIKey, SettingsKeyModel,
                                SettingsKeyModelList,    // v261024-14: reset saved model list too
                                SettingsKeyTemperature, SettingsKeySystemPrompt,
                                SettingsKeyWebSearchEnabled, SettingsKeyTavilyAPIKey,
                                SettingsKeyTavilyMaxResults]) {
            [d removeObjectForKey:key];
        }
        [d synchronize];

        NSDictionary *loaded = [SettingsViewController loadSettings];
        self.useTransit = [[loaded objectForKey:SettingsKeyUseTransit] boolValue];
        self.provider   = [loaded objectForKey:SettingsKeyProvider];
        [iOS6Theme setDarkMode:[[loaded objectForKey:SettingsKeyDarkMode] boolValue]];
        [iOS6Theme setFontSize:[[loaded objectForKey:SettingsKeyFontSize] integerValue]];
        [[NSNotificationCenter defaultCenter] postNotificationName:iOS6ThemeDidChangeNotification object:nil];

        [_fields release];
        _fields = [[NSMutableDictionary alloc] init];
        [_tableView reloadData];
        return;
    }
    // Tag 700: confirm model deletion.
    if (alertView.tag == 700 && buttonIndex == 1) {
        NSString *m = _pendingDeleteModel;
        if (m && m.length > 0) {
            [self _removeModelFromList:m];
            // If we just deleted the currently-active default, fall back
            // to the first item in the remaining list (or the provider
            // default if the list is now empty).
            NSDictionary *settings = [SettingsViewController loadSettings];
            NSString *cur = [settings objectForKey:SettingsKeyModel];
            if ([cur isEqualToString:m]) {
                NSArray *list = [self _modelList];
                NSString *newDef = [list count] > 0
                                    ? [list objectAtIndex:0]
                                    : [SettingsViewController defaultModelForProvider:_provider];
                NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
                [d setObject:newDef forKey:SettingsKeyModel];
                [d synchronize];
            }
            [_fields release];
            _fields = [[NSMutableDictionary alloc] init];
            [_tableView reloadData];
        }
        self.pendingDeleteModel = nil;
        return;
    }
}

#pragma mark - Table data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    // Always show ALL sections. The Transit section is now independent
    // of the useTransit toggle — user can configure 中转搜索 even when
    // 中转总开关 is OFF.
    return kSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSInteger logical = [self _logicalSectionForDisplayed:section];
    switch (logical) {
        case kSectionTheme:     return 3;  // dark mode, font size, image compression
        case kSectionTransit:    return 5;  // 使用中转 / Transit URL / Provider / 中转网络搜索 / 中转默认模型
        case kSectionDirect:     return 2;
        case kSectionModel:      return 7;  // Model + 搜索 / hint / 保存到列表 / 从列表选择默认 / 删除已保存 / 支持图片识别 / 支持思考
        case kSectionWebSearch:  return 3;
        case kSectionPrompt:     return 1;
        case kSectionAdvanced:   return 1;  // 流式输出
        case kSectionAbout:      return 5;  // author / email / version / github / license
        case kSectionReset:      return 1;
        default: return 0;
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSInteger logical = [self _logicalSectionForDisplayed:indexPath.section];
    if (logical == kSectionAbout && indexPath.row == 2) {
        // Version row — taller because the string is longer.
        return kRowH + 10;
    }
    return kRowH;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    // Custom header view — no default shadow (which looks bad in dark mode).
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    if (!title || title.length == 0) return nil;
    UIView *header = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 30)] autorelease];
    header.backgroundColor = [UIColor clearColor];
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectMake(16, 8, tableView.bounds.size.width - 32, 20)] autorelease];
    label.text = title;
    label.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:13]];
    label.textColor = [iOS6Theme secondaryTextColor];
    label.backgroundColor = [UIColor clearColor];
    // No shadowOffset — this removes the iOS 6 default text shadow that
    // looks like "glow" in dark mode.
    label.shadowColor = nil;
    label.shadowOffset = CGSizeZero;
    [header addSubview:label];
    return header;
}

- (NSString *)tableView:(UITableView *)tableView
titleForHeaderInSection:(NSInteger)section
{
    NSInteger logical = [self _logicalSectionForDisplayed:section];
    switch (logical) {
        case kSectionTheme:     return NSLocalizedString(@"主题", nil);
        case kSectionTransit:    return NSLocalizedString(@"中转服务器", nil);
        case kSectionDirect:     return NSLocalizedString(@"直连后端", nil);
        case kSectionModel:      return NSLocalizedString(@"模型", nil);
        case kSectionWebSearch:  return NSLocalizedString(@"联网搜索 (Tavily)", nil);
        case kSectionPrompt:     return NSLocalizedString(@"系统提示词", nil);
        case kSectionAdvanced:   return NSLocalizedString(@"高级", nil);
        case kSectionAbout:      return NSLocalizedString(@"关于", nil);
        default: return @"";
    }
}

- (NSString *)tableView:(UITableView *)tableView
titleForFooterInSection:(NSInteger)section
{
    NSInteger logical = [self _logicalSectionForDisplayed:section];
    switch (logical) {
        case kSectionTransit:
            return NSLocalizedString(@"中转是预制可关闭的开关。开则所有 AI 请求经中转服务器路由，iOS 6 上规避 TLS 兼容问题。关则直连。中转搜索独立控制 Tavily 走不走中转。默认 api-ai.awa.lat，可自建：github.com/qwq672/online-ai-transit-server", nil);
        case kSectionDirect:
            return NSLocalizedString(@"直连后端配置。BaseURL 必须 OpenAI 兼容格式。API Key 作 Authorization: Bearer 发出。即使开启中转也可保留此处配置作为回退。", nil);
        case kSectionModel:
            return NSLocalizedString(@"点「搜索」从 /v1/models 拉取模型；可手填。「保存到列表」加入常用模型，之后用「从列表选择默认」一键切换。", nil);
        case kSectionWebSearch:
            return NSLocalizedString(@"开关后 AI 自主决定是否调用 Tavily 搜索（tool_calls 模式）。结果数 1-8。", nil);
        case kSectionAdvanced:
            return NSLocalizedString(@"流式输出关闭后等 AI 全部回复完才显示。", nil);
        default: return @"";
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
              cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *kID = @"SettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kID];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                       reuseIdentifier:kID] autorelease];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.contentView.backgroundColor = [iOS6Theme bubbleAssistantColor];
    }
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];
    // Reset cell properties to prevent reuse artifacts.
    cell.textLabel.text = @"";
    cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
    cell.textLabel.textColor = [iOS6Theme textColor];
    cell.textLabel.textAlignment = NSTextAlignmentLeft;
    cell.textLabel.numberOfLines = 1;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.contentView.backgroundColor = [iOS6Theme bubbleAssistantColor];
    cell.backgroundColor = [iOS6Theme bubbleAssistantColor];

    NSInteger logical = [self _logicalSectionForDisplayed:indexPath.section];
    NSDictionary *settings = [SettingsViewController loadSettings];

    switch (logical) {
        case kSectionTheme:
            return [self _themeCellForRow:indexPath.row cell:cell];
        case kSectionTransit:
            return [self _transitCellForRow:indexPath.row cell:cell settings:settings];
        case kSectionDirect:
            return [self _directCellForRow:indexPath.row cell:cell settings:settings];
        case kSectionModel:
            return [self _modelCellForRow:indexPath.row cell:cell settings:settings];
        case kSectionWebSearch:
            return [self _webSearchCellForRow:indexPath.row cell:cell settings:settings];
        case kSectionPrompt:
            return [self _promptCell:cell settings:settings];
        case kSectionAdvanced:
            return [self _advancedCellForRow:indexPath.row cell:cell settings:settings];
        case kSectionAbout:
            return [self _aboutCellForRow:indexPath.row cell:cell];
        case kSectionReset:
            return [self _resetCell:cell];
        default:
            return cell;
    }
}

#pragma mark - Cell builders (one per section)

// Helper: build a left-aligned label.
- (UILabel *)_labelWithText:(NSString *)text
{
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(kPad, 0, kLabelWidth, kRowH)];
    l.text = text;
    l.backgroundColor = [UIColor clearColor];
    l.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
    l.textColor = [iOS6Theme textColor];
    l.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
    return [l autorelease];
}

// Helper: build a text field filling the right side of the cell.
- (UITextField *)_textFieldWithFrame:(CGRect)frame
                                 key:(NSString *)key
                           placeholder:(NSString *)ph
                             isSecure:(BOOL)secure
                            keyboardType:(UIKeyboardType)kbdType
{
    UITextField *f = [[UITextField alloc] initWithFrame:frame];
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:14]];
    f.placeholder = ph;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.returnKeyType = UIReturnKeyDone;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.keyboardType = kbdType;
    f.secureTextEntry = secure;
    f.delegate = self;
    // Use theme colors so dark mode actually shows the input text.
    f.backgroundColor = [iOS6Theme inputFieldBackgroundColor];
    f.textColor = [iOS6Theme inputFieldTextColor];
    // iOS 6 doesn't expose a public placeholder color property on
    // UITextField. We can't fix the placeholder being grey-on-grey, but
    // we can set keyboardAppearance to dark so the keyboard itself
    // matches.
    if ([iOS6Theme isDarkMode] && [f respondsToSelector:@selector(setKeyboardAppearance:)]) {
        [f setKeyboardAppearance:UIKeyboardAppearanceAlert];
    }
    f.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin;
    // Store the NSUserDefaults key on the field itself so _persistField
    // can look it up. iOS 6+ has restorationIdentifier (a string property
    // intended for UIStateRestoration but works as a free-form tag here).
    if ([f respondsToSelector:@selector(setRestorationIdentifier:)]) {
        [f setRestorationIdentifier:key];
    }
    [f addTarget:self action:@selector(_fieldChanged:)
    forControlEvents:UIControlEventEditingChanged];
    [self _registerField:f forKey:key];
    return [f autorelease];
}

// Helper: build a UISegmentedControl styled for dark mode.
// On iOS 6, UISegmentedControl doesn't auto-darken. We use tintColor
// (iOS 6+) to set the background. We use setTitleTextAttributes:forState:
// to set per-state text colors — this iOS 5+ method applies to ALL
// segments but the state determines which color is used (so selected
// segments show white, unselected show textColor).
- (UISegmentedControl *)_themedSegmentedControlWithItems:(NSArray *)items
{
    UISegmentedControl *seg = [[[UISegmentedControl alloc] initWithItems:items] autorelease];
    seg.tintColor = [iOS6Theme controlBackgroundColor];
    UIColor *normalColor = [iOS6Theme textColor];
    UIColor *selectedColor = [UIColor whiteColor];
    // setTitleTextAttributes:forState: applies to ALL segments but only
    // for the given state. We set Normal to textColor and Selected to white.
    [seg setTitleTextAttributes:@{NSForegroundColorAttributeName: normalColor,
                                    NSFontAttributeName: [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:13]]}
                      forState:UIControlStateNormal];
    [seg setTitleTextAttributes:@{NSForegroundColorAttributeName: selectedColor}
                      forState:UIControlStateSelected];
    return seg;
}

- (void)_registerField:(UITextField *)f forKey:(NSString *)key
{
    // _fields is set up in init. Avoid the dangling-pointer bug by re-initing if needed.
    if (!_fields) {
        [_fields release];
        _fields = [[NSMutableDictionary alloc] init];
    }
    [_fields setObject:f forKey:key];
}

#pragma mark - Model list helpers (v261024-14)

// Default model list per provider — used to seed the saved-model list
// on first launch (or after reset) so the user has something to pick
// from without having to type or /v1/models-search first.
+ (NSArray *)_defaultModelListForProvider:(NSString *)providerID
{
    if ([providerID isEqualToString:ProviderIDZhipu]) {
        return @[@"glm-4-plus", @"glm-4-air", @"glm-4-flash", @"glm-4-long"];
    }
    if ([providerID isEqualToString:ProviderIDOpenAI]) {
        return @[@"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo", @"gpt-3.5-turbo"];
    }
    if ([providerID isEqualToString:ProviderIDOllama]) {
        return @[@"llama3.2", @"qwen2.5", @"phi3", @"gemma2"];
    }
    return @[@"gpt-4o-mini"];
}

// Read the saved model list from NSUserDefaults. Stored as a JSON-encoded
// NSString because iOS 6 NSUserDefaults can't directly hold NSArray of
// NSString in some edge cases (the Apple docs say it can, but in practice
// on iOS 6 the array sometimes loses its element type after relaunch).
// JSON round-trip is safe and the bytes are tiny.
- (NSArray *)_modelList
{
    NSString *json = [[NSUserDefaults standardUserDefaults]
                       stringForKey:SettingsKeyModelList];
    if (!json || json.length == 0) {
        // First launch — seed from provider defaults.
        NSArray *seed = [SettingsViewController _defaultModelListForProvider:_provider];
        [self _saveModelList:seed];
        return seed;
    }
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err = nil;
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data
                                                   options:0
                                                     error:&err];
    if (err || ![arr isKindOfClass:[NSArray class]]) {
        // Corrupt JSON — re-seed.
        NSArray *seed = [SettingsViewController _defaultModelListForProvider:_provider];
        [self _saveModelList:seed];
        return seed;
    }
    // Filter non-string entries defensively.
    NSMutableArray *out = [NSMutableArray array];
    for (id e in arr) {
        if ([e isKindOfClass:[NSString class]] && [(NSString *)e length] > 0) {
            [out addObject:e];
        }
    }
    return out;
}

- (void)_saveModelList:(NSArray *)list
{
    // De-duplicate while preserving order.
    NSMutableArray *seen = [NSMutableArray array];
    for (NSString *m in list) {
        if (![seen containsObject:m]) [seen addObject:m];
    }
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:seen
                                                    options:0
                                                      error:&err];
    if (err || !data) {
        // Fallback: store as plain comma-separated string.
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

- (void)_addModelToList:(NSString *)model
{
    if (!model || model.length == 0) return;
    NSArray *cur = [self _modelList];
    if ([cur containsObject:model]) return;  // already saved
    NSMutableArray *arr = [NSMutableArray arrayWithArray:cur];
    [arr addObject:model];
    [self _saveModelList:arr];
}

- (void)_removeModelFromList:(NSString *)model
{
    if (!model || model.length == 0) return;
    NSArray *cur = [self _modelList];
    NSMutableArray *arr = [NSMutableArray array];
    for (NSString *m in cur) {
        if (![m isEqualToString:model]) [arr addObject:m];
    }
    [self _saveModelList:arr];
}

- (IBAction)_modelListChanged:(id)sender { /* stub, never called */ }

- (UITableViewCell *)_themeCellForRow:(NSInteger)row cell:(UITableViewCell *)cell
{
    if (row == 0) {
        // Dark mode toggle.
        [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"深色模式", nil)]];
        UISwitch *sw = [[[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 79, 27)] autorelease];
        [sw setOn:[iOS6Theme isDarkMode] animated:NO];
        [sw addTarget:self action:@selector(_darkModeToggle:)
         forControlEvents:UIControlEventValueChanged];
        sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        CGRect f = cell.contentView.bounds;
        sw.frame = CGRectMake(f.size.width - 79 - kPad, (kRowH - 27) / 2, 79, 27);
        [cell.contentView addSubview:sw];
        return cell;
    }
    if (row == 1) {
        // Font size segmented control.
    [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"字号", nil)]];
    NSArray *items = @[@"S", @"M", @"L", @"XL", @"XXL"];
    UISegmentedControl *seg = [self _themedSegmentedControlWithItems:items];
    seg.selectedSegmentIndex = (NSInteger)[iOS6Theme fontSize];
    [seg addTarget:self action:@selector(_fontSizeChanged:)
     forControlEvents:UIControlEventValueChanged];
    seg.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    CGRect f = cell.contentView.bounds;
    seg.frame = CGRectMake(f.size.width - 165 - kPad, (kRowH - 30) / 2, 165, 30);
    [cell.contentView addSubview:seg];
    return cell;
    }
    if (row == 2) {
        // Image compression setting. Default = 1024 (was 0 = "原图"
        // before, which made users send multi-MB iPhone photos and
        // blow up the API request. Now defaults to 1024 — user can
        // still pick "原图" if they really want full-resolution.)
        [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"图片压缩", nil)]];
        NSArray *imgItems = @[@"原图", @"1024", @"2048"];
        UISegmentedControl *imgSeg = [self _themedSegmentedControlWithItems:imgItems];
        // If the key was never set, default to index 1 (1024).
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (![d objectForKey:@"imageMaxDim"]) {
            imgSeg.selectedSegmentIndex = 1;
            [d setInteger:1024 forKey:@"imageMaxDim"];
            [d synchronize];
        } else {
            NSInteger maxDim = [d integerForKey:@"imageMaxDim"];
            if (maxDim == 0) imgSeg.selectedSegmentIndex = 0;
            else if (maxDim <= 1024) imgSeg.selectedSegmentIndex = 1;
            else imgSeg.selectedSegmentIndex = 2;
        }
        [imgSeg addTarget:self action:@selector(_imageCompressionChanged:)
         forControlEvents:UIControlEventValueChanged];
        imgSeg.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        CGRect f2 = cell.contentView.bounds;
        imgSeg.frame = CGRectMake(f2.size.width - 230 - kPad, (kRowH - 30) / 2, 230, 30);
        [cell.contentView addSubview:imgSeg];
        return cell;
    }
    return cell;
}

- (UITableViewCell *)_transitCellForRow:(NSInteger)row cell:(UITableViewCell *)cell settings:(NSDictionary *)settings
{
    if (row == 0) {
        // Transit toggle.
        [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"使用中转", nil)]];
        UISwitch *sw = [[[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 79, 27)] autorelease];
        [sw setOn:_useTransit animated:NO];
        [sw addTarget:self action:@selector(_transitToggleChanged:)
         forControlEvents:UIControlEventValueChanged];
        sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        CGRect f = cell.contentView.bounds;
        sw.frame = CGRectMake(f.size.width - 79 - kPad, (kRowH - 27) / 2, 79, 27);
        [cell.contentView addSubview:sw];
        return cell;
    }
    if (row == 1) {
        // Transit URL text field.
        [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"Transit URL", nil)]];
        CGRect f = cell.contentView.bounds;
        CGRect tfFrame = CGRectMake(kPad + kLabelWidth + 8, (kRowH - 30) / 2,
                                     f.size.width - kPad - kLabelWidth - 8 - kPad - 8, 30);
        UITextField *tf = [self _textFieldWithFrame:tfFrame
                                                  key:SettingsKeyTransitURL
                                            placeholder:kDefaultTransitURL
                                              isSecure:NO
                                         keyboardType:UIKeyboardTypeURL];
        tf.text = [settings objectForKey:SettingsKeyTransitURL];
        [cell.contentView addSubview:tf];
        return cell;
    }
    // row 2: Provider segmented control.
    if (row == 2) {
    [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"Provider", nil)]];
    UISegmentedControl *seg = [self _themedSegmentedControlWithItems:@[@"OpenAI", @"智谱", @"Ollama"]];
    NSInteger provIdx = 0;
    if ([_provider isEqualToString:ProviderIDZhipu]) provIdx = 1;
    else if ([_provider isEqualToString:ProviderIDOllama]) provIdx = 2;
    seg.selectedSegmentIndex = provIdx;
    [seg addTarget:self action:@selector(_providerChanged:)
     forControlEvents:UIControlEventValueChanged];
    seg.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    CGRect f = cell.contentView.bounds;
    seg.frame = CGRectMake(f.size.width - 165 - kPad, (kRowH - 30) / 2, 165, 30);
    [cell.contentView addSubview:seg];
    return cell;
    }
    if (row == 3) {
        // 中转网络搜索服务 toggle (default ON).
        [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"中转搜索", nil)]];
        UISwitch *sw = [[[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 79, 27)] autorelease];
        BOOL transitWebSearch = YES;
        if ([[NSUserDefaults standardUserDefaults] objectForKey:@"transitWebSearch"]) {
            transitWebSearch = [[NSUserDefaults standardUserDefaults] boolForKey:@"transitWebSearch"];
        }
        [sw setOn:transitWebSearch animated:NO];
        [sw addTarget:self action:@selector(_transitWebSearchToggle:)
         forControlEvents:UIControlEventValueChanged];
        sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        CGRect f3 = cell.contentView.bounds;
        sw.frame = CGRectMake(f3.size.width - 79 - kPad, (kRowH - 27) / 2, 79, 27);
        [cell.contentView addSubview:sw];
        return cell;
    }
    // row 4: 中转默认模型 toggle (default OFF).
    [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"中转默认模型", nil)]];
    UISwitch *sw2 = [[[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 79, 27)] autorelease];
    BOOL useServerModel = [[NSUserDefaults standardUserDefaults] boolForKey:@"useServerModel"];
    [sw2 setOn:useServerModel animated:NO];
    [sw2 addTarget:self action:@selector(_useServerModelToggle:)
     forControlEvents:UIControlEventValueChanged];
    sw2.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    CGRect f4 = cell.contentView.bounds;
    sw2.frame = CGRectMake(f4.size.width - 79 - kPad, (kRowH - 27) / 2, 79, 27);
    [cell.contentView addSubview:sw2];
    return cell;
}

- (UITableViewCell *)_directCellForRow:(NSInteger)row cell:(UITableViewCell *)cell settings:(NSDictionary *)settings
{
    NSString *label, *key, *ph;
    BOOL secure = NO;
    UIKeyboardType kbd = UIKeyboardTypeDefault;
    if (row == 0) {
        label = NSLocalizedString(@"Base URL", nil);
        key = SettingsKeyBaseURL;
        ph = @"https://api.openai.com";
        kbd = UIKeyboardTypeURL;
    } else {
        label = NSLocalizedString(@"API Key", nil);
        key = SettingsKeyAPIKey;
        ph = @"sk-...";
        secure = YES;
    }
    [cell.contentView addSubview:[self _labelWithText:label]];
    CGRect f = cell.contentView.bounds;
    CGRect tfFrame = CGRectMake(kPad + kLabelWidth + 8, (kRowH - 30) / 2,
                                 f.size.width - kPad - kLabelWidth - 8 - kPad - 8, 30);
    UITextField *tf = [self _textFieldWithFrame:tfFrame key:key placeholder:ph isSecure:secure keyboardType:kbd];
    tf.text = [settings objectForKey:key];
    [cell.contentView addSubview:tf];
    return cell;
}

- (UITableViewCell *)_modelCellForRow:(NSInteger)row cell:(UITableViewCell *)cell settings:(NSDictionary *)settings
{
    if (row == 0) {
        // Model text field + 搜索 button on the right.
        [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"Model", nil)]];
        CGRect f = cell.contentView.bounds;
        // Text field with right side reserved for the search button.
        CGFloat searchBtnW = 56.0f;
        CGRect tfFrame = CGRectMake(kPad + kLabelWidth + 8, (kRowH - 30) / 2,
                                     f.size.width - kPad - kLabelWidth - 8 - kPad - searchBtnW - 8, 30);
        UITextField *tf = [self _textFieldWithFrame:tfFrame key:SettingsKeyModel placeholder:@"gpt-4o-mini" isSecure:NO keyboardType:UIKeyboardTypeDefault];
        tf.text = [settings objectForKey:SettingsKeyModel];
        [cell.contentView addSubview:tf];

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        [btn setTitle:NSLocalizedString(@"搜索", nil) forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:13]];
        btn.backgroundColor = [iOS6Theme tintColor];
        btn.layer.cornerRadius = 6.0f;
        btn.layer.masksToBounds = YES;
        btn.frame = CGRectMake(f.size.width - searchBtnW - kPad, (kRowH - 28) / 2, searchBtnW, 28);
        btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [btn addTarget:self action:@selector(_searchAvailableModels)
         forControlEvents:UIControlEventTouchUpInside];
        [cell.contentView addSubview:btn];
        return cell;
    }
    if (row == 1) {
        // Hint row about how to use search.
        cell.textLabel.text = NSLocalizedString(@"点「搜索」可自动列出 /v1/models 的模型；也可手填", nil);
        cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:12]];
        cell.textLabel.textColor = [iOS6Theme secondaryTextColor];
        cell.textLabel.numberOfLines = 2;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (row == 2) {
        // 保存当前文本框模型到列表
        cell.textLabel.text = NSLocalizedString(@"保存到列表", nil);
        cell.textLabel.textColor = [iOS6Theme textColor];
        cell.textLabel.textAlignment = NSTextAlignmentLeft;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        return cell;
    }
    if (row == 3) {
        // 从列表选择默认
        NSArray *list = [self _modelList];
        NSString *cnt = [NSString stringWithFormat:@"（共 %lu 个）", (unsigned long)[list count]];
        cell.textLabel.text = [NSString stringWithFormat:@"%@%@", NSLocalizedString(@"从列表选择默认", nil), cnt];
        cell.textLabel.textColor = [iOS6Theme textColor];
        cell.textLabel.textAlignment = NSTextAlignmentLeft;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        return cell;
    }
    if (row == 4) {
        // 删除已保存模型
        cell.textLabel.text = NSLocalizedString(@"删除已保存模型", nil);
        cell.textLabel.textColor = [iOS6Theme tintColor];
        cell.textLabel.textAlignment = NSTextAlignmentLeft;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        return cell;
    }
    // row 5: "model supports images" toggle.
    if (row == 5) {
        [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"支持图片识别", nil)]];
        UISwitch *imgSw = [[[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 79, 27)] autorelease];
        BOOL imgSupport = [[NSUserDefaults standardUserDefaults] boolForKey:SettingsKeyModelSupportsImages];
        [imgSw setOn:imgSupport animated:NO];
        [imgSw addTarget:self action:@selector(_imageSupportToggle:)
         forControlEvents:UIControlEventValueChanged];
        imgSw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        CGRect imgSwF = cell.contentView.bounds;
        imgSw.frame = CGRectMake(imgSwF.size.width - 79 - kPad, (kRowH - 27) / 2, 79, 27);
        [cell.contentView addSubview:imgSw];
        return cell;
    }
    // row 6: "model supports thinking" toggle (moved from Advanced section).
    [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"支持思考", nil)]];
    UISwitch *thinkSw = [[[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 79, 27)] autorelease];
    BOOL thinkSupport = [[NSUserDefaults standardUserDefaults] boolForKey:SettingsKeyModelSupportsThinking];
    [thinkSw setOn:thinkSupport animated:NO];
    [thinkSw addTarget:self action:@selector(_thinkingSupportToggle:)
     forControlEvents:UIControlEventValueChanged];
    thinkSw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    CGRect thinkSwF = cell.contentView.bounds;
    thinkSw.frame = CGRectMake(thinkSwF.size.width - 79 - kPad, (kRowH - 27) / 2, 79, 27);
    [cell.contentView addSubview:thinkSw];
    return cell;
}

- (UITableViewCell *)_webSearchCellForRow:(NSInteger)row cell:(UITableViewCell *)cell settings:(NSDictionary *)settings
{
    if (row == 0) {
        // Enable toggle.
        [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"启用", nil)]];
        UISwitch *sw = [[[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 79, 27)] autorelease];
        BOOL on = [[settings objectForKey:SettingsKeyWebSearchEnabled] boolValue];
        [sw setOn:on animated:NO];
        [sw addTarget:self action:@selector(_webSearchToggle:)
         forControlEvents:UIControlEventValueChanged];
        sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        CGRect f = cell.contentView.bounds;
        sw.frame = CGRectMake(f.size.width - 79 - kPad, (kRowH - 27) / 2, 79, 27);
        [cell.contentView addSubview:sw];
        return cell;
    }
    if (row == 1) {
        // Tavily API key.
        [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"Tavily Key", nil)]];
        CGRect f = cell.contentView.bounds;
        CGRect tfFrame = CGRectMake(kPad + kLabelWidth + 8, (kRowH - 30) / 2,
                                     f.size.width - kPad - kLabelWidth - 8 - kPad - 8, 30);
        UITextField *tf = [self _textFieldWithFrame:tfFrame key:SettingsKeyTavilyAPIKey placeholder:@"tvly-..." isSecure:YES keyboardType:UIKeyboardTypeDefault];
        tf.text = [settings objectForKey:SettingsKeyTavilyAPIKey];
        [cell.contentView addSubview:tf];
        return cell;
    }
    // row 2: max results stepper + value label.
    [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"结果数", nil)]];
    NSInteger max = [[settings objectForKey:SettingsKeyTavilyMaxResults] integerValue];

    UILabel *numLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    numLabel.text = [NSString stringWithFormat:@"%d", (int)max];
    numLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
    numLabel.textColor = [iOS6Theme textColor];
    numLabel.backgroundColor = [UIColor clearColor];
    numLabel.tag = 999;
    numLabel.textAlignment = NSTextAlignmentRight;
    [cell.contentView addSubview:numLabel];
    [numLabel release];

    UIStepper *sp = [[[UIStepper alloc] initWithFrame:CGRectMake(0, 0, 94, 29)] autorelease];
    sp.minimumValue = 1;
    sp.maximumValue = 8;
    sp.value = max;
    // Dark mode tint — on iOS 6 the stepper background is white by default
    // which looks washed out in dark mode. Wrap it in a container view
    // with a dark background so it's at least visible.
    sp.tintColor = [iOS6Theme tintColor];
    [sp addTarget:self action:@selector(_tavilyMaxChanged:)
     forControlEvents:UIControlEventValueChanged];
    sp.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    CGRect f = cell.contentView.bounds;
    // Container with rounded corners + dark bg.
    UIView *stepperContainer = [[[UIView alloc] initWithFrame:CGRectMake(f.size.width - 102 - kPad, (kRowH - 31) / 2, 102, 31)] autorelease];
    stepperContainer.backgroundColor = [iOS6Theme controlBackgroundColor];
    stepperContainer.layer.cornerRadius = 6.0f;
    stepperContainer.layer.borderWidth = 1.0f;
    stepperContainer.layer.borderColor = [[iOS6Theme hairlineColor] CGColor];
    stepperContainer.layer.masksToBounds = YES;
    stepperContainer.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    sp.frame = CGRectMake(4, 1, 94, 29);
    [stepperContainer addSubview:sp];
    [cell.contentView addSubview:stepperContainer];

    // Place numLabel between stepper and label.
    [numLabel sizeToFit];
    CGRect nlF = numLabel.frame;
    nlF.origin.x = f.size.width - 102 - kPad - nlF.size.width - 8;
    nlF.origin.y = (kRowH - nlF.size.height) / 2;
    nlF.size.height = kRowH;
    numLabel.frame = nlF;
    numLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    return cell;
}

- (UITableViewCell *)_promptCell:(UITableViewCell *)cell settings:(NSDictionary *)settings
{
    [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"Prompt", nil)]];
    CGRect f = cell.contentView.bounds;
    CGRect tfFrame = CGRectMake(kPad + kLabelWidth + 8, (kRowH - 30) / 2,
                                 f.size.width - kPad - kLabelWidth - 8 - kPad - 8, 30);
    UITextField *tf = [self _textFieldWithFrame:tfFrame key:SettingsKeySystemPrompt placeholder:@"You are a helpful assistant." isSecure:NO keyboardType:UIKeyboardTypeDefault];
    tf.text = [settings objectForKey:SettingsKeySystemPrompt];
    [cell.contentView addSubview:tf];
    return cell;
}

- (UITableViewCell *)_advancedCellForRow:(NSInteger)row cell:(UITableViewCell *)cell settings:(NSDictionary *)settings
{
    // Only one row left in Advanced: 流式输出
    // (useServerModel moved to Transit section, thinkingSupport moved
    // to Model section)
    [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"流式输出", nil)]];
    UISwitch *sw = [[[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 79, 27)] autorelease];
    BOOL streamingOn = YES;
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"streamingOutput"]) {
        streamingOn = [[NSUserDefaults standardUserDefaults] boolForKey:@"streamingOutput"];
    }
    [sw setOn:streamingOn animated:NO];
    [sw addTarget:self action:@selector(_streamingOutputToggle:)
     forControlEvents:UIControlEventValueChanged];
    sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    CGRect f = cell.contentView.bounds;
    sw.frame = CGRectMake(f.size.width - 79 - kPad, (kRowH - 27) / 2, 79, 27);
    [cell.contentView addSubview:sw];
    return cell;
}

- (UITableViewCell *)_aboutCellForRow:(NSInteger)row cell:(UITableViewCell *)cell
{
    NSArray *labels = @[
        NSLocalizedString(@"作者", nil),
        NSLocalizedString(@"邮箱", nil),
        NSLocalizedString(@"版本", nil),
        NSLocalizedString(@"GitHub", nil),
        NSLocalizedString(@"License", nil)
    ];
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"261018";
    NSString *build   = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"5";
    NSString *versionString = [NSString stringWithFormat:@"v%@ (build %@, beta)", version, build];
    NSArray *values = @[
        @"qwq672",
        @"b167963232@163.com",
        versionString,
        @"qwq672/ios-online-ai-for-old-devices",
        @"MIT"
    ];
    [cell.contentView addSubview:[self _labelWithText:[labels objectAtIndex:row]]];

    UILabel *val = [[UILabel alloc] initWithFrame:CGRectZero];
    val.text = [values objectAtIndex:row];
    val.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:13]];
    val.textColor = [iOS6Theme secondaryTextColor];
    val.backgroundColor = [UIColor clearColor];
    val.textAlignment = NSTextAlignmentRight;
    val.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    val.numberOfLines = 2;  // version string is longer now
    CGRect f = cell.contentView.bounds;
    val.frame = CGRectMake(kPad + kLabelWidth + 8, (kRowH - 30) / 2,
                            f.size.width - kPad - kLabelWidth - 8 - kPad - 8, 30);
    [cell.contentView addSubview:val];
    [val release];
    return cell;
}

- (UITableViewCell *)_resetCell:(UITableViewCell *)cell
{
    cell.textLabel.text = NSLocalizedString(@"重置为默认设置", nil);
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    cell.textLabel.textColor = [iOS6Theme tintColor];
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    return cell;
}

#pragma mark - Table delegate

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSInteger logical = [self _logicalSectionForDisplayed:indexPath.section];
    if (logical == kSectionReset) {
        [self resetToDefaults];
    } else if (logical == kSectionModel) {
        [self _handleModelSectionRowTap:indexPath.row];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

// Handle taps on the new Model-section management rows (2/3/4).
// row 2: save current text-field model to the saved list.
// row 3: pop an action sheet to pick the default from the saved list.
// row 4: pop an action sheet to delete an entry from the saved list.
- (void)_handleModelSectionRowTap:(NSInteger)row
{
    if (row == 2) {
        // Read the model from the persisted settings (the text field
        // persists on every edit, so NSUserDefaults has the latest value).
        NSDictionary *settings = [SettingsViewController loadSettings];
        NSString *m = [settings objectForKey:SettingsKeyModel];
        if (!m || m.length == 0) {
            UIAlertView *av = [[[UIAlertView alloc]
                initWithTitle:NSLocalizedString(@"未填模型", nil)
                      message:NSLocalizedString(@"先在 Model 行输入模型名，再点保存。", nil)
                     delegate:nil
            cancelButtonTitle:NSLocalizedString(@"好", nil)
            otherButtonTitles:nil] autorelease];
            [av show];
            return;
        }
        [self _addModelToList:m];
        UIAlertView *av = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"已保存", nil)
                  message:[NSString stringWithFormat:@"%@ %@", m, NSLocalizedString(@"已加入常用模型列表。", nil)]
                 delegate:nil
        cancelButtonTitle:NSLocalizedString(@"好", nil)
        otherButtonTitles:nil] autorelease];
        [av show];
        [_tableView reloadData];
        return;
    }
    if (row == 3) {
        // 从列表选择默认 — action sheet tag 500.
        NSArray *list = [self _modelList];
        if ([list count] == 0) {
            UIAlertView *av = [[[UIAlertView alloc]
                initWithTitle:NSLocalizedString(@"列表为空", nil)
                      message:NSLocalizedString(@"还没有保存的模型。先在 Model 行输入模型名，点「保存到列表」。", nil)
                     delegate:nil
            cancelButtonTitle:NSLocalizedString(@"好", nil)
            otherButtonTitles:nil] autorelease];
            [av show];
            return;
        }
        UIActionSheet *sheet = [[UIActionSheet alloc]
            initWithTitle:NSLocalizedString(@"选择默认模型", nil)
                 delegate:self
        cancelButtonTitle:NSLocalizedString(@"取消", nil)
   destructiveButtonTitle:nil
        otherButtonTitles:nil];
        if ([iOS6Theme isDarkMode]) {
            sheet.actionSheetStyle = UIActionSheetStyleBlackOpaque;
        } else {
            sheet.actionSheetStyle = UIActionSheetStyleAutomatic;
        }
        for (NSString *m in list) {
            [sheet addButtonWithTitle:m];
        }
        // Remember the list separately so actionSheet callback can map
        // button index → model name (avoid stale cached list issue).
        self.availableModels = [NSMutableArray arrayWithArray:list];
        [sheet setTag:500];
        [sheet showInView:self.view];
        [sheet release];
        return;
    }
    if (row == 4) {
        // 删除已保存模型 — action sheet tag 600.
        NSArray *list = [self _modelList];
        if ([list count] == 0) {
            UIAlertView *av = [[[UIAlertView alloc]
                initWithTitle:NSLocalizedString(@"列表为空", nil)
                      message:NSLocalizedString(@"没有可删除的模型。", nil)
                     delegate:nil
            cancelButtonTitle:NSLocalizedString(@"好", nil)
            otherButtonTitles:nil] autorelease];
            [av show];
            return;
        }
        UIActionSheet *sheet = [[UIActionSheet alloc]
            initWithTitle:NSLocalizedString(@"点要删除的模型", nil)
                 delegate:self
        cancelButtonTitle:NSLocalizedString(@"取消", nil)
   destructiveButtonTitle:nil
        otherButtonTitles:nil];
        if ([iOS6Theme isDarkMode]) {
            sheet.actionSheetStyle = UIActionSheetStyleBlackOpaque;
        } else {
            sheet.actionSheetStyle = UIActionSheetStyleAutomatic;
        }
        for (NSString *m in list) {
            [sheet addButtonWithTitle:m];
        }
        self.availableModels = [NSMutableArray arrayWithArray:list];
        [sheet setTag:600];
        [sheet showInView:self.view];
        [sheet release];
        return;
    }
}

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
                          message:err.localizedDescription ?: NSLocalizedString(@"服务器无返回，请检查 BaseURL / API Key", nil)
                         delegate:nil
                cancelButtonTitle:NSLocalizedString(@"好", nil)
                otherButtonTitles:nil] autorelease];
                [fail show];
                return;
            }
            // Use UIActionSheet (slides up from bottom, like WiFi picker).
            // actionSheetStyle — BlackOpaque is the dark style on iOS 6.
            UIActionSheet *sheet = [[UIActionSheet alloc]
                initWithTitle:NSLocalizedString(@"选择模型", nil)
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

// Handle UIActionSheet for model picker (tag 400 = /v1/models search result,
// tag 500 = pick default from saved list, tag 600 = delete from saved list).
- (void)actionSheet:(UIActionSheet *)actionSheet
clickedButtonAtIndex:(NSInteger)buttonIndex
{
    // Tag 400: /v1/models search → write the chosen model as the default.
    if (actionSheet.tag == 400 && buttonIndex >= 0 && buttonIndex < (NSInteger)[_availableModels count]) {
        NSString *chosen = [_availableModels objectAtIndex:buttonIndex];
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setObject:chosen forKey:SettingsKeyModel];
        [d synchronize];
        [_fields release];
        _fields = [[NSMutableDictionary alloc] init];
        [_tableView reloadData];
        return;
    }
    // Tag 500: pick default from saved list.
    // Also auto-add to the saved list if not present (idempotent).
    if (actionSheet.tag == 500 && buttonIndex >= 0 && buttonIndex < (NSInteger)[_availableModels count]) {
        NSString *chosen = [_availableModels objectAtIndex:buttonIndex];
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setObject:chosen forKey:SettingsKeyModel];
        [d synchronize];
        [_fields release];
        _fields = [[NSMutableDictionary alloc] init];
        [_tableView reloadData];
        return;
    }
    // Tag 600: delete from saved list (with confirmation alert).
    if (actionSheet.tag == 600 && buttonIndex >= 0 && buttonIndex < (NSInteger)[_availableModels count]) {
        NSString *toDelete = [_availableModels objectAtIndex:buttonIndex];
        // Confirmation alert (tag 700) — deletion is destructive, so ask first.
        UIAlertView *av = [[[UIAlertView alloc]
            initWithTitle:NSLocalizedString(@"删除模型?", nil)
                  message:[NSString stringWithFormat:@"%@ \"%@\"", NSLocalizedString(@"确定从列表删除", nil), toDelete]
                 delegate:self
        cancelButtonTitle:NSLocalizedString(@"取消", nil)
        otherButtonTitles:NSLocalizedString(@"删除", nil), nil] autorelease];
        [av setTag:700];
        // Stash the to-delete model name on a side ivar (the picker list
        // uses availableModels; this is the per-deletion target).
        // Use the synthesized setter so the previous value is released.
        self.pendingDeleteModel = toDelete;
        [av show];
        return;
    }
}

#pragma mark - Toggle handlers

- (IBAction)_imageSupportToggle:(UISwitch *)sw
{
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:SettingsKeyModelSupportsImages];
    [[NSUserDefaults standardUserDefaults] synchronize];
    // Post notification so ComposerView updates image button visibility.
    [[NSNotificationCenter defaultCenter] postNotificationName:@"iOS6ThemeDidChangeNotification" object:nil];
}

- (IBAction)_thinkingSupportToggle:(UISwitch *)sw
{
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:SettingsKeyModelSupportsThinking];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (IBAction)_streamingOutputToggle:(UISwitch *)sw
{
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:@"streamingOutput"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (IBAction)_useServerModelToggle:(UISwitch *)sw
{
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:@"useServerModel"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (IBAction)_transitWebSearchToggle:(UISwitch *)sw
{
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:@"transitWebSearch"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (IBAction)_imageCompressionChanged:(UISegmentedControl *)seg
{
    NSInteger maxDim = 0;
    if (seg.selectedSegmentIndex == 1) maxDim = 1024;
    else if (seg.selectedSegmentIndex == 2) maxDim = 2048;
    [[NSUserDefaults standardUserDefaults] setInteger:maxDim forKey:@"imageMaxDim"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (IBAction)_darkModeToggle:(UISwitch *)sw
{
    [iOS6Theme setDarkMode:sw.on];
    // Post global theme-change notification so all VCs + AppDelegate
    // can re-style navbar / tabbar.
    [[NSNotificationCenter defaultCenter] postNotificationName:iOS6ThemeDidChangeNotification
                                                          object:nil];
    [self _applyTheme];
    [_tableView reloadData];
}

- (IBAction)_fontSizeChanged:(UISegmentedControl *)seg
{
    [iOS6Theme setFontSize:(iOS6ThemeFontSize)seg.selectedSegmentIndex];
    [[NSNotificationCenter defaultCenter] postNotificationName:iOS6ThemeDidChangeNotification
                                                          object:nil];
    [_tableView reloadData];
}

- (IBAction)_transitToggleChanged:(UISwitch *)sw
{
    self.useTransit = sw.on;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:sw.on forKey:SettingsKeyUseTransit];
    [d synchronize];
    [_fields release];
    _fields = [[NSMutableDictionary alloc] init];
    [self.tableView reloadData];
}

- (IBAction)_providerChanged:(UISegmentedControl *)seg
{
    NSArray *providers = [SettingsViewController availableProviderIDs];
    NSString *newProv = [providers objectAtIndex:seg.selectedSegmentIndex];
    self.provider = newProv;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:newProv forKey:SettingsKeyProvider];
    [d setObject:[SettingsViewController defaultModelForProvider:newProv]
      forKey:SettingsKeyModel];
    [d synchronize];
    [_fields release];
    _fields = [[NSMutableDictionary alloc] init];
    [_tableView reloadData];
}

- (IBAction)_webSearchToggle:(UISwitch *)sw
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:sw.on forKey:SettingsKeyWebSearchEnabled];
    [d synchronize];
}

- (IBAction)_tavilyMaxChanged:(UIStepper *)sp
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:(NSInteger)sp.value forKey:SettingsKeyTavilyMaxResults];
    [d synchronize];
    NSIndexPath *wsPath = [NSIndexPath indexPathForRow:2
                                            inSection:[self _displayedSectionForLogical:kSectionWebSearch]];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:wsPath];
    UILabel *numLabel = (UILabel *)[cell.contentView viewWithTag:999];
    if (numLabel) numLabel.text = [NSString stringWithFormat:@"%d", (int)sp.value];
}

#pragma mark - UITextField

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    [self _persistField:textField];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    return YES;
}

- (void)_fieldChanged:(UITextField *)field
{
    [self _persistField:field];
}

- (void)_persistField:(UITextField *)field
{
    // Look up the NSUserDefaults key from the field's restorationIdentifier
    // (set in _textFieldWithFrame:key:). iOS 6+ property.
    NSString *key = nil;
    if ([field respondsToSelector:@selector(restorationIdentifier)]) {
        key = [field restorationIdentifier];
    }
    if (!key || key.length == 0) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:field.text ?: @"" forKey:key];
    [d synchronize];
}

// Stub retained for compatibility — no longer used.
- (NSString *)_keyForLogical:(NSInteger)logical row:(NSInteger)row { return @""; }

#pragma mark - Section mapping

// All sections are always visible now (was: skip Direct when transit ON,
// skip Transit when transit OFF — that prevented independent control).
// The displayed index == logical index.
- (NSInteger)_logicalSectionForDisplayed:(NSInteger)displayed
{
    return displayed;
}

- (NSInteger)_displayedSectionForLogical:(NSInteger)logical
{
    return logical;
}

@end

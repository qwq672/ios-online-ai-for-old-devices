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

NSString *const SettingsKeyDarkMode           = @"darkMode";
NSString *const SettingsKeyFontSize           = @"fontSize";
NSString *const SettingsKeyUseTransit         = @"useTransit";
NSString *const SettingsKeyTransitURL          = @"transitURL";
NSString *const SettingsKeyProvider            = @"provider";
NSString *const SettingsKeyBaseURL              = @"baseURL";
NSString *const SettingsKeyAPIKey              = @"apiKey";
NSString *const SettingsKeyModel               = @"model";
NSString *const SettingsKeyTemperature         = @"temperature";
NSString *const SettingsKeySystemPrompt       = @"systemPrompt";
NSString *const SettingsKeyWebSearchEnabled = @"webSearchEnabled";
NSString *const SettingsKeyTavilyAPIKey      = @"tavilyAPIKey";
NSString *const SettingsKeyTavilyMaxResults  = @"tavilyMaxResults";

NSString *const ProviderIDZhipu  = @"zhipu";
NSString *const ProviderIDOpenAI = @"openai";
NSString *const ProviderIDOllama = @"ollama";

NSString *const iOS6ThemeDidChangeNotification = @"iOS6ThemeDidChangeNotification";

static NSString *const kDefaultTransitURL = @"https://api-ai.awa.lat";

// Layout constants.
static CGFloat const kLabelWidth = 100.0f;
static CGFloat const kPad = 12.0f;
static CGFloat const kRowH = 44.0f;

enum {
    kSectionTheme = 0,
    kSectionTransit,
    kSectionDirect,
    kSectionModel,
    kSectionWebSearch,
    kSectionPrompt,
    kSectionAbout,
    kSectionReset,
    kSectionCount
};

@interface SettingsViewController ()
@property (nonatomic, retain) NSMutableDictionary *fields;        // key -> UITextField
@property (nonatomic, assign) BOOL useTransit;
@property (nonatomic, copy)   NSString *provider;
@property (nonatomic, retain) NSMutableArray *availableModels;
@end

@implementation SettingsViewController

@synthesize tableView=_tableView, fields=_fields, useTransit=_useTransit,
            provider=_provider, availableModels=_availableModels;

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
    if (self.navigationController) {
        [iOS6Theme styleNavigationController:self.navigationController
                                       title:NSLocalizedString(@"设置", nil)
                                  systemIcon:UITabBarSystemItemMore];
    }
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
    }
}

#pragma mark - Table data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return _useTransit ? (kSectionCount - 1) : kSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSInteger logical = [self _logicalSectionForDisplayed:section];
    switch (logical) {
        case kSectionTheme:     return 2;
        case kSectionTransit:    return 3;
        case kSectionDirect:     return 2;
        case kSectionModel:      return 2;
        case kSectionWebSearch:  return 3;
        case kSectionPrompt:     return 1;
        case kSectionAbout:      return 5;  // author / email / version / github / license
        case kSectionReset:      return 1;
        default: return 0;
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return kRowH;
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
            return NSLocalizedString(@"中转是预制可关闭的开关。开则所有 AI/搜索请求经中转服务器路由，iOS 6 上规避 TLS 兼容问题。关则直连。默认 api-ai.awa.lat，可自建：github.com/qwq672/online-ai-transit-server", nil);
        case kSectionDirect:
            return NSLocalizedString(@"关闭中转时使用。BaseURL 必须 OpenAI 兼容格式。API Key 作 Authorization: Bearer 发出。", nil);
        case kSectionModel:
            return NSLocalizedString(@"点「搜索」从 /v1/models 拉取可选列表；也可手动输入模型名。", nil);
        case kSectionWebSearch:
            return NSLocalizedString(@"开关后每次提问先调 Tavily 搜索，结果作为上下文注入给 AI。结果数 1-8。也支持中转（中转是主开关）。", nil);
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
    f.backgroundColor = [UIColor whiteColor];
    f.textColor = [iOS6Theme textColor];
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

- (void)_registerField:(UITextField *)f forKey:(NSString *)key
{
    // _fields is set up in init. Avoid the dangling-pointer bug by re-initing if needed.
    if (!_fields) {
        [_fields release];
        _fields = [[NSMutableDictionary alloc] init];
    }
    [_fields setObject:f forKey:key];
}

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
    // Font size segmented control.
    [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"字号", nil)]];
    NSArray *items = @[@"S", @"M", @"L", @"XL", @"XXL"];
    UISegmentedControl *seg = [[[UISegmentedControl alloc] initWithItems:items] autorelease];
    seg.selectedSegmentIndex = (NSInteger)[iOS6Theme fontSize];
    [seg addTarget:self action:@selector(_fontSizeChanged:)
     forControlEvents:UIControlEventValueChanged];
    seg.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    CGRect f = cell.contentView.bounds;
    seg.frame = CGRectMake(f.size.width - 230 - kPad, (kRowH - 30) / 2, 230, 30);
    [cell.contentView addSubview:seg];
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
    [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"Provider", nil)]];
    UISegmentedControl *seg = [[[UISegmentedControl alloc] initWithItems:@[@"OpenAI", @"智谱", @"Ollama"]] autorelease];
    NSInteger provIdx = 0;
    if ([_provider isEqualToString:ProviderIDZhipu]) provIdx = 1;
    else if ([_provider isEqualToString:ProviderIDOllama]) provIdx = 2;
    seg.selectedSegmentIndex = provIdx;
    [seg addTarget:self action:@selector(_providerChanged:)
     forControlEvents:UIControlEventValueChanged];
    seg.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    CGRect f = cell.contentView.bounds;
    seg.frame = CGRectMake(f.size.width - 230 - kPad, (kRowH - 30) / 2, 230, 30);
    [cell.contentView addSubview:seg];
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

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        [btn setTitle:NSLocalizedString(@"搜索", nil) forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:13]];
        btn.frame = CGRectMake(f.size.width - searchBtnW - kPad, (kRowH - 28) / 2, searchBtnW, 28);
        btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [btn addTarget:self action:@selector(_searchAvailableModels)
         forControlEvents:UIControlEventTouchUpInside];
        [cell.contentView addSubview:btn];
        return cell;
    }
    // row 1: hint row about how to use 搜索.
    cell.textLabel.text = NSLocalizedString(@"点「搜索」可自动列出 /v1/models 的模型；也可手填", nil);
    cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:12]];
    cell.textLabel.textColor = [iOS6Theme secondaryTextColor];
    cell.textLabel.numberOfLines = 2;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
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
    [sp addTarget:self action:@selector(_tavilyMaxChanged:)
     forControlEvents:UIControlEventValueChanged];
    sp.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    CGRect f = cell.contentView.bounds;
    sp.frame = CGRectMake(f.size.width - 94 - kPad, (kRowH - 29) / 2, 94, 29);
    [cell.contentView addSubview:sp];

    // Place numLabel between stepper and label.
    [numLabel sizeToFit];
    CGRect nlF = numLabel.frame;
    nlF.origin.x = f.size.width - 94 - kPad - nlF.size.width - 8;
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

- (UITableViewCell *)_aboutCellForRow:(NSInteger)row cell:(UITableViewCell *)cell
{
    NSArray *labels = @[
        NSLocalizedString(@"作者", nil),
        NSLocalizedString(@"邮箱", nil),
        NSLocalizedString(@"版本", nil),
        NSLocalizedString(@"GitHub", nil),
        NSLocalizedString(@"License", nil)
    ];
    NSArray *values = @[
        @"qwq672",
        @"b167963232@163.com",
        @"1.0.0",
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
    CGRect f = cell.contentView.bounds;
    val.frame = CGRectMake(kPad + kLabelWidth + 8, (kRowH - 20) / 2,
                            f.size.width - kPad - kLabelWidth - 8 - kPad - 8, 20);
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
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
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
            UIAlertView *av = [[UIAlertView alloc]
                initWithTitle:NSLocalizedString(@"选择模型", nil)
                      message:NSLocalizedString(@"点选要用的模型", nil)
                     delegate:self
            cancelButtonTitle:NSLocalizedString(@"取消", nil)
            otherButtonTitles:nil];
            NSInteger limit = MIN([models count], (NSUInteger)6);
            for (NSInteger i = 0; i < limit; i++) {
                NSString *mid = [models objectAtIndex:i];
                [av addButtonWithTitle:mid];
            }
            [av setTag:400];
            [av show];
            [av release];
            self.availableModels = [NSMutableArray arrayWithArray:[models subarrayWithRange:NSMakeRange(0, limit)]];
        });
    });
}

- (void)alertView:(UIAlertView *)alertView
didDismissWithButtonIndex:(NSInteger)buttonIndex
{
    if (alertView.tag == 400 && buttonIndex > 0) {
        NSString *chosen = [_availableModels objectAtIndex:buttonIndex - 1];
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setObject:chosen forKey:SettingsKeyModel];
        [d synchronize];
        [_fields release];
        _fields = [[NSMutableDictionary alloc] init];
        [_tableView reloadData];
    }
}

#pragma mark - Toggle handlers

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

- (NSInteger)_logicalSectionForDisplayed:(NSInteger)displayed
{
    if (_useTransit) {
        switch (displayed) {
            case 0: return kSectionTheme;
            case 1: return kSectionTransit;
            case 2: return kSectionModel;
            case 3: return kSectionWebSearch;
            case 4: return kSectionPrompt;
            case 5: return kSectionAbout;
            case 6: return kSectionReset;
            default: return kSectionReset;
        }
    }
    return displayed;
}

- (NSInteger)_displayedSectionForLogical:(NSInteger)logical
{
    if (_useTransit) {
        switch (logical) {
            case kSectionTheme:     return 0;
            case kSectionTransit:    return 1;
            case kSectionModel:      return 2;
            case kSectionWebSearch:  return 3;
            case kSectionPrompt:     return 4;
            case kSectionAbout:      return 5;
            case kSectionReset:      return 6;
            default:                 return 0;
        }
    }
    return logical;
}

@end

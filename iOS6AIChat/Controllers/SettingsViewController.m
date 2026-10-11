//
//  SettingsViewController.m
//  iOS6AIChat
//
//  Grouped UITableView sections (in display order):
//    0) Theme          — dark mode toggle, font size stepper
//    1) Transit        — toggle, transit URL, provider picker
//    2) Direct server  — BaseURL + API Key (hidden when transit ON)
//    3) Model          — auto-search button + manual entry
//    4) Web Search     — Tavily toggle, API Key, result count
//    5) System Prompt
//    6) About
//    7) Reset
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

static NSString *const kDefaultTransitURL = @"https://api-ai.awa.lat";

// Logical section indices (after we hide section 2 when transit is ON).
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
@property (nonatomic, retain) NSMutableDictionary *fields;
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
        self.title = NSLocalizedString(@"Settings", nil);
        _fields = [NSMutableDictionary dictionary];
        _availableModels = [[NSMutableArray array] retain];
        NSDictionary *loaded = [SettingsViewController loadSettings];
        _useTransit = [[loaded objectForKey:SettingsKeyUseTransit] boolValue];
        _provider = [loaded objectForKey:SettingsKeyProvider];
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
    [self.view addSubview:_tableView];

    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self action:@selector(resetToDefaults)] autorelease];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // Theme may have changed since last appearance — refresh table so
    // backgrounds / fonts pick up the new palette.
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    _tableView.backgroundColor = [UIColor clearColor];
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
    if ([providerID isEqualToString:ProviderIDZhipu])  return @"智谱 GLM";
    if ([providerID isEqualToString:ProviderIDOpenAI]) return @"OpenAI";
    if ([providerID isEqualToString:ProviderIDOllama]) return @"Ollama (本地)";
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
        // Apply theme changes immediately.
        [iOS6Theme setDarkMode:[[loaded objectForKey:SettingsKeyDarkMode] boolValue]];
        [iOS6Theme setFontSize:[[loaded objectForKey:SettingsKeyFontSize] integerValue]];

        _fields = [NSMutableDictionary dictionary];
        [_tableView reloadData];
    }
    else if (alertView.tag == 200 && buttonIndex > 0) {
        // Provider picker.
        NSArray *providers = [SettingsViewController availableProviderIDs];
        NSString *newProv = [providers objectAtIndex:(buttonIndex - 1)];
        self.provider = newProv;
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setObject:newProv forKey:SettingsKeyProvider];
        [d setObject:[SettingsViewController defaultModelForProvider:newProv]
          forKey:SettingsKeyModel];
        [d synchronize];
        _fields = [NSMutableDictionary dictionary];
        [_tableView reloadData];
    }
    else if (alertView.tag == 300) {
        // Manual model input — but UIAlertView with style can't be done on
        // iOS 6 cleanly. Skip; user uses the text field row instead.
    }
}

#pragma mark - Table data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    // When transit is ON, section 2 (Direct server) is hidden.
    return _useTransit ? (kSectionCount - 1) : kSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSInteger logical = [self _logicalSectionForDisplayed:section];
    switch (logical) {
        case kSectionTheme:     return 2;  // dark mode toggle, font size stepper
        case kSectionTransit:    return 3;  // toggle, URL, provider
        case kSectionDirect:     return 2;  // baseURL, apiKey
        case kSectionModel:      return 2;  // manual entry + auto-search button
        case kSectionWebSearch:  return 3;  // toggle, api key, max results
        case kSectionPrompt:     return 1;
        case kSectionAbout:      return 4;  // author, version, github, license
        case kSectionReset:      return 1;
        default: return 0;
    }
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
        case kSectionWebSearch:  return NSLocalizedString(@"联网搜索", nil);
        case kSectionPrompt:     return NSLocalizedString(@"系统提示词", nil);
        case kSectionAbout:      return NSLocalizedString(@"关于", nil);
        default: return @"";
    }
}

- (NSString *)tableView:(UITableView *)tableView
titleForFooterInSection:(NSInteger)section
{
    NSInteger logical = [self _logicalSectionForDisplayed:section];
    if (logical == kSectionTransit) {
        return NSLocalizedString(@"开启后所有请求经中转服务器路由到对应 AI 后端，iOS 6 上规避 TLS 兼容问题。默认 api-ai.awa.lat，可自建：github.com/qwq672/online-ai-transit-server。中转是预制选项，关掉则直连你填的 BaseURL。", nil);
    }
    if (logical == kSectionDirect) {
        return NSLocalizedString(@"关闭中转时，App 直连你填的 BaseURL（必须 OpenAI 兼容格式）。API Key 作为 Authorization: Bearer 发出。", nil);
    }
    if (logical == kSectionModel) {
        return NSLocalizedString(@"点「搜索可用模型」会从 /v1/models 拉取，多模型显示为可选列表；也可手动输入。", nil);
    }
    if (logical == kSectionWebSearch) {
        return NSLocalizedString(@"Tavily 联网搜索。开关后每次提问先调 Tavily /search 取若干结果，注入到 AI 上下文。也支持中转（中转开关是主开关）。结果数 1-8。", nil);
    }
    if (logical == kSectionTheme) {
        return NSLocalizedString(@"暗色模式 / 字号调整实时生效，返回聊天页即可看到。", nil);
    }
    return @"";
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
    }
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];

    NSInteger logical = [self _logicalSectionForDisplayed:indexPath.section];
    NSDictionary *settings = [SettingsViewController loadSettings];

    // === Theme section ==============================================
    if (logical == kSectionTheme && indexPath.row == 0) {
        cell.textLabel.text = NSLocalizedString(@"深色模式", nil);
        UISwitch *sw = [[[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 79, 27)] autorelease];
        [sw setOn:[iOS6Theme isDarkMode] animated:NO];
        [sw addTarget:self action:@selector(_darkModeToggle:)
         forControlEvents:UIControlEventValueChanged];
        CGRect f = cell.contentView.bounds;
        sw.frame = CGRectMake(f.size.width - 95, 8, 79, 27);
        sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [cell.contentView addSubview:sw];
        return cell;
    }
    if (logical == kSectionTheme && indexPath.row == 1) {
        cell.textLabel.text = NSLocalizedString(@"字号", nil);
        // Use a UISegmentedControl with 5 sizes.
        NSArray *items = @[@"S", @"M", @"L", @"XL", @"XXL"];
        UISegmentedControl *seg = [[[UISegmentedControl alloc] initWithItems:items] autorelease];
        seg.selectedSegmentIndex = (NSInteger)[iOS6Theme fontSize];
        [seg addTarget:self action:@selector(_fontSizeChanged:)
         forControlEvents:UIControlEventValueChanged];
        CGRect f = cell.contentView.bounds;
        seg.frame = CGRectMake(f.size.width - 230, 5, 215, 32);
        seg.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [cell.contentView addSubview:seg];
        return cell;
    }

    // === Reset row =================================================
    if (logical == kSectionReset) {
        cell.textLabel.text = NSLocalizedString(@"重置为默认设置", nil);
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [iOS6Theme tintColor];
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        return cell;
    }

    // === About rows =================================================
    if (logical == kSectionAbout) {
        NSArray *labels = @[
            NSLocalizedString(@"作者", nil),
            NSLocalizedString(@"版本", nil),
            NSLocalizedString(@"GitHub", nil),
            NSLocalizedString(@"License", nil)
        ];
        NSArray *values = @[
            @"qwq672",
            @"1.0.0",
            @"qwq672/ios-online-ai-for-old-devices",
            @"MIT"
        ];
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(15, 8, 100, 28)];
        label.text = [labels objectAtIndex:indexPath.row];
        label.backgroundColor = [UIColor clearColor];
        label.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        label.textColor = [iOS6Theme textColor];
        [cell.contentView addSubview:label];
        [label release];

        UILabel *val = [[UILabel alloc] initWithFrame:CGRectMake(120, 8, 200, 28)];
        val.text = [values objectAtIndex:indexPath.row];
        val.backgroundColor = [UIColor clearColor];
        val.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:14]];
        val.textColor = [iOS6Theme secondaryTextColor];
        val.textAlignment = NSTextAlignmentRight;
        val.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [cell.contentView addSubview:val];
        [val release];
        return cell;
    }

    // === Transit toggle (kSectionTransit, row 0) ====================
    if (logical == kSectionTransit && indexPath.row == 0) {
        cell.textLabel.text = NSLocalizedString(@"使用中转", nil);
        UISwitch *sw = [[[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 79, 27)] autorelease];
        [sw setOn:_useTransit animated:NO];
        [sw addTarget:self action:@selector(_transitToggleChanged:)
         forControlEvents:UIControlEventValueChanged];
        CGRect f = cell.contentView.bounds;
        sw.frame = CGRectMake(f.size.width - 95, 8, 79, 27);
        sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [cell.contentView addSubview:sw];
        return cell;
    }

    // === Provider picker (kSectionTransit, row 2) ==================
    if (logical == kSectionTransit && indexPath.row == 2) {
        cell.textLabel.text = NSLocalizedString(@"Provider", nil);
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        UILabel *value = [[UILabel alloc] initWithFrame:CGRectMake(150, 8, 150, 28)];
        value.text = [SettingsViewController displayNameForProvider:_provider];
        value.textAlignment = NSTextAlignmentRight;
        value.textColor = [iOS6Theme secondaryTextColor];
        value.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        value.backgroundColor = [UIColor clearColor];
        value.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [cell.contentView addSubview:value];
        [value release];
        return cell;
    }

    // === Model auto-search button (kSectionModel, row 1) =========
    if (logical == kSectionModel && indexPath.row == 1) {
        cell.textLabel.text = NSLocalizedString(@"🔍 搜索可用模型", nil);
        cell.textLabel.textColor = [iOS6Theme tintColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        return cell;
    }

    // === Web search toggle (kSectionWebSearch, row 0) =============
    if (logical == kSectionWebSearch && indexPath.row == 0) {
        cell.textLabel.text = NSLocalizedString(@"启用 Tavily 联网搜索", nil);
        UISwitch *sw = [[[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 79, 27)] autorelease];
        BOOL on = [[settings objectForKey:SettingsKeyWebSearchEnabled] boolValue];
        [sw setOn:on animated:NO];
        [sw addTarget:self action:@selector(_webSearchToggle:)
         forControlEvents:UIControlEventValueChanged];
        CGRect f = cell.contentView.bounds;
        sw.frame = CGRectMake(f.size.width - 95, 8, 79, 27);
        sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [cell.contentView addSubview:sw];
        return cell;
    }

    // === Web search max results stepper (kSectionWebSearch, row 2) ===
    if (logical == kSectionWebSearch && indexPath.row == 2) {
        cell.textLabel.text = NSLocalizedString(@"结果数 (1-8)", nil);
        NSInteger max = [[settings objectForKey:SettingsKeyTavilyMaxResults] integerValue];
        UIStepper *sp = [[[UIStepper alloc] initWithFrame:CGRectMake(0, 0, 94, 29)] autorelease];
        sp.minimumValue = 1;
        sp.maximumValue = 8;
        sp.value = max;
        [sp addTarget:self action:@selector(_tavilyMaxChanged:)
         forControlEvents:UIControlEventValueChanged];
        CGRect f = cell.contentView.bounds;
        sp.frame = CGRectMake(f.size.width - 110, 8, 94, 29);
        sp.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [cell.contentView addSubview:sp];

        UILabel *numLabel = [[UILabel alloc] initWithFrame:CGRectMake(f.size.width - 145, 8, 30, 28)];
        numLabel.text = [NSString stringWithFormat:@"%d", (int)max];
        numLabel.backgroundColor = [UIColor clearColor];
        numLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:16]];
        numLabel.textColor = [iOS6Theme textColor];
        numLabel.tag = 999;
        [cell.contentView addSubview:numLabel];
        [numLabel release];
        return cell;
    }

    // === Generic text-field row (transit URL, baseURL, apiKey, model, tavily key, prompt, temp) ===
    NSString *key = [self _keyForLogical:logical row:indexPath.row];
    id rawValue = [settings objectForKey:key];
    NSString *current = nil;
    if ([rawValue isKindOfClass:[NSNumber class]]) {
        current = [NSString stringWithFormat:@"%@", rawValue];
    } else if ([rawValue isKindOfClass:[NSString class]]) {
        current = rawValue;
    }
    if (!current) current = @"";

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(15, 8, 120, 28)];
    label.text = [self _labelForLogical:logical row:indexPath.row];
    label.backgroundColor = [UIColor clearColor];
    label.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
    label.textColor = [iOS6Theme textColor];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [cell.contentView addSubview:label];
    [label release];

    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(140, 6, 170, 32)];
    field.borderStyle = UITextBorderStyleNone;
    field.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:14]];
    field.placeholder = [self _placeholderForLogical:logical row:indexPath.row];
    field.text = current;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.returnKeyType = UIReturnKeyDone;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.delegate = self;
    field.tag = (logical << 8) | indexPath.row;
    [field addTarget:self action:@selector(_fieldChanged:)
    forControlEvents:UIControlEventEditingChanged];
    [cell.contentView addSubview:field];
    [field release];

    [_fields setObject:field forKey:key];
    return cell;
}

#pragma mark - Table delegate

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSInteger logical = [self _logicalSectionForDisplayed:indexPath.section];
    if (logical == kSectionReset && indexPath.row == 0) {
        [self resetToDefaults];
    }
    else if (logical == kSectionTransit && indexPath.row == 2) {
        NSMutableString *msg = [NSMutableString string];
        for (NSString *pid in [SettingsViewController availableProviderIDs]) {
            [msg appendFormat:@"%@\n", [SettingsViewController displayNameForProvider:pid]];
        }
        UIAlertView *av = [[[UIAlertView alloc]
                            initWithTitle:NSLocalizedString(@"选择 Provider", nil)
                                  message:msg
                                 delegate:self
                        cancelButtonTitle:NSLocalizedString(@"取消", nil)
                        otherButtonTitles:
                            [SettingsViewController displayNameForProvider:ProviderIDOpenAI],
                            [SettingsViewController displayNameForProvider:ProviderIDZhipu],
                            [SettingsViewController displayNameForProvider:ProviderIDOllama],
                            nil] autorelease];
        [av setTag:200];
        [av show];
    }
    else if (logical == kSectionModel && indexPath.row == 1) {
        [self _searchAvailableModels];
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

    // Run sync network request on background queue.
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
            // Show as alert with one button per model.
            UIAlertView *av = [[UIAlertView alloc]
                initWithTitle:NSLocalizedString(@"选择模型", nil)
                      message:NSLocalizedString(@"点选要用的模型", nil)
                     delegate:self
            cancelButtonTitle:NSLocalizedString(@"取消", nil)
            otherButtonTitles:nil];
            // Cap at 6 buttons (UIAlertView limit on iOS 6).
            NSInteger limit = MIN([models count], (NSUInteger)6);
            for (NSInteger i = 0; i < limit; i++) {
                NSString *mid = [models objectAtIndex:i];
                [av addButtonWithTitle:mid];
            }
            [av setTag:400];
            [av show];
            [av release];
            // Cache for tag-400 handler.
            self.availableModels = [NSMutableArray arrayWithArray:[models subarrayWithRange:NSMakeRange(0, limit)]];
        });
    });
}

#pragma mark - Model picker alert

- (void)alertView:(UIAlertView *)alertView
didDismissWithButtonIndex:(NSInteger)buttonIndex
{
    // Note: this delegate method is called for ALL alerts; check tag.
    if (alertView.tag == 400 && buttonIndex > 0) {
        // Models picker.
        NSString *chosen = [_availableModels objectAtIndex:buttonIndex - 1];
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setObject:chosen forKey:SettingsKeyModel];
        [d synchronize];
        _fields = [NSMutableDictionary dictionary];
        [_tableView reloadData];
    }
}

#pragma mark - Toggles

- (IBAction)_darkModeToggle:(UISwitch *)sw
{
    [iOS6Theme setDarkMode:sw.on];
    self.view.backgroundColor = [iOS6Theme pinstripeBackground];
    _tableView.backgroundColor = [UIColor clearColor];
    [_tableView reloadData];
}

- (IBAction)_fontSizeChanged:(UISegmentedControl *)seg
{
    [iOS6Theme setFontSize:(iOS6ThemeFontSize)seg.selectedSegmentIndex];
    [_tableView reloadData];
}

- (IBAction)_transitToggleChanged:(UISwitch *)sw
{
    self.useTransit = sw.on;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:sw.on forKey:SettingsKeyUseTransit];
    [d synchronize];
    _fields = [NSMutableDictionary dictionary];
    [self.tableView reloadData];
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
    // Update the label of the cell that owns this stepper.
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:
                              [NSIndexPath indexPathForRow:2 inSection:[self _displayedSectionForLogical:kSectionWebSearch]]];
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
    NSInteger logical = field.tag >> 8;
    NSInteger row = field.tag & 0xff;
    NSString *key = [self _keyForLogical:logical row:row];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (logical == kSectionModel && row == 0) {
        [d setObject:field.text ?: @"" forKey:SettingsKeyModel];
    } else if (logical == kSectionWebSearch && row == 1) {
        [d setObject:field.text ?: @"" forKey:SettingsKeyTavilyAPIKey];
    } else if (logical == kSectionPrompt && row == 0) {
        [d setObject:field.text ?: @"" forKey:SettingsKeySystemPrompt];
    } else if (logical == kSectionTheme && row == 0) {
        // Dark mode is a switch, not text — ignore.
    } else {
        if (logical == kSectionDirect && row == 1) {
            // Temperature — numeric.
            [d setFloat:(float)[field.text doubleValue] forKey:key];
        } else {
            [d setObject:field.text ?: @"" forKey:key];
        }
    }
    [d synchronize];
}

#pragma mark - Section mapping

- (NSInteger)_logicalSectionForDisplayed:(NSInteger)displayed
{
    if (_useTransit) {
        // Skip kSectionDirect (logical=2). Map:
        // displayed 0→Theme(0), 1→Transit(1), 2→Model(3), 3→WebSearch(4),
        // 4→Prompt(5), 5→About(6), 6→Reset(7).
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
        // Inverse of _logicalSectionForDisplayed.
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

- (NSString *)_keyForLogical:(NSInteger)logical row:(NSInteger)row
{
    switch (logical) {
        case kSectionTransit:   return row == 1 ? SettingsKeyTransitURL : (row == 2 ? SettingsKeyProvider : SettingsKeyUseTransit);
        case kSectionDirect:    return row == 0 ? SettingsKeyBaseURL : SettingsKeyAPIKey;
        case kSectionModel:     return SettingsKeyModel;
        case kSectionWebSearch: return row == 1 ? SettingsKeyTavilyAPIKey : (row == 2 ? SettingsKeyTavilyMaxResults : SettingsKeyWebSearchEnabled);
        case kSectionPrompt:    return SettingsKeySystemPrompt;
        default: return @"";
    }
}

- (NSString *)_labelForLogical:(NSInteger)logical row:(NSInteger)row
{
    switch (logical) {
        case kSectionTheme:
            return row == 0 ? NSLocalizedString(@"深色模式", nil) : NSLocalizedString(@"字号", nil);
        case kSectionTransit:
            return row == 0 ? NSLocalizedString(@"使用中转", nil) :
                   row == 1 ? NSLocalizedString(@"Transit URL", nil) :
                              NSLocalizedString(@"Provider", nil);
        case kSectionDirect:
            return row == 0 ? NSLocalizedString(@"Base URL", nil) :
                              NSLocalizedString(@"API Key", nil);
        case kSectionModel:
            return row == 0 ? NSLocalizedString(@"Model", nil) :
                              NSLocalizedString(@"自动搜索", nil);
        case kSectionWebSearch:
            return row == 0 ? NSLocalizedString(@"启用", nil) :
                   row == 1 ? NSLocalizedString(@"Tavily Key", nil) :
                              NSLocalizedString(@"结果数", nil);
        case kSectionPrompt:
            return NSLocalizedString(@"Prompt", nil);
        default:
            return @"";
    }
}

- (NSString *)_placeholderForLogical:(NSInteger)logical row:(NSInteger)row
{
    switch (logical) {
        case kSectionTransit: return row == 1 ? kDefaultTransitURL : @"";
        case kSectionDirect:  return row == 0 ? @"https://api.openai.com" : @"sk-...";
        case kSectionModel:   return row == 0 ? @"gpt-4o-mini" : @"";
        case kSectionWebSearch: return row == 1 ? @"tvly-..." : @"";
        case kSectionPrompt:  return NSLocalizedString(@"You are a helpful assistant.", nil);
        default: return @"";
    }
}

- (void)dealloc
{
    [_tableView release];
    [_fields release];
    [_provider release];
    [_availableModels release];
    [super dealloc];
}

@end

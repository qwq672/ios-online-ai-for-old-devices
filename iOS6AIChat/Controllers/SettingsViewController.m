//
//  SettingsViewController.m
//  iOS6AIChat
//
//  Grouped UITableView, 5 sections:
//     0) Transit     — toggle + transit URL + provider picker
//     1) Auth        — API Key (used in both transit and direct modes)
//     2) Model       — model name + temperature
//     3) Prompt      — system prompt
//     4) Reset       — restore defaults
//
//  When transit is ON, the BaseURL field is hidden because the transit
//  server is the one routing to the actual backend.
//

#import "SettingsViewController.h"
#import "iOS6Theme.h"

NSString *const SettingsKeyUseTransit   = @"useTransit";
NSString *const SettingsKeyTransitURL  = @"transitURL";
NSString *const SettingsKeyProvider     = @"provider";
NSString *const SettingsKeyBaseURL      = @"baseURL";
NSString *const SettingsKeyAPIKey       = @"apiKey";
NSString *const SettingsKeyModel        = @"model";
NSString *const SettingsKeyTemperature  = @"temperature";
NSString *const SettingsKeySystemPrompt = @"systemPrompt";

NSString *const ProviderIDZhipu  = @"zhipu";
NSString *const ProviderIDOpenAI = @"openai";
NSString *const ProviderIDOllama = @"ollama";

// Default transit URL — see https://github.com/qwq672/online-ai-transit-server
static NSString *const kDefaultTransitURL = @"https://api-ai.awa.lat";

@interface SettingsViewController ()
@property (nonatomic, retain) NSMutableDictionary *fields;
@property (nonatomic, assign) BOOL useTransit;
@property (nonatomic, copy)   NSString *provider;
@end

@implementation SettingsViewController

@synthesize tableView=_tableView, fields=_fields, useTransit=_useTransit, provider=_provider;

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if (self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil]) {
        self.title = NSLocalizedString(@"Settings", nil);
        _fields = [NSMutableDictionary dictionary];
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

#pragma mark - Persistence helpers

+ (NSDictionary *)loadSettings
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSNumber *useTransitNum = [d objectForKey:SettingsKeyUseTransit];
    BOOL useTransit = useTransitNum ? [useTransitNum boolValue] : YES; // default ON
    return @{
        SettingsKeyUseTransit:    @(useTransit),
        SettingsKeyTransitURL:    [d stringForKey:SettingsKeyTransitURL] ?: kDefaultTransitURL,
        SettingsKeyProvider:      [d stringForKey:SettingsKeyProvider]   ?: ProviderIDOpenAI,
        SettingsKeyBaseURL:       [d stringForKey:SettingsKeyBaseURL]    ?: @"https://api.openai.com",
        SettingsKeyAPIKey:        [d stringForKey:SettingsKeyAPIKey]     ?: @"",
        SettingsKeyModel:         [d stringForKey:SettingsKeyModel]      ?: [self defaultModelForProvider:[d stringForKey:SettingsKeyProvider] ?: ProviderIDOpenAI],
        SettingsKeyTemperature:   @([d objectForKey:SettingsKeyTemperature] ? [[d stringForKey:SettingsKeyTemperature] floatValue] : 0.7f),
        SettingsKeySystemPrompt:  [d stringForKey:SettingsKeySystemPrompt] ?: NSLocalizedString(@"You are a helpful assistant.", nil)
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
        // Reset.
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        for (NSString *key in @[SettingsKeyUseTransit, SettingsKeyTransitURL,
                                SettingsKeyProvider, SettingsKeyBaseURL,
                                SettingsKeyAPIKey, SettingsKeyModel,
                                SettingsKeyTemperature, SettingsKeySystemPrompt]) {
            [d removeObjectForKey:key];
        }
        [d synchronize];

        // Refresh local state.
        NSDictionary *loaded = [SettingsViewController loadSettings];
        self.useTransit = [[loaded objectForKey:SettingsKeyUseTransit] boolValue];
        self.provider   = [loaded objectForKey:SettingsKeyProvider];

        // Force the cells to rebuild — otherwise cached textFields linger.
        _fields = [NSMutableDictionary dictionary];
        [_tableView reloadData];
    }
    else if (alertView.tag == 200 && buttonIndex > 0) {
        // Provider picker selection.
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
}

#pragma mark - Table data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    // Section 1 (Direct server) is hidden when transit is ON — the
    // user has nothing to configure for direct connection then.
    return _useTransit ? 5 : 6;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    // Map displayed-section index to our logical sections.
    NSInteger logical = [self _logicalSectionForDisplayed:section];
    switch (logical) {
        case 0: return 3;  // Transit: toggle, transit URL, provider
        case 1: return 2;  // Direct server: baseURL, apiKey
        case 2: return 2;  // Model: name, temperature
        case 3: return 1;  // System prompt
        case 4: return 1;  // Reset
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView
titleForHeaderInSection:(NSInteger)section
{
    NSInteger logical = [self _logicalSectionForDisplayed:section];
    switch (logical) {
        case 0: return NSLocalizedString(@"中转服务器", nil);
        case 1: return NSLocalizedString(@"直连后端", nil);
        case 2: return NSLocalizedString(@"模型", nil);
        case 3: return NSLocalizedString(@"系统提示词", nil);
        case 4: return @"";
        default: return @"";
    }
}

- (NSString *)tableView:(UITableView *)tableView
titleForFooterInSection:(NSInteger)section
{
    NSInteger logical = [self _logicalSectionForDisplayed:section];
    if (logical == 0) {
        return NSLocalizedString(@"开启后所有请求经中转服务器路由到对应 AI 后端，iOS 6 上规避 TLS 兼容问题。默认 api-ai.awa.lat。自建中转：https://github.com/qwq672/online-ai-transit-server", nil);
    }
    if (logical == 1) {
        return NSLocalizedString(@"关闭中转时，App 直连你填的 BaseURL（必须 OpenAI 兼容格式）。API Key 作为 Authorization: Bearer 发出。", nil);
    }
    if (logical == 2) {
        return NSLocalizedString(@"不同 Provider 的默认模型已填好。Temperature 0~1，越高回复越随机。", nil);
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
    // Strip any prior subviews (we reuse cells across rows).
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];

    NSInteger logical = [self _logicalSectionForDisplayed:indexPath.section];

    // === Reset row =========================================================
    if (logical == 4) {
        cell.textLabel.text = NSLocalizedString(@"重置为默认设置", nil);
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [iOS6Theme tintColor];
        return cell;
    }

    NSDictionary *settings = [SettingsViewController loadSettings];

    // === Transit toggle (section 0, row 0) ================================
    if (logical == 0 && indexPath.row == 0) {
        cell.textLabel.text = NSLocalizedString(@"使用中转", nil);
        cell.textLabel.textAlignment = NSTextAlignmentLeft;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [[[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 79, 27)] autorelease];
        [sw setOn:_useTransit animated:NO];
        [sw addTarget:self action:@selector(_transitToggleChanged:)
         forControlEvents:UIControlEventValueChanged];
        sw.autoresizingMask = (UIViewAutoresizingFlexibleLeftMargin |
                                UIViewAutoresizingFlexibleHeight);
        CGRect f = cell.contentView.bounds;
        sw.frame = CGRectMake(f.size.width - 95, 8, 79, 27);
        [cell.contentView addSubview:sw];
        return cell;
    }

    // === Provider picker (section 0, row 2) ==============================
    if (logical == 0 && indexPath.row == 2) {
        cell.textLabel.text = NSLocalizedString(@"Provider", nil);
        cell.textLabel.textAlignment = NSTextAlignmentLeft;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        UILabel *value = [[UILabel alloc] initWithFrame:CGRectMake(150, 8, 150, 28)];
        value.text = [SettingsViewController displayNameForProvider:_provider];
        value.textAlignment = NSTextAlignmentRight;
        value.textColor = [iOS6Theme secondaryTextColor];
        value.font = [UIFont systemFontOfSize:15];
        value.backgroundColor = [UIColor clearColor];
        value.autoresizingMask = (UIViewAutoresizingFlexibleLeftMargin |
                                   UIViewAutoresizingFlexibleWidth);
        [cell.contentView addSubview:value];
        [value release];
        return cell;
    }

    // === Transit URL (section 0, row 1) — text field =====================
    // === Direct BaseURL (section 1, row 0) — text field ==================
    // === Direct API Key (section 1, row 1) — text field =================
    // === Model (section 2, row 0) — text field ===========================
    // === Temperature (section 2, row 1) — text field =====================
    // === System prompt (section 3, row 0) — text field ===================
    //
    // All share the same textfield-host cell layout.
    NSString *key = [self _keyForLogical:logical row:indexPath.row];
    NSString *current = [settings objectForKey:key];
    if ([current isKindOfClass:[NSNumber class]]) current = [current stringValue];
    if (!current) current = @"";

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(15, 8, 120, 28)];
    label.text = [self _labelForLogical:logical row:indexPath.row];
    label.backgroundColor = [UIColor clearColor];
    label.font = [UIFont systemFontOfSize:15];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [cell.contentView addSubview:label];
    [label release];

    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(140, 6, 170, 32)];
    field.borderStyle = UITextBorderStyleNone;
    field.font = [UIFont systemFontOfSize:14];
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
    if (logical == 4 && indexPath.row == 0) {
        [self resetToDefaults];
    }
    else if (logical == 0 && indexPath.row == 2) {
        // Provider picker — show UIAlertView with one button per provider.
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
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
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
    if (logical == 2 && row == 1) {
        [d setFloat:(float)[field.text doubleValue] forKey:key];
    } else {
        [d setObject:field.text ?: @"" forKey:key];
    }
    [d synchronize];
}

- (IBAction)_transitToggleChanged:(UISwitch *)sw
{
    self.useTransit = sw.on;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:sw.on forKey:SettingsKeyUseTransit];
    [d synchronize];

    // Section count changes when toggle flips, so reload everything.
    _fields = [NSMutableDictionary dictionary];
    [self.tableView reloadData];
}

#pragma mark - Section mapping

// Returns the logical section index (0=Transit, 1=Direct, 2=Model, 3=Prompt, 4=Reset)
// for a given visible section index. When transit is ON, the "Direct server"
// section is hidden, so all later sections shift down by one.
- (NSInteger)_logicalSectionForDisplayed:(NSInteger)displayed
{
    if (_useTransit) {
        // [0]=Transit, [1]=Model, [2]=Prompt, [3]=Reset
        // Visible: 0 → 0 (Transit), 1 → 2 (Model), 2 → 3 (Prompt), 3 → 4 (Reset)
        switch (displayed) {
            case 0: return 0; // Transit
            case 1: return 2; // Model
            case 2: return 3; // Prompt
            case 3: return 4; // Reset
            default: return 4;
        }
    }
    return displayed; // All sections visible, identity mapping.
}

- (NSString *)_keyForLogical:(NSInteger)logical row:(NSInteger)row
{
    switch (logical) {
        case 0: return row == 1 ? SettingsKeyTransitURL : (row == 2 ? SettingsKeyProvider : SettingsKeyUseTransit);
        case 1: return row == 0 ? SettingsKeyBaseURL : SettingsKeyAPIKey;
        case 2: return row == 0 ? SettingsKeyModel : SettingsKeyTemperature;
        case 3: return SettingsKeySystemPrompt;
        default: return @"";
    }
}

- (NSString *)_labelForLogical:(NSInteger)logical row:(NSInteger)row
{
    switch (logical) {
        case 0:
            return row == 0 ? NSLocalizedString(@"使用中转", nil) :
                   row == 1 ? NSLocalizedString(@"Transit URL", nil) :
                              NSLocalizedString(@"Provider", nil);
        case 1:
            return row == 0 ? NSLocalizedString(@"Base URL", nil) :
                              NSLocalizedString(@"API Key", nil);
        case 2:
            return row == 0 ? NSLocalizedString(@"Model", nil) :
                              NSLocalizedString(@"Temperature", nil);
        case 3:
            return NSLocalizedString(@"Prompt", nil);
        default:
            return @"";
    }
}

- (NSString *)_placeholderForLogical:(NSInteger)logical row:(NSInteger)row
{
    switch (logical) {
        case 0: return row == 1 ? kDefaultTransitURL : @"";
        case 1: return row == 0 ? @"https://api.openai.com" : @"sk-...";
        case 2: return row == 0 ? @"gpt-4o-mini" : @"0.7";
        case 3: return NSLocalizedString(@"You are a helpful assistant.", nil);
        default: return @"";
    }
}

- (void)dealloc
{
    [_tableView release];
    [_fields release];
    [_provider release];
    [super dealloc];
}

@end

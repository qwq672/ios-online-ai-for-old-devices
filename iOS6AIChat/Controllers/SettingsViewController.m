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
#import "Logger.h"
// v261025-3: needed for [ModelManagementViewController removeAllTransitModels]
// + sourceForModel: + instantiate throwaway VC for searchTransitBundledModels
#import "ModelManagementViewController.h"
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
// v261025-3: transit-server bundled model toggle (off by default).
// When ON, the app calls GET /v1/transit/models and bulk-adds returned
// models to local storage with source="transit". When OFF, all
// source="transit" models are bulk-removed.
NSString *const SettingsKeyUseTransitModels = @"useTransitModels";
// v261025-3: timestamp of the last successful /v1/transit/models search.
// Stored as an NSDate; formatted for display in the toggle row's footer.
NSString *const SettingsKeyTransitModelsLastSearch = @"transitModelsLastSearch";

NSString *const ProviderIDZhipu    = @"zhipu";
NSString *const ProviderIDDeepSeek = @"deepseek";
NSString *const ProviderIDKimi     = @"kimi";
NSString *const ProviderIDOpenAI   = @"openai";
NSString *const ProviderIDAnthropic = @"anthropic";
NSString *const ProviderIDOllama   = @"ollama";

// v261025-8: the active image-generation model (kind="image" entry).
// Parallel to SettingsKeyModel (chat model).
NSString *const SettingsKeyImageGenModel = @"imageGenModel";

// v261025-9: the new two-tier provider list (replaces the flat
// SettingsKeyModelList for fresh installs). Migration is automatic on the
// first read of +[ModelManagementViewController savedProviders]: if the
// new key is empty but the old key has data, the flat entries are
// grouped by (provider, baseURL, apiKey) and lifted into provider entries.
NSString *const SettingsKeyProviderList = @"providerList";

// v261025-9: template ids are identical to the v261025-8 provider ids.
// "custom" is a new addition.
NSString *const ProviderTemplateCustom = @"custom";

// v261025-9: API format ids.
NSString *const ProviderFormatOpenAI    = @"openai";
NSString *const ProviderFormatAnthropic = @"anthropic";
NSString *const ProviderFormatOllama    = @"ollama";

NSString *const iOS6ThemeDidChangeNotification = @"iOS6ThemeDidChangeNotification";

static NSString *const kDefaultTransitURL = @"https://ai-transit.awa.lat";

// Layout constants.
// v261025-5: bumped kLabelWidth 80→96 so 4-character Chinese labels like
// "图片压缩" and "中转搜索" don't truncate to "图片压" / "中转搜".
// (User-reported screenshot IMG_0455 showed exactly this truncation.)
static CGFloat const kLabelWidth = 96.0f;
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
    // v261025-1: also cancel any deferred sheet presentation still pending.
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
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
    // v261025-8: full provider roster. Order = display order in pickers.
    return @[ProviderIDZhipu, ProviderIDDeepSeek, ProviderIDKimi,
             ProviderIDOpenAI, ProviderIDAnthropic, ProviderIDOllama];
}

+ (NSString *)displayNameForProvider:(NSString *)providerID
{
    if ([providerID isEqualToString:ProviderIDZhipu])     return @"智谱";
    if ([providerID isEqualToString:ProviderIDDeepSeek])  return @"DeepSeek";
    if ([providerID isEqualToString:ProviderIDKimi])      return @"Kimi";
    if ([providerID isEqualToString:ProviderIDOpenAI])    return @"OpenAI";
    if ([providerID isEqualToString:ProviderIDAnthropic]) return @"Anthropic";
    if ([providerID isEqualToString:ProviderIDOllama])    return @"Ollama";
    if ([providerID isEqualToString:@"custom"])           return @"自定义";
    return providerID ?: @"Custom";
}

+ (NSString *)defaultModelForProvider:(NSString *)providerID
{
    if ([providerID isEqualToString:ProviderIDZhipu])     return @"glm-4-flash";
    if ([providerID isEqualToString:ProviderIDDeepSeek])  return @"deepseek-chat";
    if ([providerID isEqualToString:ProviderIDKimi])      return @"moonshot-v1-8k";
    if ([providerID isEqualToString:ProviderIDOpenAI])    return @"gpt-4o-mini";
    if ([providerID isEqualToString:ProviderIDAnthropic]) return @"claude-3-5-haiku-20241022";
    if ([providerID isEqualToString:ProviderIDOllama])    return @"llama3.2";
    return @"gpt-4o-mini";
}

// v261025-7: default endpoint per provider — used by ModelAddViewController
// to auto-fill the BaseURL field when the user switches the provider
// segment, and as the fallback when an entry has no baseURL of its own.
+ (NSString *)defaultBaseURLForProvider:(NSString *)providerID
{
    if ([providerID isEqualToString:ProviderIDZhipu]) {
        return @"https://open.bigmodel.cn/api/paas/v4";
    }
    if ([providerID isEqualToString:ProviderIDDeepSeek]) {
        return @"https://api.deepseek.com";
    }
    if ([providerID isEqualToString:ProviderIDKimi]) {
        return @"https://api.moonshot.cn/v1";
    }
    if ([providerID isEqualToString:ProviderIDAnthropic]) {
        return @"https://api.anthropic.com";
    }
    if ([providerID isEqualToString:ProviderIDOllama]) {
        return @"http://localhost:11434";
    }
    // default + ProviderIDOpenAI
    return @"https://api.openai.com";
}

// v261025-8: Anthropic speaks its own /v1/messages format; every other
// provider (incl. Ollama's OpenAI-compat endpoint and all the Chinese
// vendors) is OpenAI-compatible. NetworkService branches on this.
+ (BOOL)providerUsesAnthropicFormat:(NSString *)providerID
{
    return [providerID isEqualToString:ProviderIDAnthropic];
}

// v261025-8: quick-pick model list for the add-model form (and the
// ModelMgmt /v1/models search fallback). kind = "chat" | "image".
+ (NSArray *)commonModelsForProvider:(NSString *)providerID kind:(NSString *)kind
{
    BOOL image = [kind isEqualToString:@"image"];
    if (image) {
        // Only Zhipu + OpenAI (and custom endpoints) have image-gen APIs.
        if ([providerID isEqualToString:ProviderIDZhipu]) {
            return @[@"cogview-3plus", @"cogview-4-250304", @"cogview-3-flash"];
        }
        if ([providerID isEqualToString:ProviderIDOpenAI]) {
            return @[@"gpt-image-1", @"dall-e-3", @"dall-e-2"];
        }
        return @[];
    }
    if ([providerID isEqualToString:ProviderIDZhipu]) {
        return @[@"glm-4-plus", @"glm-4-air", @"glm-4-flash", @"glm-4-long",
                 @"glm-4-flashx", @"glm-4v"];
    }
    if ([providerID isEqualToString:ProviderIDDeepSeek]) {
        return @[@"deepseek-chat", @"deepseek-reasoner"];
    }
    if ([providerID isEqualToString:ProviderIDKimi]) {
        return @[@"moonshot-v1-8k", @"moonshot-v1-32k", @"moonshot-v1-128k",
                 @"kimi-latest"];
    }
    if ([providerID isEqualToString:ProviderIDOpenAI]) {
        return @[@"gpt-4o", @"gpt-4o-mini", @"gpt-4.1", @"gpt-4.1-mini",
                 @"o4-mini", @"gpt-3.5-turbo"];
    }
    if ([providerID isEqualToString:ProviderIDAnthropic]) {
        return @[@"claude-sonnet-4-20250514", @"claude-3-5-haiku-20241022",
                 @"claude-3-5-sonnet-20241022", @"claude-3-haiku-20240307"];
    }
    if ([providerID isEqualToString:ProviderIDOllama]) {
        return @[@"llama3.2", @"qwen2.5", @"phi3", @"gemma2"];
    }
    return @[];
}

// v261025-8: does this provider have an image-generation endpoint?
+ (BOOL)providerSupportsImageGen:(NSString *)providerID
{
    return [providerID isEqualToString:ProviderIDZhipu] ||
           [providerID isEqualToString:ProviderIDOpenAI] ||
           [providerID isEqualToString:ProviderTemplateCustom];
}

// v261025-9: template roster (display order). All seven — six known
// providers plus "custom". Mirrors availableProviderIDs + custom appended.
+ (NSArray *)availableTemplateIDs
{
    return [NSArray arrayWithObjects:
            ProviderIDZhipu, ProviderIDDeepSeek, ProviderIDKimi,
            ProviderIDOpenAI, ProviderIDAnthropic, ProviderIDOllama,
            ProviderTemplateCustom, nil];
}

// v261025-9: template → canonical API format. "custom" defaults to openai
// (the most common case for OpenAI-compat custom endpoints; the form lets
// the user override to anthropic or ollama manually).
+ (NSString *)formatForTemplate:(NSString *)templateID
{
    if (![templateID isKindOfClass:[NSString class]] || templateID.length == 0) {
        return ProviderFormatOpenAI;
    }
    if ([templateID isEqualToString:ProviderIDAnthropic]) return ProviderFormatAnthropic;
    if ([templateID isEqualToString:ProviderIDOllama])    return ProviderFormatOllama;
    return ProviderFormatOpenAI;
}

// v261025-9: format → matching templates. Used by the add-provider form to
// filter the template picker after the user picks a format segment.
+ (NSArray *)templatesForFormat:(NSString *)formatID
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *t in [self availableTemplateIDs]) {
        if ([[self formatForTemplate:t] isEqualToString:formatID]) {
            [out addObject:t];
        }
    }
    return out;
}

// v261025-9: template → default baseURL. Thin wrapper over the existing
// defaultBaseURLForProvider: for the known six; custom → @"" (empty).
+ (NSString *)defaultBaseURLForTemplate:(NSString *)templateID
{
    if ([templateID isEqualToString:ProviderTemplateCustom]) return @"";
    return [self defaultBaseURLForProvider:templateID];
}

// v261025-9: reverse-map a typed baseURL → which template (if any) it
// matches. Returns ProviderTemplateCustom when no template's default
// matches. Trims trailing slashes for the comparison.
+ (NSString *)templateForBaseURL:(NSString *)baseURL
{
    if (![baseURL isKindOfClass:[NSString class]] || baseURL.length == 0) {
        return ProviderTemplateCustom;
    }
    NSString *trimmed = [baseURL stringByTrimmingCharactersInSet:
                         [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    for (NSString *t in [self availableTemplateIDs]) {
        if ([t isEqualToString:ProviderTemplateCustom]) continue;
        NSString *def = [self defaultBaseURLForTemplate:t];
        if (def.length == 0) continue;
        NSString *defTrim = [def stringByTrimmingCharactersInSet:
                             [NSCharacterSet characterSetWithCharactersInString:@"/"]];
        if ([trimmed isEqualToString:defTrim]) return t;
    }
    return ProviderTemplateCustom;
}

// v261025-9: human-friendly name for a template id. Thin wrapper over
// displayNameForProvider: (which already handles the custom case).
+ (NSString *)displayNameForTemplate:(NSString *)templateID
{
    if ([templateID isEqualToString:ProviderTemplateCustom]) {
        return NSLocalizedString(@"自定义", nil);
    }
    return [self displayNameForProvider:templateID];
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
                                SettingsKeyModelList,    // also reset saved model list
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
        case kSectionTransit:    return 6;  // 使用中转 / Transit URL / Provider / 中转网络搜索 / 中转默认模型 / 中转自带模型
        case kSectionDirect:     return 2;
        // v261025-8: 模型管理入口（模型/生图模型/能力开关全部集中在
        // ModelManagementViewController —— 设置页不再重复一份模型表单，
        // 两处同时维护正是“逻辑乱”的根源）。
        case kSectionModel:      return 1;
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
    // v261025-7: shared transparent header (replaces the local variant —
    // same idea, one implementation everywhere).
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    return [iOS6Theme groupedSectionHeaderViewWithTitle:title
                                                  width:tableView.bounds.size.width];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    return (title.length > 0) ? 26.0f : 8.0f;
}

// v261025-7: custom TRANSPARENT footer views — the system footer draws an
// opaque LIGHT strip (white bar in dark mode, user-reported).
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
            return NSLocalizedString(@"全局默认连接：模型条目未单独指定 BaseURL / API Key 时回退到这里。Anthropic 格式（a/）会自动改用 /v1/messages 协议。", nil);
        case kSectionModel:
            return NSLocalizedString(@"对话模型与生图模型都在「模型管理」里添加、分组、切换和测试（支持 智谱 / DeepSeek / Kimi / OpenAI / Anthropic / Ollama）。", nil);
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
    // v261025-2: snapshot subviews — see CharacterManagementVC for the
    // full root-cause writeup. Mutating subviews while iterating it is
    // SIGSEGV on cctools-port armv7.
    NSArray *oldSubviews = [cell.contentView.subviews copy];
    for (UIView *v in oldSubviews) [v removeFromSuperview];
    [oldSubviews release];
    // Reset cell properties to prevent reuse artifacts.
    cell.textLabel.text = @"";
    cell.textLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
    cell.textLabel.textColor = [iOS6Theme textColor];
    cell.textLabel.textAlignment = NSTextAlignmentLeft;
    cell.textLabel.numberOfLines = 1;
    // v261025-7: explicit CLEAR label background (dark-mode white-plate fix).
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.textLabel.opaque = NO;
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
    // v261025-5: shrink font for long labels so e.g. "图片压缩" at the
    // user's bumped font-size still fits in kLabelWidth instead of
    // truncating to "图片压". minScaleFactor does the work; numberOfLines
    // stays 1 so a single line is enforced.
    l.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.7f;
    l.numberOfLines = 1;
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
    if ([providerID isEqualToString:ProviderIDDeepSeek]) {
        return @[@"deepseek-chat", @"deepseek-reasoner"];
    }
    if ([providerID isEqualToString:ProviderIDKimi]) {
        return @[@"moonshot-v1-8k", @"moonshot-v1-32k"];
    }
    if ([providerID isEqualToString:ProviderIDOpenAI]) {
        return @[@"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo", @"gpt-3.5-turbo"];
    }
    if ([providerID isEqualToString:ProviderIDAnthropic]) {
        return @[@"claude-3-5-haiku-20241022", @"claude-3-5-sonnet-20241022"];
    }
    if ([providerID isEqualToString:ProviderIDOllama]) {
        return @[@"llama3.2", @"qwen2.5", @"phi3", @"gemma2"];
    }
    return @[@"gpt-4o-mini"];
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
    // row 2: Provider picker — v261025-8 改成点击行弹 UIActionSheet。
    // 提供商已扩展到 6 家（智谱/DeepSeek/Kimi/OpenAI/Anthropic/Ollama），
    // 分段控件放不下；action sheet 每项一行更清楚，还能带副标题。
    // 该 provider 是「全局默认」—— 模型条目未指定自己的 provider 时用它。
    if (row == 2) {
        [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"默认提供商", nil)]];
        NSString *provName = [SettingsViewController displayNameForProvider:_provider];
        UILabel *provVal = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
        provVal.text = provName ?: @"OpenAI";
        provVal.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        provVal.textColor = [iOS6Theme secondaryTextColor];
        provVal.backgroundColor = [UIColor clearColor];
        provVal.textAlignment = NSTextAlignmentRight;
        provVal.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        CGRect pvF = cell.contentView.bounds;
        provVal.frame = CGRectMake(kPad + kLabelWidth + 8, 0,
                                   pvF.size.width - kPad - kLabelWidth - 8 - kPad - 26, kRowH);
        [cell.contentView addSubview:provVal];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
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
    if (row == 4) {
        // 中转默认模型 toggle (default OFF).
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
    // v261025-3 row 5: 中转自带模型 toggle (default OFF) + 上次搜索时间。
    // ON  → fetch GET /v1/transit/models; if enabled, bulk-add models to
    //         local storage with source="transit". If disabled, prompt
    //         "此中转服务器不含自带模型".
    // OFF → bulk-remove all source="transit" models.
    // The toggle handler (_useTransitModelsToggle:) creates a throwaway
    // ModelManagementViewController to call its searchTransitBundledModels
    // method (the search logic + UI live there).
    [cell.contentView addSubview:[self _labelWithText:NSLocalizedString(@"中转自带模型", nil)]];
    UISwitch *sw3 = [[[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 79, 27)] autorelease];
    BOOL useTransitModels = [[NSUserDefaults standardUserDefaults] boolForKey:SettingsKeyUseTransitModels];
    [sw3 setOn:useTransitModels animated:NO];
    [sw3 addTarget:self action:@selector(_useTransitModelsToggle:)
     forControlEvents:UIControlEventValueChanged];
    sw3.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    CGRect f5 = cell.contentView.bounds;
    sw3.frame = CGRectMake(f5.size.width - 79 - kPad, (kRowH - 27) / 2, 79, 27);
    [cell.contentView addSubview:sw3];
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
    // v261025-8: 单一入口行 —— 模型的增删改查、分组、生图模型、能力
    // 开关全部集中在 ModelManagementViewController。设置页旧的
    // “Model 手填 + /v1/models 搜索 + 能力开关”三套东西和模型管理页
    // 重复且易失同步 —— 全部移除，只剩这一行入口。
    cell.textLabel.text = NSLocalizedString(@"模型管理…", nil);
    cell.textLabel.textColor = [iOS6Theme tintColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
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
    }
    // v261025-8: 模型管理入口行 → push ModelManagementViewController。
    else if (logical == kSectionModel) {
        ModelManagementViewController *mm = [[[ModelManagementViewController alloc] init] autorelease];
        [self.navigationController pushViewController:mm animated:YES];
    }
    // v261025-8: 默认提供商行 → 弹提供商选择 sheet（tag 450）。
    else if (logical == kSectionTransit && indexPath.row == 2) {
        [self _presentProviderSheet];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

// v261025-8: provider picker — 6 家 + 自定义，action sheet 每项一行。
- (void)_presentProviderSheet
{
    UIActionSheet *sheet = [[[UIActionSheet alloc]
        initWithTitle:NSLocalizedString(@"选择默认提供商", nil)
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
    [sheet setTag:450];
    [sheet showInView:self.view];
}

// v261025-8: /v1/models 搜索 + tag-400 模型选择 sheet 已随设置页模型表单一起移除
// —— 模型搜索/选择/管理统一在 ModelManagementViewController。

#pragma mark - Toggle handlers

// v261025-8: 图片识别/思考开关已移至 ModelManagementViewController 的能力段
// （与设置页重复维护正是逻辑乱源），对应 handler 一并移除。

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

// v261025-3: 中转自带模型 toggle.
//   ON  → instantiate a throwaway ModelMgmt VC and call its
//         searchTransitBundledModels method. The VC is retained by the
//         dispatch_async block until the search completes (or fails),
//         then released. The VC's _tableView is nil so the reloadData
//         call inside is a no-op — Settings' own table will be reloaded
//         when the user navigates back.
//   OFF → bulk-remove all source="transit" models. The removal is
//         synchronous (just an NSUserDefaults write).
- (IBAction)_useTransitModelsToggle:(UISwitch *)sw
{
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:SettingsKeyUseTransitModels];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (sw.on) {
        // Defer the search to the next runloop turn so this toggle's
        // row redraw completes first (avoid a table-while-toggling UI
        // glitch — the throwaway VC will display its own alert.
        [self performSelector:@selector(_kickoffTransitBundledModelSearch)
                   withObject:nil
                   afterDelay:0.1];
    } else {
        // Bulk-remove all transit-sourced models from local storage.
        // If the user's current default model was a transit one, fall
        // back to the first remaining user-sourced model.
        [ModelManagementViewController removeAllTransitModels];
        NSString *curDefault = [[NSUserDefaults standardUserDefaults] stringForKey:SettingsKeyModel];
        NSString *curSrc = [ModelManagementViewController sourceForModel:curDefault];
        if ([curSrc isEqualToString:@"transit"]) {
            // Current default was a transit model that just got removed —
            // pick the first remaining user model (if any).
            NSArray *remaining = [ModelManagementViewController savedModelList];
            if ([remaining count] > 0) {
                [[NSUserDefaults standardUserDefaults] setObject:[remaining objectAtIndex:0]
                                                          forKey:SettingsKeyModel];
            } else {
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:SettingsKeyModel];
            }
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
        [[Logger sharedLogger] info:@"Settings: transit bundled models toggled OFF — bulk-removed"];
        // Reload this table to refresh the footer's last-search hint.
        if (_tableView) [_tableView reloadData];
    }
}

// Called via performSelector:withObject:afterDelay:0.1 from the toggle.
// Lives here so the toggle handler stays short.
- (void)_kickoffTransitBundledModelSearch
{
    // v261025-3: throwaway VC. Its dispatch_async block retains it, so
    // the autorelease + manual release here is safe — the block will
    // release it when the search completes.
    ModelManagementViewController *tmp = [[[ModelManagementViewController alloc] init] autorelease];
    // Keep it alive past this autoreleasepool — the dispatch_async in
    // searchTransitBundledModels captures self (tmp) and retains it,
    // but ONLY after we enter that method. Between this point and that
    // dispatch_async call, tmp's retaincount is exactly 1 (from alloc),
    // which the autorelease will decrement at pool drain. To prevent a
    // premature release, do a manual retain here and let the dispatch
    // block's release drop it to 0 when done. Actually simpler: skip
    // autorelease, do manual alloc+retain+release-after-search.
    // But the cleanest pattern is just to NOT autorelease here — the
    // dispatch_async will own the only reference.
    // (We DID autorelease above to balance the alloc; the dispatch_async
    // block in searchTransitBundledModels retains self, so tmp stays
    // alive until that block completes. The autorelease here drains at
    // the runloop end, but the block's retain keeps it alive.)
    [tmp searchTransitBundledModels];
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

// v261025-8: provider picker sheet (tag 450). iOS 6 cancel occupies
// index 0; provider options live at 1..N (6 providers + 自定义 at 7).
- (void)actionSheet:(UIActionSheet *)actionSheet
clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (actionSheet.tag != 450) return;
    if (buttonIndex == actionSheet.cancelButtonIndex) return;
    NSArray *providers = [SettingsViewController availableProviderIDs];
    NSInteger modelIndex = buttonIndex - 1;
    NSString *newProv = nil;
    if (modelIndex >= 0 && modelIndex < (NSInteger)[providers count]) {
        newProv = [providers objectAtIndex:modelIndex];
    } else if (modelIndex == (NSInteger)[providers count]) {
        newProv = @"custom";
    }
    if (![newProv isKindOfClass:[NSString class]] || newProv.length == 0) return;
    [self _applyGlobalProvider:newProv];
}

// Shared apply: persist provider (+ default model + default baseURL when
// the current one is empty or still an untouched provider default).
- (void)_applyGlobalProvider:(NSString *)newProv
{
    self.provider = newProv;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:newProv forKey:SettingsKeyProvider];
    [d setObject:[SettingsViewController defaultModelForProvider:newProv]
      forKey:SettingsKeyModel];
    // v261025-8: 全局 BaseURL 跟随新提供商 —— 仅当它为空或仍是某家的
    // 默认值时（用户手填的自定义 URL 永不覆盖）。
    NSString *curBase = [d stringForKey:SettingsKeyBaseURL] ?: @"";
    BOOL isDefaultURL = (curBase.length == 0);
    for (NSString *p in [SettingsViewController availableProviderIDs]) {
        if ([curBase isEqualToString:[SettingsViewController defaultBaseURLForProvider:p]]) {
            isDefaultURL = YES;
            break;
        }
    }
    if (isDefaultURL) {
        [d setObject:[SettingsViewController defaultBaseURLForProvider:newProv]
          forKey:SettingsKeyBaseURL];
    }
    [d synchronize];
    [_fields release];
    _fields = [[NSMutableDictionary alloc] init];
    [_tableView reloadData];
    [[Logger sharedLogger] info:[NSString stringWithFormat:@"Settings global provider → %@", newProv]];
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

//
//  SettingsViewController.h
//  iOS6AIChat
//
//  Settings keys — persisted to NSUserDefaults.
//  Sections in the table view:
//    0) Theme         — dark mode toggle, font size stepper
//    1) Transit       — toggle + transit URL + provider picker
//    2) Direct server  — BaseURL + API Key (hidden when transit ON)
//    3) Model         — model picker (auto-search /v1/models + manual)
//    4) Web Search    — Tavily toggle + API Key + result count
//    5) System Prompt
//    6) About         — author / version / github link
//    7) Reset
//

#import <UIKit/UIKit.h>

extern NSString *const SettingsKeyDarkMode;
extern NSString *const SettingsKeyFontSize;
extern NSString *const SettingsKeyUseTransit;
extern NSString *const SettingsKeyTransitURL;
extern NSString *const SettingsKeyProvider;
extern NSString *const SettingsKeyBaseURL;
extern NSString *const SettingsKeyAPIKey;
extern NSString *const SettingsKeyModel;
extern NSString *const SettingsKeyModelList;
extern NSString *const SettingsKeyModelSupportsImages;
extern NSString *const SettingsKeyModelSupportsThinking;
extern NSString *const SettingsKeyStreamingOutput;
extern NSString *const SettingsKeyTemperature;
extern NSString *const SettingsKeySystemPrompt;
extern NSString *const SettingsKeyWebSearchEnabled;
extern NSString *const SettingsKeyTavilyAPIKey;
extern NSString *const SettingsKeyTavilyMaxResults;
// v261025-3: transit-server bundled model toggle.
//   ON  → app calls /v1/transit/models, auto-adds returned models to the
//         local Model management with source="transit".
//   OFF → all source="transit" models are bulk-removed from local storage.
extern NSString *const SettingsKeyUseTransitModels;
// v261025-3: timestamp of the last successful /v1/transit/models search
// (formatted as a localized date string, displayed in Settings under the
// toggle row to remind the user when they last refreshed).
extern NSString *const SettingsKeyTransitModelsLastSearch;
// v261025-8: the ACTIVE image-generation model id (kind="image" entry in
// the model list). Parallel to SettingsKeyModel which tracks the chat model.
extern NSString *const SettingsKeyImageGenModel;

// Provider IDs.
// v261025-8: 用户明确了提供商概念 —— DeepSeek / BigModel(智谱) / Kimi 这类是
// 「模型提供商」；OpenAI / Anthropic / Ollama 这类既是提供商也定义了
// 「API 格式」。App 内统一用 provider id 表达，NetworkService 再把
// provider 映射到请求格式（OpenAI 兼容 / Anthropic 原生）。
extern NSString *const ProviderIDZhipu;
extern NSString *const ProviderIDDeepSeek;
extern NSString *const ProviderIDKimi;
extern NSString *const ProviderIDOpenAI;
extern NSString *const ProviderIDAnthropic;
extern NSString *const ProviderIDOllama;

@interface SettingsViewController : UIViewController
                              <UITableViewDataSource,
                               UITableViewDelegate,
                               UITextFieldDelegate,
                               UIAlertViewDelegate,
                               UIActionSheetDelegate>

@property (nonatomic, retain) UITableView *tableView;

// Read all persisted settings as a dict, with sensible defaults.
+ (NSDictionary *)loadSettings;

// Save the whole dict atomically.
+ (void)saveSettings:(NSDictionary *)dict;

// Provider display-name helpers.
+ (NSArray *)availableProviderIDs;
+ (NSString *)displayNameForProvider:(NSString *)providerID;
+ (NSString *)defaultModelForProvider:(NSString *)providerID;
// v261025-7: default endpoint per provider (ModelAddViewController form).
+ (NSString *)defaultBaseURLForProvider:(NSString *)providerID;
// v261025-8: does this provider speak the Anthropic /v1/messages format?
// (All others use the OpenAI-compatible /v1/chat/completions format.)
+ (BOOL)providerUsesAnthropicFormat:(NSString *)providerID;
// v261025-8: quick-pick model lists for the add-model form.
// kind: "chat" | "image". Returns NSString model ids.
+ (NSArray *)commonModelsForProvider:(NSString *)providerID kind:(NSString *)kind;
// v261025-8: does this provider have an image-generation endpoint?
+ (BOOL)providerSupportsImageGen:(NSString *)providerID;

// Default seed list of saved models per provider (v261024-15).
// Used by ModelManagementViewController when the user has no saved list yet.
+ (NSArray *)_defaultModelListForProvider:(NSString *)providerID;

- (void)resetToDefaults;

@end

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

// v261025-11: global image-generation FEATURE switch (default ON).
// When OFF: the composer 加号 menu hides the 生图模式 toggle, ModelMgmt
// hides the image-model row, and sends never route to the image API.
extern NSString *const SettingsKeyImageGenFeatureEnabled;

// v261025-11: model-autonomous capability switches (default OFF).
// "支持自主联网搜索" — the model has built-in web search (no Tavily
// tool-calls needed); when ON we append a system-prompt hint telling the
// model to use its own search.
// "支持自主读取URL" — the model can fetch URLs by itself; same prompt hint.
extern NSString *const SettingsKeyModelAutonomousWebSearch;
extern NSString *const SettingsKeyModelAutonomousURLReading;

// v261025-9: the two-tier provider list (new structure, replaces
// SettingsKeyModelList for fresh installs; old key is auto-migrated on
// first read of +[ModelManagementViewController savedProviders]).
// Schema:
//   [{ id, format, template, displayName, baseURL, apiKey, collapsed,
//      models: [{ id, starred, kind, displayName }] }]
extern NSString *const SettingsKeyProviderList;

// Provider IDs (a.k.a. "templates" in v261025-9 two-tier nomenclature).
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
// v261025-9: "custom" is a template id meaning "user-supplied endpoint that
// doesn't match any known template" (form auto-selects it when the typed
// baseURL matches no template default).
extern NSString *const ProviderTemplateCustom;

// v261025-9: API formats (the OTHER tier — what wire protocol to speak).
//   openai    = /v1/chat/completions (OpenAI / 智谱 / DeepSeek / Kimi /
//               Ollama's OpenAI-compat /v1 endpoint / any custom OpenAI-compat)
//   anthropic = /v1/messages (Anthropic only)
//   ollama    = /api/chat (Ollama native — NOT yet implemented in
//               NetworkService as of v9; ollama templates still go through
//               the openai-compat /v1 path. Future work.)
extern NSString *const ProviderFormatOpenAI;
extern NSString *const ProviderFormatAnthropic;
extern NSString *const ProviderFormatOllama;

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

// v261025-9: two-tier helpers (format ↔ template).
// All seven template ids in display order: zhipu/deepseek/kimi/openai/
// anthropic/ollama/custom.
+ (NSArray *)availableTemplateIDs;
// Map a template id → its canonical API format. "custom" defaults to openai
// (the most common case; the user can override format manually in the form).
+ (NSString *)formatForTemplate:(NSString *)templateID;
// Templates that match a given format (e.g. openai → zhipu/deepseek/kimi/
// openai/ollama/custom; anthropic → anthropic; ollama → ollama).
+ (NSArray *)templatesForFormat:(NSString *)formatID;
// Default endpoint for a template. Same values as defaultBaseURLForProvider:
// (kept as a thin wrapper for naming consistency with the new vocabulary).
+ (NSString *)defaultBaseURLForTemplate:(NSString *)templateID;
// Reverse-map a typed baseURL → which template (if any) it matches.
// Returns ProviderTemplateCustom when no template's default matches.
+ (NSString *)templateForBaseURL:(NSString *)baseURL;
// Human-friendly name for a template id (same as displayNameForProvider:
// plus the "custom" case). Thin wrapper.
+ (NSString *)displayNameForTemplate:(NSString *)templateID;

// Default seed list of saved models per provider (v261024-15).
// Used by ModelManagementViewController when the user has no saved list yet.
+ (NSArray *)_defaultModelListForProvider:(NSString *)providerID;

- (void)resetToDefaults;

@end

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

// Provider IDs.
extern NSString *const ProviderIDZhipu;
extern NSString *const ProviderIDOpenAI;
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

// Default seed list of saved models per provider (v261024-15).
// Used by ModelManagementViewController when the user has no saved list yet.
+ (NSArray *)_defaultModelListForProvider:(NSString *)providerID;

- (void)resetToDefaults;

@end

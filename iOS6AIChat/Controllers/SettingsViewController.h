//
//  SettingsViewController.h
//  iOS6AIChat
//
//  Provider presets — maps a UI label to the wire-format string sent
//  in the X-Provider header to the transit server, plus a sensible
//  default model name to prefill.
//

#import <UIKit/UIKit.h>

extern NSString *const SettingsKeyUseTransit;     // BOOL — relay mode toggle
extern NSString *const SettingsKeyTransitURL;     // NSString — relay server base
extern NSString *const SettingsKeyProvider;       // NSString — "zhipu" | "openai" | "ollama" | "" (custom)
extern NSString *const SettingsKeyBaseURL;        // NSString — direct mode base URL
extern NSString *const SettingsKeyAPIKey;         // NSString — provider API key
extern NSString *const SettingsKeyModel;          // NSString — model name
extern NSString *const SettingsKeyTemperature;    // NSNumber — 0..1
extern NSString *const SettingsKeySystemPrompt;    // NSString

// Canonical provider IDs and display labels — keep in sync with the
// transit server at https://github.com/qwq672/online-ai-transit-server
extern NSString *const ProviderIDZhipu;
extern NSString *const ProviderIDOpenAI;
extern NSString *const ProviderIDOllama;

@interface SettingsViewController : UIViewController
                              <UITableViewDataSource,
                               UITableViewDelegate,
                               UITextFieldDelegate,
                               UIAlertViewDelegate>

@property (nonatomic, retain) UITableView *tableView;

// Read all persisted settings as a dictionary, with sensible defaults.
+ (NSDictionary *)loadSettings;

// Save the whole dict atomically (writes through to NSUserDefaults).
+ (void)saveSettings:(NSDictionary *)dict;

// Convenience — given a provider id, return the default model name.
+ (NSString *)defaultModelForProvider:(NSString *)providerID;

// Convenience — all available provider IDs in display order.
+ (NSArray *)availableProviderIDs;
+ (NSString *)displayNameForProvider:(NSString *)providerID;

- (void)resetToDefaults;

@end

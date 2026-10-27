//
//  ModelManagementViewController.h
//  iOS6AIChat
//
//  v261025-9: TWO-TIER provider/model management (rewritten).
//    Section 0:   当前默认 (resolved chat model + 生图 model + 测试/搜索)
//    Sections 1..N: one section PER PROVIDER ENTRY (collapsible).
//                   Header tap = toggle collapse; row tap = set active;
//                   star button on row = toggle starred;
//                   (DetailDisclosure on header = push ProviderEditViewController)
//                   swipe-row = delete that model
//    Section N+1: + 添加模型供应商 (→ pushes ModelAddViewController)
//    Section N+2: 能力开关 (图片识别 / 思考)
//
//  v261025-9 entry schema (SettingsKeyProviderList JSON array):
//    { id: "uuid",                          // stable provider UUID
//      format: "openai"|"anthropic"|"ollama",
//      template: "deepseek"|"kimi"|"zhipu"|"openai"|"anthropic"|"ollama"|"custom",
//      displayName: "DeepSeek",             // shown in section header
//      baseURL: "https://api.deepseek.com",
//      apiKey: "sk-...",                    // per-provider key override
//      collapsed: BOOL,                      // section UI state
//      models: [
//        { id: "deepseek-chat",             // model id (unique within provider)
//          starred: BOOL,                    // appears in composer 加号 menu
//          kind: "chat"|"image"|nil,        // image = 生图 model
//          displayName: "..."|nil           // friendly per-model name
//        }
//      ]
//    }
//
//  Migration: when SettingsKeyProviderList is empty/missing but the legacy
//  SettingsKeyModelList has flat entries {id, source, provider, baseURL,
//  apiKey, displayName, kind}, they are grouped by (provider, baseURL,
//  apiKey) into provider entries. Each flat entry's id+kind+displayName
//  becomes a model inside the resulting provider entry.
//
//  The CHAT path: +resolvedConnectionForChat looks up the ACTIVE model
//  (SettingsKeyModel) across all providers' models[], returns the
//  parent provider's {format, template, baseURL, apiKey} + the model id.
//  v261025-8: the IMAGE-GEN path: +resolvedConnectionForImageGen looks up
//  the active image model (SettingsKeyImageGenModel) the same way.
//

#import <UIKit/UIKit.h>
#import "SettingsViewController.h"   // for SettingsKey* + Provider* constants

@class ModelAddViewController;
@class ProviderEditViewController;

@interface ModelManagementViewController : UIViewController
                              <UITableViewDataSource,
                               UITableViewDelegate,
                               UIAlertViewDelegate,
                               UIActionSheetDelegate>

@property (nonatomic, retain) UITableView *tableView;
@property (nonatomic, retain) NSMutableArray *availableModels;  // for /v1/models search picker

// ---- v261025-9 new two-tier provider persistence (canonical API) ----
// Returns the saved provider entries (auto-migrates the legacy flat list
// on first call). Each entry is a dict per the schema above.
+ (NSArray *)savedProviders;
+ (void)saveProviders:(NSArray *)providers;
// Generate a stable UUID string (used as provider entry id on creation).
// Public so ModelAddViewController / ProviderEditViewController can call it.
+ (NSString *)newProviderUUID;

// v261025-10: starred-model helpers for the composer 加号 menu.
// +starredChatModels returns an array of dicts:
//   { id: modelID, displayName: "...", providerDisplayName: "...", active: BOOL }
// across ALL providers' models where starred=YES and kind != "image".
// +starredImageModels is the same but for kind == "image" entries.
// Both return an empty array when no models are starred.
+ (NSArray *)starredChatModels;
+ (NSArray *)starredImageModels;

// Look up the provider entry that owns the given model id.
// Returns nil when no provider has a model with that id.
+ (NSDictionary *)providerEntryContainingModel:(NSString *)modelID;

// Toggle the collapsed state of a provider entry (persisted immediately).
// No-op if the id doesn't match any provider.
+ (void)toggleCollapsedForProviderID:(NSString *)providerUUID;

// Toggle the starred state of a model inside a provider entry.
// No-op if the provider or model isn't found.
+ (void)toggleStarredForModel:(NSString *)modelID
                inProviderID:(NSString *)providerUUID;

// Set which model is the active chat/image model (writes SettingsKeyModel
// or SettingsKeyImageGenModel depending on the model's kind).
+ (void)setActiveModel:(NSString *)modelID;

// Add / remove a single model inside an existing provider entry.
+ (void)addModel:(NSString *)modelID
            kind:(NSString *)kind      // "chat"|"image"|nil -> "chat"
    toProviderID:(NSString *)providerUUID;
+ (void)removeModel:(NSString *)modelID
     fromProviderID:(NSString *)providerUUID;
// Replace a provider entry wholesale (used by ProviderEditViewController
// when the user edits the format/template/baseURL/apiKey/models).
+ (void)replaceProviderWithID:(NSString *)providerUUID
                    newEntry:(NSDictionary *)newEntry;
// Remove an entire provider entry (and all its models). Also clears
// SettingsKeyModel / SettingsKeyImageGenModel if they pointed at one of
// this provider's models.
+ (void)removeProviderWithID:(NSString *)providerUUID;

// ---- Legacy back-compat shims (v261025-7 callers) ----
// v261025-9: these now read/write the new two-tier structure but expose
// a flat view of just the model dicts ({id, kind, starred, displayName,
// provider, baseURL, apiKey}). Old callers (ChatViewController's fallback,
// Settings's removeAllTransitModels) keep working without code changes.
+ (NSArray *)savedModelEntries;
+ (NSArray *)savedModelList;                       // IDs only (back-compat)
+ (void)saveModelEntries:(NSArray *)entries;       // merges into provider list
+ (void)saveModelList:(NSArray *)list;             // back-compat (all source=user)
+ (void)addModel:(NSString *)model;                // bare id (legacy)
+ (void)addModelEntry:(NSDictionary *)entry;       // merges into provider list
+ (void)removeModel:(NSString *)model;
// v261025-3: bulk operations for transit-sourced models.
+ (void)addTransitModels:(NSArray *)modelIDs;     // add with source="transit"
+ (void)removeAllTransitModels;                    // remove all source="transit"
+ (NSString *)sourceForModel:(NSString *)model;    // "user" | "transit"

// ---- v261025-9 resolved connection for the chat path ----
// Returns { format, template, baseURL, apiKey, model } for the ACTIVE
// chat model. Falls back to global settings when no model is set or the
// model id can't be found in any provider entry.
+ (NSDictionary *)resolvedConnectionForChat;

// ---- v261025-9 resolved connection for the image-gen path ----
// Returns { format, template, baseURL, apiKey, model } for the ACTIVE
// image model. model is @"" when no image model is configured -
// ChatViewController prompts the user to add one.
+ (NSDictionary *)resolvedConnectionForImageGen;

// v261025-8: is this entry/model an 生图 model? (kind=="image"; absent = chat)
+ (BOOL)entryIsImageKind:(NSDictionary *)entry;
+ (BOOL)modelIsImageKind:(NSDictionary *)modelDict;

// v261025-3: search the transit server's bundled model list
// (GET /v1/transit/models). If the server returns enabled=false,
// prompt the user with "此中转服务器不含自带模型". If enabled=true,
// the returned models are bulk-added to local storage with
// source="transit". Mid-search the user can cancel.
- (void)searchTransitBundledModels;

@end

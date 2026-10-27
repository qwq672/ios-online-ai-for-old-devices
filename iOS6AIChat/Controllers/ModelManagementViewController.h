//
//  ModelManagementViewController.h
//  iOS6AIChat
//
//  v261025-7: two-tier provider/model management.
//    Section 0: 当前默认模型 (resolved active entry + 测试/搜索 buttons)
//    Sections 1..N: one section PER PROVIDER (zhipu / openai / ollama /
//                   custom) — rows are that provider's saved models.
//                   Tap row = set active. Swipe = delete.
//    Section N+1: 添加 (+ 添加模型 → pushes ModelAddViewController form)
//    Section N+2: 能力开关 (图片识别 / 思考)
//
//  v261025-7 entry schema (SettingsKeyModelList JSON array):
//    { id: "glm-4-flash",            // model id (required, unique)
//      source: "user"|"transit",     // provenance badge
//      provider: "zhipu"|nil,        // NEW: which provider this runs on
//      baseURL: "https://..."|nil,   // NEW: per-entry endpoint override
//      apiKey: "sk-..."|nil,         // NEW: per-entry key override
//      displayName: "智谱免费"|nil,   // NEW: friendly name shown in list
//      kind: "chat"|"image"|nil      // v261025-8: kind="image" entries are
//                                    } 生图模型 (composer 生图 mode);
//                                    chat/absent = regular conversation model
//    }
//  Entries missing the new keys (pre-v261025-7 files) resolve their
//  connection details from the global Settings at use time — fully
//  backward compatible.
//
//  The CHAT path now goes through +resolvedConnectionForChat, which merges
//  the active entry's overrides with the global settings defaults.
//  v261025-8: the IMAGE-GEN path goes through +resolvedConnectionForImageGen
//  (active kind="image" entry — tracked by SettingsKeyImageGenModel).
//

#import <UIKit/UIKit.h>
#import "SettingsViewController.h"   // for SettingsKeyModelList helpers

@class ModelAddViewController;

@interface ModelManagementViewController : UIViewController
                              <UITableViewDataSource,
                               UITableViewDelegate,
                               UIAlertViewDelegate,
                               UIActionSheetDelegate>

@property (nonatomic, retain) UITableView *tableView;
@property (nonatomic, retain) NSMutableArray *availableModels;  // for /v1/models search picker

// ---- Entry persistence (v261025-7 canonical dict-array API) ----
+ (NSArray *)savedModelEntries;
+ (NSArray *)savedModelList;                       // IDs only (back-compat)
+ (void)saveModelEntries:(NSArray *)entries;
+ (void)saveModelList:(NSArray *)list;             // back-compat (all source=user)
+ (void)addModel:(NSString *)model;                // bare id (legacy)
+ (void)addModelEntry:(NSDictionary *)entry;       // full entry (v261025-7)
+ (void)removeModel:(NSString *)model;
// v261025-3: bulk operations for transit-sourced models.
+ (void)addTransitModels:(NSArray *)modelIDs;     // add with source="transit"
+ (void)removeAllTransitModels;                    // remove all source="transit"
+ (NSString *)sourceForModel:(NSString *)model;    // "user" | "transit"

// ---- v261025-7 resolved connection for the chat path ----
// Returns { provider, baseURL, apiKey, model } merged from the ACTIVE
// entry (looked up by SettingsKeyModel) and global settings defaults.
// Callers use this instead of reading SettingsKey* directly.
+ (NSDictionary *)resolvedConnectionForChat;

// ---- v261025-8 resolved connection for the image-gen path ----
// Returns { provider, baseURL, apiKey, model } for the ACTIVE image model
// (looked up by SettingsKeyImageGenModel). model is @"" when no image
// model is configured — the caller should prompt the user to add one.
+ (NSDictionary *)resolvedConnectionForImageGen;

// v261025-8: is this entry a 生图 model? (kind=="image"; absent = chat)
+ (BOOL)entryIsImageKind:(NSDictionary *)entry;

// v261025-3: search the transit server's bundled model list
// (GET /v1/transit/models). If the server returns enabled=false,
// prompt the user with "此中转服务器不含自带模型". If enabled=true,
// the returned models are bulk-added to local storage with
// source="transit". Mid-search the user can cancel.
- (void)searchTransitBundledModels;

@end

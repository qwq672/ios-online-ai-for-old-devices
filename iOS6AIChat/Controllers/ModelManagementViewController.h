//
//  ModelManagementViewController.h
//  iOS6AIChat
//
//  v261024-15: independent model management page (moved out of Settings).
//    Sections:
//      0) 当前默认模型 + 搜索 /v1/models
//      1) 已保存模型列表 (点行=设默认, 编辑模式删行)
//      2) 添加新模型 (alert 输入)
//      3) 能力开关 (支持图片识别 / 支持思考)
//

#import <UIKit/UIKit.h>
#import "SettingsViewController.h"   // for SettingsKeyModelList helpers

@interface ModelManagementViewController : UIViewController
                              <UITableViewDataSource,
                               UITableViewDelegate,
                               UIAlertViewDelegate,
                               UIActionSheetDelegate>

@property (nonatomic, retain) UITableView *tableView;
@property (nonatomic, retain) NSMutableArray *availableModels;  // for /v1/models search picker

// v261025-3: storage now holds dict entries [{id, source}].
// savedModelEntries / saveModelEntries: are the canonical dict-array API.
// savedModelList / saveModelList: are back-compat shims (IDs only,
// treated as source="user" on save).
+ (NSArray *)savedModelEntries;
+ (NSArray *)savedModelList;
+ (void)saveModelEntries:(NSArray *)entries;
+ (void)saveModelList:(NSArray *)list;
+ (void)addModel:(NSString *)model;
+ (void)removeModel:(NSString *)model;
// v261025-3: bulk operations for transit-sourced models.
+ (void)addTransitModels:(NSArray *)modelIDs;     // add with source="transit"
+ (void)removeAllTransitModels;                    // remove all source="transit"
+ (NSString *)sourceForModel:(NSString *)model;    // "user" | "transit"

// v261025-3: search the transit server's bundled model list
// (GET /v1/transit/models). If the server returns enabled=false,
// prompt the user with "此中转服务器不含自带模型". If enabled=true,
// the returned models are bulk-added to local storage with
// source="transit". Mid-search the user can cancel.
- (void)searchTransitBundledModels;

@end

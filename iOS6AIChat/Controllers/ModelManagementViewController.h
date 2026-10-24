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

@end

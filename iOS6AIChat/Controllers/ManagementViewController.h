//
//  ManagementViewController.h
//  iOS6AIChat
//
//  v261024-15: independent management hub (Plan 2).
//    Reached from HistoryViewController's tableFooterView "⚙️ 管理" button.
//    Each row pushes a dedicated child VC (设置 / 模型管理 / 角色管理 / 日志).
//

#import <UIKit/UIKit.h>

@interface ManagementViewController : UIViewController
                              <UITableViewDataSource,
                               UITableViewDelegate>

@property (nonatomic, retain) UITableView *tableView;

@end

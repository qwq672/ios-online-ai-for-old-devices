//
//  LogViewController.h
//  iOS6AIChat
//
//  v261024-15: in-app log viewer.
//    Sections:
//      0) 开关 + 清空按钮 + 显示文件路径
//      1) 日志内容 (single cell containing a self-sizing UITextView)
//

#import <UIKit/UIKit.h>

@interface LogViewController : UIViewController
                              <UITableViewDataSource,
                               UITableViewDelegate>

@property (nonatomic, retain) UITableView *tableView;

@end

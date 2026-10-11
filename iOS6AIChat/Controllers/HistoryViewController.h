//
//  HistoryViewController.h
//  iOS6AIChat
//

#import <UIKit/UIKit.h>

@interface HistoryViewController : UIViewController
                              <UITableViewDataSource,
                               UITableViewDelegate>

@property (nonatomic, retain) UITableView *tableView;
@property (nonatomic, retain) UIBarButtonItem *editButton;

@end

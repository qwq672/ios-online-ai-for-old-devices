//
//  CharacterManagementViewController.h
//  iOS6AIChat
//
//  v261024-15: independent character-management page.
//    Sections:
//      0) 添加新角色（alert 输入名称 + 提示词）
//      1) 已保存角色列表（tap = 设为激活, swipe = 删除）
//      2) 当前激活角色显示
//      3) 「用户身份注入」开关（默认 ON — 把当前设备名作为 system prompt 前缀注入）
//

#import <UIKit/UIKit.h>

@interface CharacterManagementViewController : UIViewController
                              <UITableViewDataSource,
                               UITableViewDelegate,
                               UIAlertViewDelegate>

@property (nonatomic, retain) UITableView *tableView;

// Compose the final system prompt that gets prepended to AI requests.
// 1) If injectUserIdentity ON, prepend "User identity: <device-name>"
// 2) If active character exists, append its prompt
// 3) Append `base` (the user's regular system prompt from Settings)
+ (NSString *)effectiveSystemPromptWithBase:(NSString *)base;

@end

//
//  ProviderEditViewController.h
//  iOS6AIChat
//
//  v261025-9: edit an existing provider entry (the two-tier structure).
//  Pushed by ModelManagementViewController when the user taps the blue
//  DetailDisclosure button on a provider section header.
//
//  Sections:
//    0) 格式    — format segmented (openai / anthropic / ollama)
//    1) 模板    — template picker row (action sheet, filtered by format)
//    2) 连接    — BaseURL + API Key (text fields, edit-in-place)
//    3) 测试    — 测试连接 button (GET {baseURL}/v1/models or /v1/messages)
//    4) 模型    — list of this provider's models with star toggle + swipe-delete
//                 + a "添加模型" row at the bottom (manual id input via alert)
//                 + a "搜索模型" row (GET /v1/models → action-sheet picker)
//    5) 删除    — destructive row "删除整个供应商"
//
//  Saving: every change is persisted immediately to SettingsKeyProviderList
//  via +[ModelManagementViewController replaceProviderWithID:newEntry:].
//  No explicit "保存" button — edit-in-place UX (matches the rest of the
//  Settings/ModelMgmt flow).
//

#import <UIKit/UIKit.h>
#import "SettingsViewController.h"

@interface ProviderEditViewController : UIViewController
                              <UITableViewDataSource,
                               UITableViewDelegate,
                               UITextFieldDelegate,
                               UIActionSheetDelegate,
                               UIAlertViewDelegate>

// Initialize with the provider entry to edit (a deep copy is kept; the
// original is replaced wholesale on save). The id is preserved.
- (id)initWithProviderEntry:(NSDictionary *)entry;

@end

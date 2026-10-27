//
//  ComposerPlusMenuView.h
//  iOS6AIChat
//
//  v261025-10: 半屏从下滑入菜单，整合 ComposerView 的 4 个常驻 toggle
//  (deepThinking / webSearch / imageGen / imageUpload) + 切换模型 + 切换角色
//  + 清空对话。点 plusButton 触发呈现，从底部滑入到屏幕下 1/3 处停。
//
//  段布局 (tableView grouped style):
//    Section 0 - 模式 (toggle)
//      row 0: 深度思考 (UISwitch)
//      row 1: 联网搜索 (UISwitch)
//      row 2: 生图模式 (UISwitch)  ← ON 时输入框变蓝 (delegate 通知)
//    Section 1 - 动作 (tap → action)
//      row 0: 📷 上传/识别图片
//      (v261025-11 精简: 清空对话/更多模型/更多角色 三行已删 — 后两者与
//       切换模型/切换角色 段末尾的 "更多…" 行完全重复)
//
//  呈现: 全屏蒙层 (半透明黑) + 屏幕下 1/3 的圆角白底菜单。
//  关闭: 点蒙层 / 上滑手势 / 选中模型后自动 / 切到其他 action 后自动。
//

#import <UIKit/UIKit.h>

@class ComposerPlusMenuView;

@protocol ComposerPlusMenuDelegate <NSObject>
@optional
// toggle changed (deepThinking/webSearch/imageGen). The composer's plus
// button badge count should refresh; the textView's background may also
// change (image-gen ON → light blue).
- (void)plusMenu:(ComposerPlusMenuView *)menu
  deepThinkingEnabledChanged:(BOOL)enabled;
- (void)plusMenu:(ComposerPlusMenuView *)menu
  webSearchEnabledChanged:(BOOL)enabled;
- (void)plusMenu:(ComposerPlusMenuView *)menu
  imageGenEnabledChanged:(BOOL)enabled;
// tap actions — delegate handles the actual picker / navigation / alert.
- (void)plusMenuDidTapImageUpload:(ComposerPlusMenuView *)menu;
- (void)plusMenuDidTapMoreModels:(ComposerPlusMenuView *)menu;
- (void)plusMenuDidTapMoreCharacters:(ComposerPlusMenuView *)menu;
// user picked a specific model / character from the inline submenu.
- (void)plusMenu:(ComposerPlusMenuView *)menu
  didSelectChatModelID:(NSString *)modelID;
- (void)plusMenu:(ComposerPlusMenuView *)menu
  didSelectImageModelID:(NSString *)modelID;
- (void)plusMenu:(ComposerPlusMenuView *)menu
  didSelectCharacterName:(NSString *)name;
@end

@interface ComposerPlusMenuView : UIView
                              <UITableViewDataSource,
                               UITableViewDelegate>

@property (nonatomic, assign) id<ComposerPlusMenuDelegate> delegate;

// Show the menu as a modal overlay over the given view (the chat VC's
// root view). Animates the menu sliding up from below + the dim layer
// fading in. Cheap to call repeatedly — re-uses the same instance.
- (void)showInView:(UIView *)parentView;
// Dismiss with a slide-down animation. Safe to call when not shown.
- (void)dismissAnimated;

// Refresh the inline model/character submenus (call after the user toggles
// a star or adds/removes a model, so the next show reflects current state).
- (void)refresh;

@end

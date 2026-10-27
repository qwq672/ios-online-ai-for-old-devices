//
//  ComposerView.h
//  iOS6AIChat
//
//  v261025-10: simplified layout — only [+] [─── input ───] [➤Send].
//  The four toggle buttons (image / deepThinking / webSearch / imageGen)
//  moved into a slide-up 加号 menu (ComposerPlusMenuView). The plus button
//  shows a red badge with the count of currently-active toggles so the
//  user can tell at a glance how many modes are on.
//
//  When image-gen is ON, the input field's background turns light blue
//  and the placeholder becomes "输入生图提示" — a stronger signal than
//  the old per-button highlight.
//

#import <UIKit/UIKit.h>

extern NSString *const ComposerViewSendMessageNotification;
extern NSString *const ComposerViewSendMessageTextKey;
extern NSString *const ComposerViewSendMessageDeepThinkingKey;
extern NSString *const ComposerViewSendMessageWebSearchKey;
extern NSString *const ComposerViewSendMessageImagesKey;

@class ComposerView;
@class ComposerPlusMenuView;

@protocol ComposerViewDelegate <NSObject>
@optional
// v261025-8: signature extended with imageGen: — YES when the 生图 toggle
// is on (send goes to the image-generation path, not the chat stream).
- (void)composer:(ComposerView *)composer didSendText:(NSString *)text
              images:(NSArray *)images
        deepThinking:(BOOL)deepThinking webSearch:(BOOL)webSearch
            imageGen:(BOOL)imageGen;
- (void)composerDidChangeHeight:(ComposerView *)composer;
// v261025-3: fired when the user taps the send/stop button while a
// stream is in flight. The send button becomes a "stop" button while
// isStreaming=YES — tapping it should call NetworkService.stopGenerating
// to preserve the partial text and fire the normal didFinish path.
// v261025-8: this ALSO fires while an image generation is running —
// the delegate should cancel its pending image-gen completion.
- (void)composerDidTapStop:(ComposerView *)composer;
// v261025-10: fired when the user taps the plus button. The delegate
// (ChatViewController) should create / show the ComposerPlusMenuView.
- (void)composerDidTapPlusButton:(ComposerView *)composer;
// v261025-10: fired after any toggle state changes from the plus menu
// (so the plus button's badge count and the input field's image-gen
// blue tint can refresh).
- (void)composerToggleStateDidChange:(ComposerView *)composer;
@end

@interface ComposerView : UIView <UITextViewDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>

@property (nonatomic, assign) id<ComposerViewDelegate> delegate;
@property (nonatomic, retain) UITextView *textView;
@property (nonatomic, retain) UIButton  *sendButton;
// v261025-10: replaces the four old toggle buttons. Tap → menu.
@property (nonatomic, retain) UIButton *plusButton;
// v261025-10: badge showing the count of active toggles (1/2/3).
@property (nonatomic, retain) UILabel *plusBadge;
@property (nonatomic, assign) BOOL isStreaming;

// v261025-10: retained UIColor ivars for layer.borderColor — assigning a
// bare [UIColor ...].CGColor leaves a dangling ref after the autorelease
// pool drains (same crash class as v261025-5's text-view border).
// Field border color is the standard one; image-gen mode swaps in a
// blue tint by switching the ivar (and refreshing layer.borderColor).
@property (nonatomic, retain) UIColor *fieldBorderUIColor;

+ (BOOL)deepThinkingEnabled;
+ (void)setDeepThinkingEnabled:(BOOL)enabled;
+ (BOOL)webSearchEnabled;
+ (void)setWebSearchEnabled:(BOOL)enabled;
+ (BOOL)imageGenEnabled;
+ (void)setImageGenEnabled:(BOOL)enabled;

// v261025-10: count of currently-active toggles (DT + Web + imageGen).
// The plus button badge displays this number. Public so
// ComposerPlusMenuView can read it for badge refresh.
+ (NSInteger)activeToggleCount;

// v261025-10: refresh the plus button badge + input field background
// (call after any toggle change). Public so ComposerPlusMenuView can
// invoke it via the delegate path without having to import ComposerView
// internals.
- (void)refreshPlusButtonVisuals;

// v261025-10: present the UIImagePickerController from the given VC.
// The composer owns the picker delegate + _pendingImages array; this
// just kicks off the picker presentation. Public so ChatViewController's
// plus-menu callback can trigger image upload.
- (void)presentImagePickerFromViewController:(UIViewController *)vc;

- (void)clearText;

@end

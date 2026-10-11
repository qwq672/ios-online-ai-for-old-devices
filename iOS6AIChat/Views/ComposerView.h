//
//  ComposerView.h
//  iOS6AIChat
//
//  Bottom composer bar with:
//     - iOS 6 textured pinstripe background
//     - Rounded, glossed UITextView ("Type a message…")
//     - Glossed tinted Send button
//     - Deep Thinking toggle button (left of input)
//       — when ON, sends prepend a chain-of-thought system instruction
//       so the model shows step-by-step reasoning before answering.
//     - Web Search toggle button (left of Deep Thinking)
//       — when ON, ChatVC does a Tavily /search first and injects
//       results as context before the AI request.
//
//  Sends a ComposerViewSendMessageNotification with the current text +
//  deepThinking + webSearch flags when the user taps Send.
//

#import <UIKit/UIKit.h>

extern NSString *const ComposerViewSendMessageNotification;
extern NSString *const ComposerViewSendMessageTextKey;
extern NSString *const ComposerViewSendMessageDeepThinkingKey;
extern NSString *const ComposerViewSendMessageWebSearchKey;

@class ComposerView;

@protocol ComposerViewDelegate <NSObject>
@optional
- (void)composer:(ComposerView *)composer didSendText:(NSString *)text
        deepThinking:(BOOL)deepThinking webSearch:(BOOL)webSearch;
- (void)composerDidChangeHeight:(ComposerView *)composer;
@end

@interface ComposerView : UIView <UITextViewDelegate>

@property (nonatomic, assign) id<ComposerViewDelegate> delegate;
@property (nonatomic, retain) UITextView *textView;
@property (nonatomic, retain) UIButton  *sendButton;
@property (nonatomic, retain) UIButton *deepThinkingButton;   // toggle, persists to NSUserDefaults
@property (nonatomic, retain) UIButton *webSearchButton;      // toggle, persists to NSUserDefaults
@property (nonatomic, assign) BOOL isStreaming;   // YES: disable send button

// Convenience accessors for the toggles' persisted state.
+ (BOOL)deepThinkingEnabled;
+ (void)setDeepThinkingEnabled:(BOOL)enabled;
+ (BOOL)webSearchEnabled;
+ (void)setWebSearchEnabled:(BOOL)enabled;

- (void)clearText;

@end

//
//  ComposerView.h
//  iOS6AIChat
//
//  Simple single-row composer:
//    [💡DT] [🌐Web] [   input field (multi-line)   ] [➤Send]
//
//  All on ONE row. Height starts at 44pt, grows as text expands.
//  Uses UIButtonTypeRoundedRect for iOS 6 native button look.
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
@property (nonatomic, retain) UIButton *deepThinkingButton;
@property (nonatomic, retain) UIButton *webSearchButton;
@property (nonatomic, assign) BOOL isStreaming;

+ (BOOL)deepThinkingEnabled;
+ (void)setDeepThinkingEnabled:(BOOL)enabled;
+ (BOOL)webSearchEnabled;
+ (void)setWebSearchEnabled:(BOOL)enabled;

- (void)clearText;

@end

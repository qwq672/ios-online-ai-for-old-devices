//
//  ComposerView.h
//  iOS6AIChat
//
//  Bottom composer bar with:
//     - iOS 6 textured pinstripe background
//     - Rounded, glossed UITextField ("Type a message…")
//     - Glossed blue Send button
//
//  Sends a ComposerViewSendMessageNotification with the current text
//  when the user taps Send.
//

#import <UIKit/UIKit.h>

extern NSString *const ComposerViewSendMessageNotification;
extern NSString *const ComposerViewSendMessageTextKey;

@class ComposerView;

@protocol ComposerViewDelegate <NSObject>
@optional
- (void)composer:(ComposerView *)composer didSendText:(NSString *)text;
- (void)composerDidChangeHeight:(ComposerView *)composer;
@end

@interface ComposerView : UIView <UITextViewDelegate>

@property (nonatomic, assign) id<ComposerViewDelegate> delegate;
@property (nonatomic, retain) UITextView *textView;
@property (nonatomic, retain) UIButton  *sendButton;
@property (nonatomic, assign) BOOL isStreaming;   // YES: disable send button

- (void)clearText;

@end

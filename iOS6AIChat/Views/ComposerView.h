//
//  ComposerView.h
//  iOS6AIChat
//
//  Single-row composer with image upload:
//    [📷] [💡DT] [🌐Web] [   input field   ] [➤Send]
//

#import <UIKit/UIKit.h>

extern NSString *const ComposerViewSendMessageNotification;
extern NSString *const ComposerViewSendMessageTextKey;
extern NSString *const ComposerViewSendMessageDeepThinkingKey;
extern NSString *const ComposerViewSendMessageWebSearchKey;
extern NSString *const ComposerViewSendMessageImagesKey;

@class ComposerView;

@protocol ComposerViewDelegate <NSObject>
@optional
- (void)composer:(ComposerView *)composer didSendText:(NSString *)text
              images:(NSArray *)images
        deepThinking:(BOOL)deepThinking webSearch:(BOOL)webSearch;
- (void)composerDidChangeHeight:(ComposerView *)composer;
// v261025-3: fired when the user taps the send/stop button while a
// stream is in flight. The send button becomes a "stop" button while
// isStreaming=YES — tapping it should call NetworkService.stopGenerating
// to preserve the partial text and fire the normal didFinish path.
- (void)composerDidTapStop:(ComposerView *)composer;
@end

@interface ComposerView : UIView <UITextViewDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>

@property (nonatomic, assign) id<ComposerViewDelegate> delegate;
@property (nonatomic, retain) UITextView *textView;
@property (nonatomic, retain) UIButton  *sendButton;
@property (nonatomic, retain) UIButton *deepThinkingButton;
@property (nonatomic, retain) UIButton *webSearchButton;
@property (nonatomic, retain) UIButton *imageButton;
@property (nonatomic, retain) UILabel  *imageBadge;
@property (nonatomic, assign) BOOL isStreaming;

+ (BOOL)deepThinkingEnabled;
+ (void)setDeepThinkingEnabled:(BOOL)enabled;
+ (BOOL)webSearchEnabled;
+ (void)setWebSearchEnabled:(BOOL)enabled;

- (void)clearText;

@end

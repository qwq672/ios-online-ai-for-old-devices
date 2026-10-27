//
//  ComposerView.h
//  iOS6AIChat
//
//  Single-row composer with image upload:
//    [📷] [💡DT] [🌐Web] [🖼生图] [   input field   ] [➤Send]
//
//  v261025-8: added the 生图 (image generation) toggle. While ON, sending
//  routes the text to the image-generation API (active kind="image"
//  model) instead of the chat completion — deep-thinking and web-search
//  toggles are visually disabled in that mode (they don't apply).
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
@end

@interface ComposerView : UIView <UITextViewDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>

@property (nonatomic, assign) id<ComposerViewDelegate> delegate;
@property (nonatomic, retain) UITextView *textView;
@property (nonatomic, retain) UIButton  *sendButton;
@property (nonatomic, retain) UIButton *deepThinkingButton;
@property (nonatomic, retain) UIButton *webSearchButton;
@property (nonatomic, retain) UIButton *imageButton;
@property (nonatomic, retain) UIButton *imageGenButton;
@property (nonatomic, retain) UILabel  *imageBadge;
@property (nonatomic, assign) BOOL isStreaming;

+ (BOOL)deepThinkingEnabled;
+ (void)setDeepThinkingEnabled:(BOOL)enabled;
+ (BOOL)webSearchEnabled;
+ (void)setWebSearchEnabled:(BOOL)enabled;
// v261025-8: 生图 toggle state (persisted like the other two).
+ (BOOL)imageGenEnabled;
+ (void)setImageGenEnabled:(BOOL)enabled;

- (void)clearText;

@end

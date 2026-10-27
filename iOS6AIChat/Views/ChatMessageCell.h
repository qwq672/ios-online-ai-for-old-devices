//
//  ChatMessageCell.h
//  iOS6AIChat
//
//  UITableViewCell subclass for a single chat message.
//  Owns:
//     - ChatBubbleView as the message background
//     - UITextView to render the attributed text (works on iOS 6)
//
//  Layout:
//     - User messages are pinned to the right
//     - Assistant messages are pinned to the left
//     - 12pt horizontal padding from screen edge
//     - 6pt vertical padding between bubbles
//

#import <UIKit/UIKit.h>
#import "Message.h"
#import "ChatBubbleView.h" // pull in BubbleRole

@class ChatMessageCell;

@protocol ChatMessageCellDelegate <NSObject>
@optional
- (void)chatCell:(ChatMessageCell *)cell didTapRegenerate:(Message *)message;
- (void)chatCell:(ChatMessageCell *)cell didTapCopy:(Message *)message;
// v261025-6: user-message edit — shows an alert with the user's original
// text; on save, truncates the conversation from this message onward and
// re-sends the (possibly edited) text.
- (void)chatCell:(ChatMessageCell *)cell didTapEditUserMessage:(Message *)message;
// v261025-6: variant pager — navigate to previous / next AI-response variant.
- (void)chatCell:(ChatMessageCell *)cell didTapVariantArrow:(Message *)message direction:(NSInteger)direction;  // -1 = prev, +1 = next
// v261025-8: the user tapped the generated image — open the full-screen viewer.
- (void)chatCellDidTapGeneratedImage:(ChatMessageCell *)cell message:(Message *)message;
@end

@interface ChatMessageCell : UITableViewCell

@property (nonatomic, assign) id<ChatMessageCellDelegate> delegate;
@property (nonatomic, retain) UITextView       *textView;     // displays attributed text
@property (nonatomic, retain) ChatBubbleView   *bubble;       // bubble background view
@property (nonatomic, retain) Message          *message;
@property (nonatomic, retain) NSAttributedString *renderedAttr;
@property (nonatomic, retain) UIButton *regenerateButton;  // AI reply only
@property (nonatomic, retain) UIButton *clipboardButton;    // AI reply only (copy)
// v261025-6: user-message edit button — shown on user cells only.
@property (nonatomic, retain) UIButton *editButton;
// v261025-6: variant pager — "‹ 1/N ›" UI + prev/next arrow buttons.
// Shown on AI cells where the message has more than one response variant.
@property (nonatomic, retain) UIButton *variantPrevButton;
@property (nonatomic, retain) UIButton *variantNextButton;
@property (nonatomic, retain) UILabel *variantIndexLabel;

// Convenience sizing helper — computes the height required to display
// the given message at the given width, accounting for text wrapping.
+ (CGFloat)heightForMessage:(Message *)message width:(CGFloat)width;

// Flush render caches (attributed strings bake in theme colors).
// Call when dark/light mode or font size changes.
+ (void)flushCaches;

// v261025-8: drop ONLY the height cache (not the rendered-attr cache).
// Called when a message's content changes shape outside the streaming
// path — e.g. an image-generation placeholder ("正在生成图片…") becomes
// an image bubble. NSCache has no prefix eviction, so this clears the
// whole height cache; heights rebuild lazily on the next layout pass.
+ (void)invalidateHeightCache;

- (void)applyMessage:(Message *)message;

@end

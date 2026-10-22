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
@end

@interface ChatMessageCell : UITableViewCell

@property (nonatomic, assign) id<ChatMessageCellDelegate> delegate;
@property (nonatomic, retain) UITextView       *textView;     // displays attributed text
@property (nonatomic, retain) ChatBubbleView   *bubble;       // bubble background view
@property (nonatomic, retain) Message          *message;
@property (nonatomic, retain) NSAttributedString *renderedAttr;
@property (nonatomic, retain) UIButton *regenerateButton;  // AI reply only
@property (nonatomic, retain) UIButton *clipboardButton;    // AI reply only (copy)

// Convenience sizing helper — computes the height required to display
// the given message at the given width, accounting for text wrapping.
+ (CGFloat)heightForMessage:(Message *)message width:(CGFloat)width;

- (void)applyMessage:(Message *)message;

@end

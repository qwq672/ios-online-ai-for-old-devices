//
//  ChatMessageCell.m
//  iOS6AIChat
//

#import "ChatMessageCell.h"
#import "iOS6Theme.h"
#import "MarkdownParser.h"

@implementation ChatMessageCell

@synthesize textView=_textView, bubble=_bubble, message=_message, renderedAttr=_renderedAttr;

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if (self = [super initWithStyle:style reuseIdentifier:reuseIdentifier]) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.contentView.backgroundColor = [UIColor clearColor];

        _bubble = [[ChatBubbleView alloc] initWithFrame:CGRectZero];
        [self.contentView addSubview:_bubble];

        _textView = [[UITextView alloc] initWithFrame:CGRectZero];
        _textView.backgroundColor = [UIColor clearColor];
        _textView.editable = NO;
        _textView.scrollEnabled = NO;
        // UITextView.textContainer / textContainerInset are iOS 7+.
        // They don't exist in the iOS 6 SDK headers, so we don't call them
        // via the property syntax — would error at compile time. Instead
        // we use performSelector:withObject: which the compiler accepts.
        if ([_textView respondsToSelector:@selector(setTextContainerInset:)]) {
            [_textView performSelector:@selector(setTextContainerInset:)
                             withObject:[NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(7, 10, 7, 10)]];
        }
        _textView.font = [UIFont systemFontOfSize:16];
        _textView.textColor = [iOS6Theme textColor];
        _textView.dataDetectorTypes = UIDataDetectorTypeLink;
        _textView.userInteractionEnabled = YES;
        [_bubble addSubview:_textView];
    }
    return self;
}

- (void)applyMessage:(Message *)message
{
    self.message = message;

    BubbleRole role = message.isUser ? BubbleRoleUser : BubbleRoleAssistant;
    _bubble.role = role;

    UIFont *base = [UIFont systemFontOfSize:15];
    CGFloat textWidth = self.bounds.size.width - 2 * 12 - 2 * 10 - 8;
    if (textWidth < 100) textWidth = 200;

    // Build the attributed string and cache it so we don't have to recompute
    // during height queries (which run synchronously before layout).
    self.renderedAttr = [MarkdownParser attributedStringFromMarkdown:message.content
                                                             baseFont:base
                                                                width:textWidth];
    _textView.attributedText = _renderedAttr;
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    if (!_message) return;

    CGFloat pad = 12.0f;
    CGFloat bubbleInnerHPad = 10.0f;
    CGFloat bubbleInnerVPad = 7.0f;
    CGFloat verticalPad = 6.0f;
    CGFloat maxBubbleWidth = self.bounds.size.width - 2 * pad;
    maxBubbleWidth = MIN(maxBubbleWidth, 280.0f);

    CGFloat availTextWidth = maxBubbleWidth - 2 * bubbleInnerHPad - 8;
    if (availTextWidth < 60) availTextWidth = 60;

    // Measure using the cached attributed string.
    CGRect textRect = CGRectZero;
    if (_renderedAttr) {
        textRect = [_renderedAttr boundingRectWithSize:CGSizeMake(availTextWidth, CGFLOAT_MAX)
                                              options:(NSStringDrawingUsesLineFragmentOrigin |
                                                       NSStringDrawingUsesFontLeading)
                                              context:nil];
    }
    if (textRect.size.height < 20) textRect.size.height = 20;

    CGFloat bubbleWidth  = MAX(textRect.size.width + 2 * bubbleInnerHPad + 8, 60);
    bubbleWidth = MIN(bubbleWidth, maxBubbleWidth);
    CGFloat bubbleHeight = textRect.size.height + 2 * bubbleInnerVPad + 6 + 4; // tail + inset slack

    CGFloat bubbleX;
    if (_message.isUser) {
        bubbleX = self.bounds.size.width - bubbleWidth - pad;
    } else {
        bubbleX = pad;
    }
    CGFloat bubbleY = verticalPad;
    CGRect bubbleRect = CGRectMake(bubbleX, bubbleY, bubbleWidth, bubbleHeight);
    _bubble.frame = bubbleRect;
    _textView.frame = CGRectMake(4, 4, bubbleWidth - 8, bubbleHeight - 8);
}

+ (CGFloat)heightForMessage:(Message *)message width:(CGFloat)width
{
    if (!message) return 60;

    CGFloat pad = 12.0f;
    CGFloat bubbleInnerHPad = 10.0f;
    CGFloat bubbleInnerVPad = 7.0f;
    CGFloat verticalPad = 6.0f;
    CGFloat maxBubbleWidth = width - 2 * pad;
    maxBubbleWidth = MIN(maxBubbleWidth, 280.0f);
    CGFloat availTextWidth = maxBubbleWidth - 2 * bubbleInnerHPad - 8;
    if (availTextWidth < 60) availTextWidth = 60;

    UIFont *base = [UIFont systemFontOfSize:15];
    NSAttributedString *attr = [MarkdownParser attributedStringFromMarkdown:message.content
                                                                    baseFont:base
                                                                       width:availTextWidth];
    CGRect textRect = [attr boundingRectWithSize:CGSizeMake(availTextWidth, CGFLOAT_MAX)
                                         options:(NSStringDrawingUsesLineFragmentOrigin |
                                                  NSStringDrawingUsesFontLeading)
                                         context:nil];
    CGFloat bubbleHeight = textRect.size.height + 2 * bubbleInnerVPad + 6 + 4 + 8;
    return bubbleHeight + 2 * verticalPad;
}

- (void)dealloc
{
    [_bubble release];
    [_textView release];
    [_message release];
    [_renderedAttr release];
    [super dealloc];
}

@end

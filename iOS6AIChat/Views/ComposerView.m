//
//  ComposerView.m
//  iOS6AIChat
//

#import "ComposerView.h"
#import "iOS6Theme.h"
#import <QuartzCore/QuartzCore.h>

NSString *const ComposerViewSendMessageNotification = @"ComposerViewSendMessageNotification";
NSString *const ComposerViewSendMessageTextKey      = @"ComposerViewSendMessageTextKey";

@interface ComposerView ()
@property (nonatomic, retain) UIImageView *pinstripeBackground;
@property (nonatomic, retain) UIView *textFieldBackground; // rounded container
@end

@implementation ComposerView

@synthesize textView=_textView, sendButton=_sendButton, isStreaming=_isStreaming,
            delegate=_delegate, pinstripeBackground=_pinstripeBackground,
            textFieldBackground=_textFieldBackground;

- (id)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [iOS6Theme pinstripeBackground];

        _textFieldBackground = [[UIView alloc] initWithFrame:CGRectZero];
        _textFieldBackground.backgroundColor = [UIColor whiteColor];
        _textFieldBackground.layer.cornerRadius = 8.0f;  // CALayer on iOS 6 still works (3.2+)
        _textFieldBackground.layer.masksToBounds = YES;
        [self addSubview:_textFieldBackground];

        _textView = [[UITextView alloc] initWithFrame:CGRectZero];
        _textView.font = [UIFont systemFontOfSize:15];
        _textView.delegate = self;
        _textView.backgroundColor = [UIColor clearColor];
        _textView.scrollEnabled = YES;
        _textView.returnKeyType = UIReturnKeySend;
        [_textFieldBackground addSubview:_textView];

        _sendButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_sendButton setTitle:NSLocalizedString(@"Send", nil)
                      forState:UIControlStateNormal];
        [_sendButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _sendButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        [_sendButton addTarget:self
                        action:@selector(_sendTapped)
              forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_sendButton];

        _isStreaming = NO;

        // Soft top hairline to separate from the chat view above.
        UIView *hair = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, 1)];
        hair.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.18f];
        hair.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleBottomMargin);
        [self addSubview:hair];
        [hair release];
    }
    return self;
}

- (void)setIsStreaming:(BOOL)isStreaming
{
    _isStreaming = isStreaming;
    _sendButton.enabled = !isStreaming;
    [_sendButton setAlpha:isStreaming ? 0.5f : 1.0f];
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    CGFloat h = self.bounds.size.height;
    CGFloat pad = 8.0f;
    CGFloat sendW = 64.0f;
    CGFloat gap = 6.0f;

    CGRect sendRect = CGRectMake(self.bounds.size.width - sendW - pad,
                                  pad,
                                  sendW,
                                  h - 2 * pad);
    _sendButton.frame = sendRect;

    CGRect textBgRect = CGRectMake(pad, pad,
                                    self.bounds.size.width - sendW - 2 * pad - gap,
                                    h - 2 * pad);
    _textFieldBackground.frame = textBgRect;
    _textView.frame = CGRectInset(textBgRect, 4, 4);

    // Draw the glossed send button background ourselves so it matches
    // the iOS 6 skeuomorphic look.
    [self _drawSendButtonBackground];
}

- (void)_drawSendButtonBackground
{
    // Re-render the send button's background image each layout pass.
    // Because we don't want to ship PNGs, we generate the background
    // programmatically into a UIImage once per state and assign it.
    static UIImage *normalImage = nil;
    static UIImage *highlightImage = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        normalImage = [[self _renderButtonImageHighlighted:NO] retain];
        highlightImage = [[self _renderButtonImageHighlighted:YES] retain];
    });
    [_sendButton setBackgroundImage:normalImage forState:UIControlStateNormal];
    [_sendButton setBackgroundImage:highlightImage forState:UIControlStateHighlighted];
    [_sendButton setBackgroundImage:highlightImage forState:UIControlStateDisabled];
}

- (UIImage *)_renderButtonImageHighlighted:(BOOL)highlighted
{
    CGRect rect = CGRectMake(0, 0, 64, 40);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [iOS6Theme fillRoundedButtonBackgroundInRect:rect
                                          context:ctx
                                         tintColor:[iOS6Theme tintColor]
                                        highlighted:highlighted];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [img stretchableImageWithLeftCapWidth:8 topCapHeight:8];
}

- (void)_sendTapped
{
    [self _dispatchSend];
}

- (void)_dispatchSend
{
    NSString *text = [_textView.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) return;

    if ([_delegate respondsToSelector:@selector(composer:didSendText:)]) {
        [_delegate composer:self didSendText:text];
    }
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ComposerViewSendMessageNotification
                      object:self
                    userInfo:@{ ComposerViewSendMessageTextKey: text }];

    [self clearText];
}

- (void)clearText
{
    _textView.text = @"";
}

#pragma mark - UITextViewDelegate

- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range
    replacementText:(NSString *)text
{
    // Use return key as send trigger (matches iOS 6 iMessage behaviour).
    if ([text isEqualToString:@"\n"]) {
        [self _dispatchSend];
        return NO;
    }
    return YES;
}

- (void)textViewDidChange:(UITextView *)textView
{
    // Auto-grow if needed.
    NSUInteger oldHeight = self.bounds.size.height;
    CGSize target = CGSizeMake(_textView.frame.size.width, CGFLOAT_MAX);
    CGSize measured = [_textView sizeThatFits:target];
    CGFloat desired = measured.height + 16;
    if (desired < 44) desired = 44;
    if (desired > 120) desired = 120;
    if ((NSInteger)desired != (NSInteger)oldHeight) {
        CGRect f = self.frame;
        f.size.height = desired;
        self.frame = f;
        if ([_delegate respondsToSelector:@selector(composerDidChangeHeight:)]) {
            [_delegate composerDidChangeHeight:self];
        }
    }
}

- (void)dealloc
{
    [_textView release];
    [_sendButton release];
    [_pinstripeBackground release];
    [_textFieldBackground release];
    [super dealloc];
}

@end

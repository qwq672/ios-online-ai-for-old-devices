//
//  ComposerView.m
//  iOS6AIChat
//
//  Redesigned 2-row layout (better for 3.5" iPhone):
//
//      Row 1 (h≈34pt): [💡DT][🌐Web][📷+]         [➤Send]
//      Row 2 (h≈44-120pt): [    multi-line input field       ]
//
//  - Send button is now an icon (drawn CoreGraphics paper-plane), 40pt square.
//  - Three toggle/action buttons on row 1 left, 36pt each.
//  - Input field on row 2, expands the full width.
//  - The three toggles persist their state to NSUserDefaults.
//

#import "ComposerView.h"
#import "iOS6Theme.h"
#import "IconDrawing.h"
#import <QuartzCore/QuartzCore.h>

NSString *const ComposerViewSendMessageNotification = @"ComposerViewSendMessageNotification";
NSString *const ComposerViewSendMessageTextKey           = @"ComposerViewSendMessageTextKey";
NSString *const ComposerViewSendMessageDeepThinkingKey = @"ComposerViewSendMessageDeepThinkingKey";
NSString *const ComposerViewSendMessageWebSearchKey     = @"ComposerViewSendMessageWebSearchKey";

static NSString * const kUDKeyDeepThinking = @"composer.deepThinking";
static NSString * const kUDKeyWebSearch   = @"composer.webSearch";

// Row 1 height (toggles + send button).
static CGFloat const kRow1Height = 34.0f;
// Padding around the composer.
static CGFloat const kPad = 6.0f;

@interface ComposerView ()
@property (nonatomic, retain) UIView *textFieldBackground;
@end

@implementation ComposerView

@synthesize textView=_textView, sendButton=_sendButton, isStreaming=_isStreaming,
            delegate=_delegate, textFieldBackground=_textFieldBackground,
            deepThinkingButton=_deepThinkingButton, webSearchButton=_webSearchButton;

- (id)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [iOS6Theme pinstripeBackground];

        _textFieldBackground = [[UIView alloc] initWithFrame:CGRectZero];
        _textFieldBackground.backgroundColor = [UIColor whiteColor];
        _textFieldBackground.layer.cornerRadius = 6.0f;
        _textFieldBackground.layer.masksToBounds = YES;
        [self addSubview:_textFieldBackground];

        _textView = [[UITextView alloc] initWithFrame:CGRectZero];
        _textView.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        _textView.delegate = self;
        _textView.backgroundColor = [UIColor clearColor];
        _textView.scrollEnabled = YES;
        _textView.returnKeyType = UIReturnKeyDefault;  // Enter = newline (multi-line)
        _textView.enablesReturnKeyAutomatically = NO;
        if ([_textView respondsToSelector:@selector(setTextContainerInset:)]) {
            [_textView performSelector:@selector(setTextContainerInset:)
                             withObject:[NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(6, 8, 6, 8)]];
        }
        _textView.textColor = [iOS6Theme textColor];
        // Make the field become first responder on tap (text input bug fix).
        _textView.userInteractionEnabled = YES;
        _textView.editable = YES;
        [_textFieldBackground addSubview:_textView];

        // Deep Thinking toggle (leftmost) — drawn lightbulb icon.
        _deepThinkingButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_deepThinkingButton addTarget:self
                                action:@selector(_deepThinkingTapped)
                      forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_deepThinkingButton];

        // Web Search toggle — drawn globe icon.
        _webSearchButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_webSearchButton addTarget:self
                             action:@selector(_webSearchTapped)
                   forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_webSearchButton];

        // Image upload button — hidden until multipart upload is
        // implemented. Currently just an empty placeholder.
        // _imageUploadButton = [UIButton buttonWithType:UIButtonTypeCustom];
        // [self addSubview:_imageUploadButton];

        // Send button — drawn arrow icon.
        _sendButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_sendButton addTarget:self
                        action:@selector(_sendTapped)
              forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_sendButton];

        _isStreaming = NO;

        // Top hairline.
        UIView *hair = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, 1)];
        hair.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.18f];
        hair.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleBottomMargin);
        [self addSubview:hair];
        [hair release];

        [self _refreshToggleVisuals];
    }
    return self;
}

- (void)setIsStreaming:(BOOL)isStreaming
{
    _isStreaming = isStreaming;
    _sendButton.enabled = !isStreaming;
    [_sendButton setAlpha:isStreaming ? 0.4f : 1.0f];
}

#pragma mark - Toggle persistence

+ (BOOL)deepThinkingEnabled
{
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kUDKeyDeepThinking];
    return n ? [n boolValue] : YES;
}

+ (void)setDeepThinkingEnabled:(BOOL)enabled
{
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kUDKeyDeepThinking];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (BOOL)webSearchEnabled
{
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kUDKeyWebSearch];
    return n ? [n boolValue] : NO;
}

+ (void)setWebSearchEnabled:(BOOL)enabled
{
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kUDKeyWebSearch];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)_deepThinkingTapped
{
    BOOL newVal = ![[self class] deepThinkingEnabled];
    [[self class] setDeepThinkingEnabled:newVal];
    [self _refreshToggleVisuals];
}

- (void)_webSearchTapped
{
    BOOL newVal = ![[self class] webSearchEnabled];
    [[self class] setWebSearchEnabled:newVal];
    [self _refreshToggleVisuals];
}

- (void)_imageUploadTapped
{
    UIAlertView *av = [[[UIAlertView alloc]
        initWithTitle:NSLocalizedString(@"图片上传", nil)
              message:NSLocalizedString(@"功能开发中，敬请期待。", nil)
             delegate:nil
    cancelButtonTitle:NSLocalizedString(@"好", nil)
    otherButtonTitles:nil] autorelease];
    [av show];
}

- (void)_refreshToggleVisuals
{
    BOOL dt = [[self class] deepThinkingEnabled];
    BOOL ws = [[self class] webSearchEnabled];
    UIColor *onBG  = [iOS6Theme tintColor];
    UIColor *offBG = [UIColor colorWithWhite:0.5f alpha:0.35f];
    UIColor *onIconColor  = [UIColor whiteColor];
    UIColor *offIconColor = [UIColor colorWithWhite:0.15f alpha:0.85f];

    _deepThinkingButton.selected = dt;
    _webSearchButton.selected = ws;
    [self _setButton:_deepThinkingButton
                 bg:dt?onBG:offBG
            iconType:IconTypeLightbulb
           iconColor:dt?onIconColor:offIconColor];
    [self _setButton:_webSearchButton
                 bg:ws?onBG:offBG
            iconType:IconTypeGlobe
           iconColor:ws?onIconColor:offIconColor];
    // Send button — always tinted with the theme tint, white arrow on top.
    UIColor *sendIconColor = [UIColor whiteColor];
    UIImage *sendIcon = [IconDrawing imageForType:IconTypeSendArrow
                                              size:CGSizeMake(22, 22)
                                             color:sendIconColor];
    [_sendButton setImage:sendIcon forState:UIControlStateNormal];
}

- (void)_setButton:(UIButton *)btn
                 bg:(UIColor *)bg
            iconType:(IconType)iconType
           iconColor:(UIColor *)iconColor
{
    // 1. Background image (tinted/grey gradient button).
    CGRect r = CGRectMake(0, 0, 36, 28);
    UIGraphicsBeginImageContextWithOptions(r.size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [iOS6Theme fillRoundedButtonBackgroundInRect:r context:ctx tintColor:bg highlighted:NO];
    UIImage *bgImg = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    [btn setBackgroundImage:[bgImg stretchableImageWithLeftCapWidth:6 topCapHeight:6]
                 forState:UIControlStateNormal];

    // 2. Icon image (drawn by IconDrawing).
    UIImage *icon = [IconDrawing imageForType:iconType
                                         size:CGSizeMake(18, 18)
                                        color:iconColor];
    [btn setImage:icon forState:UIControlStateNormal];
    // Centre the icon (no stretching).
    [btn setImageEdgeInsets:UIEdgeInsetsMake(0, 0, 0, 0)];
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;

    // Row 1 occupies top kRow1Height pts; row 2 the rest.
    CGFloat row1H = kRow1Height;
    CGFloat row2Top = row1H + 2;

    // Toggle buttons: 36pt wide each, 4pt gap, on the left.
    CGFloat toggleW = 36.0f;
    CGFloat toggleGap = 4.0f;
    CGFloat toggleY = (row1H - 28) / 2;
    _deepThinkingButton.frame = CGRectMake(kPad, toggleY, toggleW, 28);
    CGFloat x = kPad + toggleW + toggleGap;
    _webSearchButton.frame = CGRectMake(x, toggleY, toggleW, 28);
    x += toggleW + toggleGap;

    // (Image upload button removed — not yet implemented.)

    // Send button on right of row 1.
    CGFloat sendW = 40.0f;
    _sendButton.frame = CGRectMake(w - sendW - kPad, 2, sendW, row1H - 4);

    // Row 2: input field, fills full width minus padding.
    CGFloat row2H = h - row2Top - kPad;
    CGRect textBgRect = CGRectMake(kPad, row2Top, w - 2 * kPad, row2H);
    _textFieldBackground.frame = textBgRect;
    _textView.frame = CGRectInset(textBgRect, 4, 4);

    [self _drawSendButtonBackground];
}

- (void)_drawSendButtonBackground
{
    // No caching — image picks up the current theme tint each layout pass,
    // so dark/light mode switches refresh the Send button colour too.
    UIImage *normalImage = [self _renderSendButtonBgHighlighted:NO];
    UIImage *highlightImage = [self _renderSendButtonBgHighlighted:YES];
    [_sendButton setBackgroundImage:normalImage forState:UIControlStateNormal];
    [_sendButton setBackgroundImage:highlightImage forState:UIControlStateHighlighted];
    [_sendButton setBackgroundImage:highlightImage forState:UIControlStateDisabled];
}

- (UIImage *)_renderSendButtonBgHighlighted:(BOOL)highlighted
{
    CGRect rect = CGRectMake(0, 0, 40, 32);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [iOS6Theme fillRoundedButtonBackgroundInRect:rect
                                          context:ctx
                                         tintColor:[iOS6Theme tintColor]
                                        highlighted:highlighted];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [img stretchableImageWithLeftCapWidth:6 topCapHeight:6];
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

    // Resign first responder so keyboard hides after send.
    [_textView resignFirstResponder];

    BOOL dt = [[self class] deepThinkingEnabled];
    BOOL ws = [[self class] webSearchEnabled];
    if ([_delegate respondsToSelector:@selector(composer:didSendText:deepThinking:webSearch:)]) {
        [_delegate composer:self didSendText:text deepThinking:dt webSearch:ws];
    }
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ComposerViewSendMessageNotification
                      object:self
                    userInfo:@{
                        ComposerViewSendMessageTextKey: text,
                        ComposerViewSendMessageDeepThinkingKey: @(dt),
                        ComposerViewSendMessageWebSearchKey: @(ws)
                    }];

    [self clearText];
}

- (void)clearText
{
    _textView.text = @"";
    // Recalculate height after clearing.
    [self textViewDidChange:_textView];
}

#pragma mark - UITextViewDelegate

- (void)textViewDidChange:(UITextView *)textView
{
    // Auto-grow row 2 (the input). Total composer height grows too.
    CGFloat w = self.bounds.size.width;
    CGSize target = CGSizeMake(_textView.frame.size.width, CGFLOAT_MAX);
    CGSize measured = [_textView sizeThatFits:target];
    CGFloat row2H = measured.height + 12; // 12 = top+bottom inset
    if (row2H < 44) row2H = 44;
    if (row2H > 120) row2H = 120;
    CGFloat newTotalH = kRow1Height + 2 + row2H + kPad;
    if ((NSInteger)newTotalH != (NSInteger)self.bounds.size.height) {
        CGRect f = self.frame;
        f.size.height = newTotalH;
        self.frame = f;
        [self setNeedsLayout];
        [self layoutIfNeeded];
        if ([_delegate respondsToSelector:@selector(composerDidChangeHeight:)]) {
            [_delegate composerDidChangeHeight:self];
        }
    }
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_textView release];
    [_sendButton release];
    [_deepThinkingButton release];
    [_webSearchButton release];
    [_textFieldBackground release];
    [super dealloc];
}

@end

//
//  ComposerView.m
//  iOS6AIChat
//
//  Composer bar with:
//     - Glossed send button (right)
//     - Deep Thinking toggle button (left of input)
//     - Web Search toggle button (left of Deep Thinking)
//  Toggles persist to NSUserDefaults so they survive app restarts.
//

#import "ComposerView.h"
#import "iOS6Theme.h"
#import <QuartzCore/QuartzCore.h>

NSString *const ComposerViewSendMessageNotification = @"ComposerViewSendMessageNotification";
NSString *const ComposerViewSendMessageTextKey           = @"ComposerViewSendMessageTextKey";
NSString *const ComposerViewSendMessageDeepThinkingKey = @"ComposerViewSendMessageDeepThinkingKey";
NSString *const ComposerViewSendMessageWebSearchKey     = @"ComposerViewSendMessageWebSearchKey";

static NSString * const kUDKeyDeepThinking = @"composer.deepThinking";
static NSString * const kUDKeyWebSearch   = @"composer.webSearch";

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
        _textFieldBackground.layer.cornerRadius = 8.0f;
        _textFieldBackground.layer.masksToBounds = YES;
        [self addSubview:_textFieldBackground];

        _textView = [[UITextView alloc] initWithFrame:CGRectZero];
        _textView.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        _textView.delegate = self;
        _textView.backgroundColor = [UIColor clearColor];
        _textView.scrollEnabled = YES;
        _textView.returnKeyType = UIReturnKeySend;
        if ([_textView respondsToSelector:@selector(setTextContainerInset:)]) {
            [_textView performSelector:@selector(setTextContainerInset:)
                             withObject:[NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(7, 10, 7, 10)]];
        }
        _textView.textColor = [iOS6Theme textColor];
        [_textFieldBackground addSubview:_textView];

        // Deep Thinking toggle button (left of input).
        _deepThinkingButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_deepThinkingButton setTitle:@"DT" forState:UIControlStateNormal];
        _deepThinkingButton.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        _deepThinkingButton.titleLabel.numberOfLines = 2;
        _deepThinkingButton.titleLabel.textAlignment = NSTextAlignmentCenter;
        [_deepThinkingButton addTarget:self
                                action:@selector(_deepThinkingTapped)
                      forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_deepThinkingButton];

        // Web Search toggle button (leftmost).
        _webSearchButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_webSearchButton setTitle:@"Web" forState:UIControlStateNormal];
        _webSearchButton.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        _webSearchButton.titleLabel.numberOfLines = 2;
        _webSearchButton.titleLabel.textAlignment = NSTextAlignmentCenter;
        [_webSearchButton addTarget:self
                             action:@selector(_webSearchTapped)
                   forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_webSearchButton];

        _sendButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_sendButton setTitle:NSLocalizedString(@"Send", nil)
                      forState:UIControlStateNormal];
        [_sendButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _sendButton.titleLabel.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        [_sendButton addTarget:self
                        action:@selector(_sendTapped)
              forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_sendButton];

        _isStreaming = NO;

        // Soft top hairline.
        UIView *hair = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, 1)];
        hair.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.18f];
        hair.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleBottomMargin);
        [self addSubview:hair];
        [hair release];

        // Apply initial toggle visuals.
        [self _refreshToggleVisuals];
    }
    return self;
}

- (void)setIsStreaming:(BOOL)isStreaming
{
    _isStreaming = isStreaming;
    _sendButton.enabled = !isStreaming;
    [_sendButton setAlpha:isStreaming ? 0.5f : 1.0f];
}

#pragma mark - Toggle persistence

+ (BOOL)deepThinkingEnabled
{
    // Default ON per user request (deep thinking by default for richer answers).
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
    // Default OFF (user must opt-in; needs API key).
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

- (void)_refreshToggleVisuals
{
    BOOL dt = [[self class] deepThinkingEnabled];
    BOOL ws = [[self class] webSearchEnabled];
    // Lit-up state: tinted background + white text.
    // Dim state: translucent grey background + grey text.
    UIColor *onBG  = [iOS6Theme tintColor];
    UIColor *offBG = [UIColor colorWithWhite:0.5f alpha:0.4f];
    UIColor *onText  = [UIColor whiteColor];
    UIColor *offText = [UIColor colorWithWhite:0.2f alpha:0.8f];

    _deepThinkingButton.selected = dt;
    _webSearchButton.selected = ws;
    // Use the backgroundImage trick to colour them.
    [self _setButton:_deepThinkingButton bg:dt?onBG:offBG textColor:dt?onText:offText];
    [self _setButton:_webSearchButton   bg:ws?onBG:offBG textColor:ws?onText:offText];
}

- (void)_setButton:(UIButton *)btn bg:(UIColor *)bg textColor:(UIColor *)tc
{
    CGRect r = CGRectMake(0, 0, 44, 28);
    UIGraphicsBeginImageContextWithOptions(r.size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [iOS6Theme fillRoundedButtonBackgroundInRect:r context:ctx tintColor:bg highlighted:NO];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    [btn setBackgroundImage:[img stretchableImageWithLeftCapWidth:8 topCapHeight:8]
                 forState:UIControlStateNormal];
    [btn setTitleColor:tc forState:UIControlStateNormal];
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    CGFloat h = self.bounds.size.height;
    CGFloat pad = 8.0f;
    CGFloat sendW = 64.0f;
    CGFloat gap = 6.0f;
    CGFloat toggleW = 44.0f;
    CGFloat toggleGap = 4.0f;

    // Right side: send button.
    CGRect sendRect = CGRectMake(self.bounds.size.width - sendW - pad,
                                  pad, sendW, h - 2 * pad);
    _sendButton.frame = sendRect;

    // Left side: web search toggle.
    CGRect wsRect = CGRectMake(pad, pad, toggleW, h - 2 * pad);
    _webSearchButton.frame = wsRect;

    // Next: deep thinking toggle.
    CGFloat dtX = pad + toggleW + toggleGap;
    CGRect dtRect = CGRectMake(dtX, pad, toggleW, h - 2 * pad);
    _deepThinkingButton.frame = dtRect;

    // Middle: text field background fills the gap.
    CGFloat textX = dtX + toggleW + toggleGap;
    CGFloat textW = self.bounds.size.width - sendW - 2 * pad - gap
                     - 2 * (toggleW + toggleGap);
    CGRect textBgRect = CGRectMake(textX, pad, textW, h - 2 * pad);
    _textFieldBackground.frame = textBgRect;
    _textView.frame = CGRectInset(textBgRect, 4, 4);

    [self _drawSendButtonBackground];
}

- (void)_drawSendButtonBackground
{
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
}

#pragma mark - UITextViewDelegate

- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range
    replacementText:(NSString *)text
{
    if ([text isEqualToString:@"\n"]) {
        [self _dispatchSend];
        return NO;
    }
    return YES;
}

- (void)textViewDidChange:(UITextView *)textView
{
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
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_textView release];
    [_sendButton release];
    [_deepThinkingButton release];
    [_webSearchButton release];
    [_textFieldBackground release];
    [super dealloc];
}

@end

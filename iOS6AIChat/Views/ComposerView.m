//
//  ComposerView.m
//  iOS6AIChat
//
//  SIMPLE single-row composer — one row, no nesting bugs.
//  Layout: [💡] [🌐] [input field] [➤]
//  All buttons use UIButtonTypeRoundedRect (iOS 6 native look).
//  Input field has white bg + rounded border (visible, tappable).
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

@interface ComposerView ()
@end

@implementation ComposerView

@synthesize textView=_textView, sendButton=_sendButton, isStreaming=_isStreaming,
            delegate=_delegate, deepThinkingButton=_deepThinkingButton,
            webSearchButton=_webSearchButton;

- (id)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [iOS6Theme pinstripeBackground];
        self.clipsToBounds = YES;

        // --- Input text view (the main input field) ---
        // Created FIRST so it's at the bottom of the z-order (buttons on top
        // won't block its touch events since they're side-by-side, not overlapping).
        _textView = [[UITextView alloc] initWithFrame:CGRectZero];
        _textView.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        _textView.delegate = self;
        _textView.backgroundColor = [UIColor whiteColor];
        _textView.scrollEnabled = YES;
        _textView.editable = YES;
        _textView.userInteractionEnabled = YES;
        // Add a "Done" button above the keyboard to dismiss it.
        UIToolbar *kbdToolbar = [[[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)] autorelease];
        kbdToolbar.barStyle = UIBarStyleDefault;
        UIBarButtonItem *flex = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil] autorelease];
        UIBarButtonItem *done = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(_keyboardDone)] autorelease];
        kbdToolbar.items = [NSArray arrayWithObjects:flex, done, nil];
        _textView.inputAccessoryView = kbdToolbar;
        _textView.returnKeyType = UIReturnKeyDefault;
        _textView.textColor = [iOS6Theme textColor];
        _textView.layer.cornerRadius = 8.0f;
        _textView.layer.borderWidth = 1.0f;
        _textView.layer.borderColor = [[UIColor lightGrayColor] CGColor];
        // Text container inset for padding (iOS 7+ guarded).
        if ([_textView respondsToSelector:@selector(setTextContainerInset:)]) {
            [_textView performSelector:@selector(setTextContainerInset:)
                             withObject:[NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(6, 8, 6, 8)]];
        }
        [self addSubview:_textView];

        // --- Deep Thinking toggle (iOS 6 rounded rect button) ---
        _deepThinkingButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        [_deepThinkingButton addTarget:self action:@selector(_deepThinkingTapped)
                      forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_deepThinkingButton];

        // --- Web Search toggle (iOS 6 rounded rect button) ---
        _webSearchButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        [_webSearchButton addTarget:self action:@selector(_webSearchTapped)
                    forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_webSearchButton];

        // --- Send button (iOS 6 rounded rect with arrow icon) ---
        _sendButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        [_sendButton addTarget:self action:@selector(_sendTapped)
              forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_sendButton];

        _isStreaming = NO;

        // Top hairline.
        UIView *hair = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, 1)] autorelease];
        hair.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.2f];
        hair.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self addSubview:hair];

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

#pragma mark - Layout (THE CRITICAL PART)

- (void)layoutSubviews
{
    [super layoutSubviews];

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat pad = 6.0f;
    CGFloat gap = 4.0f;
    CGFloat btnW = 36.0f;
    CGFloat sendW = 44.0f;
    CGFloat btnH = 30.0f;
    CGFloat btnY = (h - btnH) / 2.0f;

    // Left: DT button
    _deepThinkingButton.frame = CGRectMake(pad, btnY, btnW, btnH);

    // Next: Web button
    CGFloat x = pad + btnW + gap;
    _webSearchButton.frame = CGRectMake(x, btnY, btnW, btnH);
    x += btnW + gap;

    // Right: Send button
    CGFloat sendX = w - sendW - pad;
    _sendButton.frame = CGRectMake(sendX, btnY, sendW, btnH);

    // Middle: text view fills the gap
    CGFloat tvX = x + gap;
    CGFloat tvW = sendX - gap - tvX;
    if (tvW < 60) tvW = 60; // minimum width safety
    CGFloat tvH = h - 2 * pad;
    if (tvH < 30) tvH = 30;
    _textView.frame = CGRectMake(tvX, pad, tvW, tvH);
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
    BOOL v = ![[self class] deepThinkingEnabled];
    [[self class] setDeepThinkingEnabled:v];
    [self _refreshToggleVisuals];
}

- (void)_webSearchTapped
{
    BOOL v = ![[self class] webSearchEnabled];
    [[self class] setWebSearchEnabled:v];
    [self _refreshToggleVisuals];
}

- (void)_refreshToggleVisuals
{
    BOOL dt = [[self class] deepThinkingEnabled];
    BOOL ws = [[self class] webSearchEnabled];

    // Use icon image on the buttons.
    UIImage *bulb = [IconDrawing imageForType:IconTypeLightbulb size:CGSizeMake(16, 16)
                                       color:dt ? [iOS6Theme tintColor] : [UIColor grayColor]];
    UIImage *globe = [IconDrawing imageForType:IconTypeGlobe size:CGSizeMake(16, 16)
                                         color:ws ? [iOS6Theme tintColor] : [UIColor grayColor]];
    UIImage *arrow = [IconDrawing imageForType:IconTypeSendArrow size:CGSizeMake(18, 18)
                                          color:[iOS6Theme tintColor]];

    [_deepThinkingButton setImage:bulb forState:UIControlStateNormal];
    [_webSearchButton setImage:globe forState:UIControlStateNormal];
    [_sendButton setImage:arrow forState:UIControlStateNormal];

    // Title to empty (image only).
    [_deepThinkingButton setTitle:@"" forState:UIControlStateNormal];
    [_webSearchButton setTitle:@"" forState:UIControlStateNormal];
    [_sendButton setTitle:@"" forState:UIControlStateNormal];

    // Highlight state when ON.
    if (dt) {
        [_deepThinkingButton setSelected:YES];
    } else {
        [_deepThinkingButton setSelected:NO];
    }
    if (ws) {
        [_webSearchButton setSelected:YES];
    } else {
        [_webSearchButton setSelected:NO];
    }
}

- (void)_keyboardDone
{
    [_textView resignFirstResponder];
}

#pragma mark - Send

- (void)_sendTapped
{
    NSString *text = [_textView.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) return;
    [_textView resignFirstResponder];

    BOOL dt = [[self class] deepThinkingEnabled];
    BOOL ws = [[self class] webSearchEnabled];
    if ([_delegate respondsToSelector:@selector(composer:didSendText:deepThinking:webSearch:)]) {
        [_delegate composer:self didSendText:text deepThinking:dt webSearch:ws];
    }
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ComposerViewSendMessageNotification object:self
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
    [self textViewDidChange:_textView];
}

#pragma mark - UITextViewDelegate

- (void)textViewDidChange:(UITextView *)textView
{
    // Auto-grow: measure text, resize composer if needed.
    CGSize measured = [_textView sizeThatFits:CGSizeMake(_textView.frame.size.width, CGFLOAT_MAX)];
    CGFloat needed = measured.height + 12; // 12 = top+bottom padding
    if (needed < 30) needed = 30;
    if (needed > 100) needed = 100;
    CGFloat newH = needed + 12; // 12 = top+bottom margin in composer
    if ((NSInteger)newH != (NSInteger)self.bounds.size.height) {
        CGRect f = self.frame;
        f.size.height = newH;
        self.frame = f;
        [self setNeedsLayout];
        [self layoutIfNeeded];
        if ([_delegate respondsToSelector:@selector(composerDidChangeHeight:)]) {
            [_delegate composerDidChangeHeight:self];
        }
    }
}

- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range
    replacementText:(NSString *)text
{
    // Don't intercept newline — let it insert a newline (multi-line input).
    return YES;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_textView release];
    [_sendButton release];
    [_deepThinkingButton release];
    [_webSearchButton release];
    [super dealloc];
}

@end

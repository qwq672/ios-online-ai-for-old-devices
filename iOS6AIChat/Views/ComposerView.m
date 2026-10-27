//
//  ComposerView.m
//  iOS6AIChat
//
//  v261025-10: simplified layout — only [+] [─── input ───] [➤Send].
//  See the .h file for the layout rationale and the menu-based toggle UX.
//

#import "ComposerView.h"
#import "iOS6Theme.h"
#import "IconDrawing.h"
#import "NSDataBase64.h"
#import <QuartzCore/QuartzCore.h>

NSString *const ComposerViewSendMessageNotification = @"ComposerViewSendMessageNotification";
NSString *const ComposerViewSendMessageTextKey           = @"ComposerViewSendMessageTextKey";
NSString *const ComposerViewSendMessageDeepThinkingKey = @"ComposerViewSendMessageDeepThinkingKey";
NSString *const ComposerViewSendMessageWebSearchKey     = @"ComposerViewSendMessageWebSearchKey";
NSString *const ComposerViewSendMessageImagesKey         = @"ComposerViewSendMessageImagesKey";

static NSString * const kUDKeyDeepThinking = @"composer.deepThinking";
static NSString * const kUDKeyWebSearch   = @"composer.webSearch";
static NSString * const kUDKeyImageGen    = @"composer.imageGen";   // v261025-8

@interface ComposerView () {
    NSMutableArray *_pendingImages;
    UIColor *_fieldBorderUIColor;
    // v261025-10: image-gen-mode background tint (light blue). Retained
    // for the same reason as the border color ivar — bare UIColor* from
    // a class method is autoreleased, and we need to keep the CGColor
    // alive across the runloop.
    UIColor *_imageGenBgUIColor;
}
@end

@implementation ComposerView

@synthesize textView=_textView, sendButton=_sendButton, isStreaming=_isStreaming,
            delegate=_delegate, plusButton=_plusButton, plusBadge=_plusBadge,
            fieldBorderUIColor=_fieldBorderUIColor;

- (id)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.clipsToBounds = YES;

        _pendingImages = [[NSMutableArray alloc] init];

        // Text view (main input) — inset glass field, darker than its bar.
        _textView = [[UITextView alloc] initWithFrame:CGRectZero];
        _textView.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        _textView.delegate = self;
        _textView.backgroundColor = [iOS6Theme composerFieldBackgroundColor];
        _textView.editable = YES;
        _textView.userInteractionEnabled = YES;
        _textView.returnKeyType = UIReturnKeyDefault;
        _textView.textColor = [iOS6Theme inputFieldTextColor];
        _textView.layer.cornerRadius = 8.0f;
        _textView.layer.borderWidth = 1.0f;
        _fieldBorderUIColor = [[iOS6Theme composerFieldBorderColor] retain];
        _textView.layer.borderColor = [_fieldBorderUIColor CGColor];
        if ([_textView respondsToSelector:@selector(setTextContainerInset:)]) {
            [_textView performSelector:@selector(setTextContainerInset:)
                             withObject:[NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(6, 8, 6, 8)]];
        }
        // Done button on keyboard.
        UIToolbar *kbdToolbar = [[[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)] autorelease];
        kbdToolbar.barStyle = [iOS6Theme isDarkMode] ? UIBarStyleBlack : UIBarStyleDefault;
        UIBarButtonItem *flex = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil] autorelease];
        UIBarButtonItem *done = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(_keyboardDone)] autorelease];
        kbdToolbar.items = [NSArray arrayWithObjects:flex, done, nil];
        _textView.inputAccessoryView = kbdToolbar;
        // Dark-mode keyboard appearance.
        if ([iOS6Theme isDarkMode] && [_textView respondsToSelector:@selector(setKeyboardAppearance:)]) {
            [_textView setKeyboardAppearance:UIKeyboardAppearanceAlert];
        }
        [self addSubview:_textView];

        // v261025-10: plus button (replaces 4 old toggle buttons).
        // buttonWithType: returns autorelease(+0); retain per ivar — the
        // v261025-7 root-cause writeup (over-release crash) applies here.
        _plusButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
        _plusButton.layer.cornerRadius = 5.0f;
        _plusButton.layer.masksToBounds = YES;
        [_plusButton addTarget:self action:@selector(_plusTapped)
                  forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_plusButton];

        // v261025-10: badge — small red circle on top-right of plus button
        // showing the count of active toggles. Hidden when count = 0.
        _plusBadge = [[UILabel alloc] initWithFrame:CGRectZero];
        _plusBadge.font = [UIFont boldSystemFontOfSize:10];
        _plusBadge.textColor = [UIColor whiteColor];
        _plusBadge.backgroundColor = [UIColor redColor];
        _plusBadge.textAlignment = NSTextAlignmentCenter;
        _plusBadge.layer.cornerRadius = 8.0f;
        _plusBadge.layer.masksToBounds = YES;
        _plusBadge.hidden = YES;
        [self addSubview:_plusBadge];

        // Send button.
        _sendButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
        _sendButton.layer.cornerRadius = 5.0f;
        _sendButton.layer.masksToBounds = YES;
        [_sendButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [_sendButton addTarget:self action:@selector(_sendTapped)
                forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_sendButton];

        _isStreaming = NO;

        // v261025-10: image-gen background tint color (light blue).
        // Retained for the same reason as the border ivar.
        _imageGenBgUIColor = [[UIColor colorWithRed:0.85f green:0.92f
                                               blue:1.0f alpha:1.0f] retain];

        [self refreshPlusButtonVisuals];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_themeChanged)
                                                     name:@"iOS6ThemeDidChangeNotification"
                                                   object:nil];
    }
    return self;
}

// iOS 6 metal input-toolbar: 1px top highlight → 1px bevel line → vertical
// gradient body → 1px bottom shadow. (Identical to v261025-8.)
- (void)drawRect:(CGRect)rect
{
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGFloat scale = [[UIScreen mainScreen] scale];
    if (scale < 1) scale = 1;
    CGFloat lineH = 1.0f / scale;
    CGFloat w = rect.size.width, h = rect.size.height;

    [iOS6Theme drawLinearGradientInRect:rect
                                context:ctx
                               topColor:[iOS6Theme composerBarTopColor]
                            bottomColor:[iOS6Theme composerBarBottomColor]];

    CGContextSetFillColorWithColor(ctx,
        [UIColor colorWithWhite:1.0f alpha:([iOS6Theme isDarkMode] ? 0.55f : 0.85f)].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, lineH));
    CGContextSetFillColorWithColor(ctx,
        [UIColor colorWithWhite:0.0f alpha:([iOS6Theme isDarkMode] ? 0.8f : 0.12f)].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, lineH, w, lineH));

    CGContextSetFillColorWithColor(ctx,
        [UIColor colorWithWhite:0.0f alpha:([iOS6Theme isDarkMode] ? 0.9f : 0.3f)].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, h - lineH, w, lineH));
}

- (void)_themeChanged
{
    [self setNeedsDisplay];
    _textView.backgroundColor = [iOS6Theme composerFieldBackgroundColor];
    _textView.textColor = [iOS6Theme inputFieldTextColor];
    [_fieldBorderUIColor release];
    _fieldBorderUIColor = [[iOS6Theme composerFieldBorderColor] retain];
    _textView.layer.borderColor = [_fieldBorderUIColor CGColor];
    if ([iOS6Theme isDarkMode] && [_textView respondsToSelector:@selector(setKeyboardAppearance:)]) {
        [_textView setKeyboardAppearance:UIKeyboardAppearanceAlert];
    } else if ([_textView respondsToSelector:@selector(setKeyboardAppearance:)]) {
        [_textView setKeyboardAppearance:UIKeyboardAppearanceDefault];
    }
    [self refreshPlusButtonVisuals];
    [self setNeedsLayout];
}

- (void)setIsStreaming:(BOOL)isStreaming
{
    _isStreaming = isStreaming;
    _sendButton.enabled = YES;
    [_sendButton setAlpha:1.0f];
    if (isStreaming) {
        UIImage *stopIcon = [self _stopIconImage];
        [_sendButton setImage:stopIcon forState:UIControlStateNormal];
        UIImage *stopBg = [iOS6Theme glassButtonImageOfSize:CGSizeMake(40, 30)
                                                    accent:NO];
        [_sendButton setBackgroundImage:stopBg forState:UIControlStateNormal];
        [_sendButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    } else {
        UIImage *arrow = [IconDrawing imageForType:IconTypeSendArrow
                                              size:CGSizeMake(18, 18)
                                              color:[UIColor whiteColor]];
        [_sendButton setImage:arrow forState:UIControlStateNormal];
        UIImage *greenS = [iOS6Theme greenGlassButtonImageOfSize:CGSizeMake(40, 30)];
        if (greenS) {
            [_sendButton setBackgroundImage:greenS forState:UIControlStateNormal];
        } else {
            UIImage *accentS = [iOS6Theme glassButtonImageOfSize:CGSizeMake(40, 30)
                                                            accent:YES];
            [_sendButton setBackgroundImage:accentS forState:UIControlStateNormal];
        }
        [_sendButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    }
}

// v261025-3: draw an inline stop icon. Cached as a static (identical to
// the v261025-8 implementation).
- (UIImage *)_stopIconImage
{
    static UIImage *cachedStopIcon = nil;
    if (cachedStopIcon) return cachedStopIcon;
    CGFloat sz = 14.0f;
    CGFloat scale = [[UIScreen mainScreen] scale];
    if (scale < 1) scale = 1;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(sz, sz), NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
        CGFloat r = 2.0f;
        CGContextBeginPath(ctx);
        CGContextMoveToPoint(ctx, r, 0);
        CGContextAddArcToPoint(ctx, sz, 0, sz, r, r);
        CGContextAddArcToPoint(ctx, sz, sz, sz - r, sz, r);
        CGContextAddArcToPoint(ctx, 0, sz, 0, sz - r, r);
        CGContextAddArcToPoint(ctx, 0, 0, r, 0, r);
        CGContextClosePath(ctx);
        CGContextFillPath(ctx);
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (img) {
        cachedStopIcon = [img retain];
        return cachedStopIcon;
    }
    return nil;
}

#pragma mark - Layout

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat pad = 6.0f, gap = 4.0f;
    CGFloat btnW = 34.0f, sendW = 40.0f, btnH = 30.0f;
    CGFloat btnY = (h - btnH) / 2.0f;
    CGFloat x = pad;

    // Plus button (leftmost).
    _plusButton.frame = CGRectMake(x, btnY, btnW, btnH);
    // Badge sits at the top-right corner of the plus button.
    _plusBadge.frame = CGRectMake(x + btnW - 10, btnY - 4, 16, 16);
    x += btnW + gap;

    // Send button (right).
    CGFloat sendX = w - sendW - pad;
    _sendButton.frame = CGRectMake(sendX, btnY, sendW, btnH);

    // Text view (middle, fills remaining space).
    // v261025-10: with only 2 buttons ([+] and [▶]) the text view now
    // spans ~230pt on a 320pt screen — over 65% wider than the old 116pt.
    CGFloat tvX = x + gap;
    CGFloat tvW = sendX - gap - tvX;
    if (tvW < 60) tvW = 60;
    CGFloat tvH = h - 2 * pad;
    if (tvH < 30) tvH = 30;
    _textView.frame = CGRectMake(tvX, pad, tvW, tvH);
}

#pragma mark - Toggles (class accessors — same keys as v261025-8)

+ (BOOL)deepThinkingEnabled { NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kUDKeyDeepThinking]; return n ? [n boolValue] : YES; }
+ (void)setDeepThinkingEnabled:(BOOL)e { [[NSUserDefaults standardUserDefaults] setBool:e forKey:kUDKeyDeepThinking]; [[NSUserDefaults standardUserDefaults] synchronize]; }
+ (BOOL)webSearchEnabled { NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kUDKeyWebSearch]; return n ? [n boolValue] : NO; }
+ (void)setWebSearchEnabled:(BOOL)e { [[NSUserDefaults standardUserDefaults] setBool:e forKey:kUDKeyWebSearch]; [[NSUserDefaults standardUserDefaults] synchronize]; }
+ (BOOL)imageGenEnabled { NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kUDKeyImageGen]; return n ? [n boolValue] : NO; }
+ (void)setImageGenEnabled:(BOOL)e { [[NSUserDefaults standardUserDefaults] setBool:e forKey:kUDKeyImageGen]; [[NSUserDefaults standardUserDefaults] synchronize]; }

// v261025-10: how many toggles are currently ON.
+ (NSInteger)activeToggleCount
{
    NSInteger n = 0;
    if ([self deepThinkingEnabled]) n++;
    if ([self webSearchEnabled]) n++;
    if ([self imageGenEnabled]) n++;
    return n;
}

- (void)_keyboardDone { [_textView resignFirstResponder]; }

// v261025-10: refresh the plus button badge + the input field's image-gen
// blue tint. Called from initWithFrame:, _themeChanged, and after any
// toggle change fired via ComposerPlusMenuView.
- (void)refreshPlusButtonVisuals
{
    NSInteger count = [[self class] activeToggleCount];
    if (count > 0) {
        _plusBadge.hidden = NO;
        _plusBadge.text = [NSString stringWithFormat:@"%d", (int)count];
    } else {
        _plusBadge.hidden = YES;
    }
    // Plus button background: glassy neutral. Icon: black "+" on light,
    // white "+" on dark.
    CGSize plusSize = CGSizeMake(34, 30);
    UIImage *plusBg = [iOS6Theme glassButtonImageOfSize:plusSize accent:NO];
    [_plusButton setBackgroundImage:plusBg forState:UIControlStateNormal];
    // Draw a "+" glyph directly (avoids Helvetica glyph gaps at small sizes).
    UIImage *plusIcon = [self _plusIconImage];
    [_plusButton setImage:plusIcon forState:UIControlStateNormal];

    // v261025-10: when image-gen is ON, the text-view background turns
    // light blue + placeholder reads "输入生图提示". When OFF, restore.
    BOOL ig = [[self class] imageGenEnabled];
    if (ig) {
        _textView.backgroundColor = _imageGenBgUIColor;
        // Border to a slightly more saturated blue to match.
        _textView.layer.borderColor = [[UIColor colorWithRed:0.4f green:0.6f
                                                        blue:0.95f alpha:1.0f] CGColor];
        // (placeholder set via textViewDidChange when empty)
        if (_textView.text.length == 0) {
            _textView.text = @"";
            // iOS 6 UITextView doesn't have placeholder natively; we draw a
            // fake one by setting text to a grayed-out hint and clearing it
            // on first edit. Simpler: just leave it empty; the blue
            // background already signals image-gen mode.
        }
    } else {
        _textView.backgroundColor = [iOS6Theme composerFieldBackgroundColor];
        _textView.layer.borderColor = [_fieldBorderUIColor CGColor];
    }
}

// v261025-10: draw a "+" icon inline (cached). The glyph uses Helvetica
// "+"; if Helvetica is missing the glyph at the size we want, we fall
// back to two rectangles (vertical + horizontal) drawn with CG.
- (UIImage *)_plusIconImage
{
    static UIImage *cachedPlus = nil;
    if (cachedPlus) return cachedPlus;
    CGFloat sz = 16.0f;
    CGFloat scale = [[UIScreen mainScreen] scale];
    if (scale < 1) scale = 1;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(sz, sz), NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        CGContextSetFillColorWithColor(ctx, [iOS6Theme secondaryTextColor].CGColor);
        CGFloat barW = 2.0f;
        CGFloat barL = 4.0f;
        // Horizontal bar.
        CGContextFillRect(ctx, CGRectMake(barL, (sz - barW) / 2.0f, sz - 2 * barL, barW));
        // Vertical bar.
        CGContextFillRect(ctx, CGRectMake((sz - barW) / 2.0f, barL, barW, sz - 2 * barL));
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (img) {
        cachedPlus = [img retain];
        return cachedPlus;
    }
    return nil;
}

// v261025-10: the plus button was tapped — let the delegate show the menu.
- (void)_plusTapped
{
    if ([_delegate respondsToSelector:@selector(composerDidTapPlusButton:)]) {
        [_delegate composerDidTapPlusButton:self];
    }
}

#pragma mark - Image picker (action delegated to ChatViewController)

// v261025-10: image-upload now happens via the plus menu's action row,
// but the actual UIImagePickerController is still presented by the
// ComposerView itself (it owns the _pendingImages array + the picker
// delegate). Exposed as a public-ish method so ChatViewController can
// trigger it from the plus-menu callback.
- (void)presentImagePickerFromViewController:(UIViewController *)vc
{
    UIImagePickerController *picker = [[[UIImagePickerController alloc] init] autorelease];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.allowsEditing = NO;
    picker.delegate = self;
    if (vc) [vc presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info
{
    UIImage *image = [info objectForKey:UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!image || image.size.width <= 0 || image.size.height <= 0) return;

    NSInteger maxDim = [[NSUserDefaults standardUserDefaults] integerForKey:@"imageMaxDim"];
    if (maxDim > 0) {
        CGFloat w = image.size.width, h = image.size.height;
        if (w > maxDim || h > maxDim) {
            CGFloat scale = (CGFloat)maxDim / MAX(w, h);
            w = (NSInteger)(w * scale);
            h = (NSInteger)(h * scale);
            if (w < 1) w = 1;
            if (h < 1) h = 1;
            UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 0.0);
            [image drawInRect:CGRectMake(0, 0, w, h)];
            UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            if (resized) image = resized;
        }
    }
    UIImage *capturedImage = [image retain];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSData *jpegData = UIImageJPEGRepresentation(capturedImage, 0.7);
            NSString *base64 = jpegData ? [jpegData base64String] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                [capturedImage release];
                if (!base64 || base64.length == 0) return;
                NSString *dataUrl = [NSString stringWithFormat:@"data:image/jpeg;base64,%@", base64];
                [_pendingImages addObject:dataUrl];
                // Refresh badge count on the plus button (image-upload
                // is one of the things the badge tracks; we now show
                // pending image count as a temporary override).
                NSInteger imgCount = (NSInteger)[_pendingImages count];
                if (imgCount > 0) {
                    _plusBadge.hidden = NO;
                    _plusBadge.text = [NSString stringWithFormat:@"%d", (int)imgCount];
                    _plusBadge.backgroundColor = [UIColor redColor];
                }
            });
        }
    });
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Send

- (void)_sendTapped
{
    if (_isStreaming) {
        if ([_delegate respondsToSelector:@selector(composerDidTapStop:)]) {
            [_delegate composerDidTapStop:self];
        }
        return;
    }

    NSString *text = [_textView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0 && [_pendingImages count] == 0) return;
    [_textView resignFirstResponder];

    BOOL dt = [[self class] deepThinkingEnabled];
    BOOL ws = [[self class] webSearchEnabled];
    BOOL ig = [[self class] imageGenEnabled];
    NSArray *imgs = [_pendingImages count] > 0 ? [NSArray arrayWithArray:_pendingImages] : nil;

    if ([_delegate respondsToSelector:@selector(composer:didSendText:images:deepThinking:webSearch:imageGen:)]) {
        [_delegate composer:self didSendText:text images:imgs deepThinking:dt webSearch:ws imageGen:ig];
    }

    [self clearText];
}

- (void)clearText
{
    _textView.text = @"";
    [_pendingImages removeAllObjects];
    [self refreshPlusButtonVisuals];
    [self textViewDidChange:_textView];
}

#pragma mark - UITextViewDelegate

- (void)textViewDidChange:(UITextView *)textView
{
    CGSize measured = [_textView sizeThatFits:CGSizeMake(_textView.frame.size.width, CGFLOAT_MAX)];
    CGFloat needed = measured.height + 12;
    if (needed < 30) needed = 30;
    if (needed > 100) needed = 100;
    CGFloat newH = needed + 12;
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

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_textView release];
    [_sendButton release];
    [_plusButton release];
    [_plusBadge release];
    [_pendingImages release];
    [_fieldBorderUIColor release];
    _fieldBorderUIColor = nil;
    [_imageGenBgUIColor release];
    _imageGenBgUIColor = nil;
    [super dealloc];
}

@end

//
//  ComposerView.m
//  iOS6AIChat
//
//  Single-row composer: [📷] [💡] [🌐] [input] [➤]
//  Image button picks from photo library, compresses, base64 encodes.
//  Badge shows pending image count.
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

@interface ComposerView () {
    NSMutableArray *_pendingImages;
}
@end

@implementation ComposerView

@synthesize textView=_textView, sendButton=_sendButton, isStreaming=_isStreaming,
            delegate=_delegate, deepThinkingButton=_deepThinkingButton,
            webSearchButton=_webSearchButton, imageButton=_imageButton,
            imageBadge=_imageBadge;

- (id)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [iOS6Theme pinstripeBackground];
        self.clipsToBounds = YES;

        // Pending images array (base64 data URLs).
        _pendingImages = [[NSMutableArray alloc] init];

        // Text view (main input).
        _textView = [[UITextView alloc] initWithFrame:CGRectZero];
        _textView.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        _textView.delegate = self;
        _textView.backgroundColor = [UIColor whiteColor];
        _textView.editable = YES;
        _textView.userInteractionEnabled = YES;
        _textView.returnKeyType = UIReturnKeyDefault;
        _textView.textColor = [iOS6Theme textColor];
        _textView.layer.cornerRadius = 8.0f;
        _textView.layer.borderWidth = 1.0f;
        _textView.layer.borderColor = [[UIColor lightGrayColor] CGColor];
        if ([_textView respondsToSelector:@selector(setTextContainerInset:)]) {
            [_textView performSelector:@selector(setTextContainerInset:)
                             withObject:[NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(6, 8, 6, 8)]];
        }
        // Done button on keyboard.
        UIToolbar *kbdToolbar = [[[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)] autorelease];
        kbdToolbar.barStyle = UIBarStyleDefault;
        UIBarButtonItem *flex = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil] autorelease];
        UIBarButtonItem *done = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(_keyboardDone)] autorelease];
        kbdToolbar.items = [NSArray arrayWithObjects:flex, done, nil];
        _textView.inputAccessoryView = kbdToolbar;
        [self addSubview:_textView];

        // Image button.
        _imageButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        [_imageButton addTarget:self action:@selector(_imageButtonTapped)
                forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_imageButton];

        // Image badge (shows count).
        _imageBadge = [[UILabel alloc] initWithFrame:CGRectZero];
        _imageBadge.font = [UIFont boldSystemFontOfSize:10];
        _imageBadge.textColor = [UIColor whiteColor];
        _imageBadge.backgroundColor = [UIColor redColor];
        _imageBadge.textAlignment = NSTextAlignmentCenter;
        _imageBadge.layer.cornerRadius = 8.0f;
        _imageBadge.layer.masksToBounds = YES;
        _imageBadge.hidden = YES;
        [self addSubview:_imageBadge];

        // DT button.
        _deepThinkingButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        [_deepThinkingButton addTarget:self action:@selector(_deepThinkingTapped)
                      forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_deepThinkingButton];

        // Web button.
        _webSearchButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        [_webSearchButton addTarget:self action:@selector(_webSearchTapped)
                    forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_webSearchButton];

        // Send button.
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

    // Image button (leftmost) — hidden if model doesn't support images.
    if (!_imageButton.hidden) {
        _imageButton.frame = CGRectMake(x, btnY, btnW, btnH);
        _imageBadge.frame = CGRectMake(x + btnW - 10, btnY - 4, 16, 16);
        x += btnW + gap;
    }

    // DT button.
    _deepThinkingButton.frame = CGRectMake(x, btnY, btnW, btnH);
    x += btnW + gap;

    // Web button.
    _webSearchButton.frame = CGRectMake(x, btnY, btnW, btnH);
    x += btnW + gap;

    // Send button (right).
    CGFloat sendX = w - sendW - pad;
    _sendButton.frame = CGRectMake(sendX, btnY, sendW, btnH);

    // Text view (middle, fills remaining space).
    CGFloat tvX = x + gap;
    CGFloat tvW = sendX - gap - tvX;
    if (tvW < 60) tvW = 60;
    CGFloat tvH = h - 2 * pad;
    if (tvH < 30) tvH = 30;
    _textView.frame = CGRectMake(tvX, pad, tvW, tvH);
}

#pragma mark - Toggles

+ (BOOL)deepThinkingEnabled { NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kUDKeyDeepThinking]; return n ? [n boolValue] : YES; }
+ (void)setDeepThinkingEnabled:(BOOL)e { [[NSUserDefaults standardUserDefaults] setBool:e forKey:kUDKeyDeepThinking]; [[NSUserDefaults standardUserDefaults] synchronize]; }
+ (BOOL)webSearchEnabled { NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kUDKeyWebSearch]; return n ? [n boolValue] : NO; }
+ (void)setWebSearchEnabled:(BOOL)e { [[NSUserDefaults standardUserDefaults] setBool:e forKey:kUDKeyWebSearch]; [[NSUserDefaults standardUserDefaults] synchronize]; }

- (void)_deepThinkingTapped { BOOL v = ![[self class] deepThinkingEnabled]; [[self class] setDeepThinkingEnabled:v]; [self _refreshToggleVisuals]; }
- (void)_webSearchTapped { BOOL v = ![[self class] webSearchEnabled]; [[self class] setWebSearchEnabled:v]; [self _refreshToggleVisuals]; }

- (void)_keyboardDone { [_textView resignFirstResponder]; }

- (void)_refreshToggleVisuals
{
    BOOL dt = [[self class] deepThinkingEnabled];
    BOOL ws = [[self class] webSearchEnabled];
    UIImage *bulb = [IconDrawing imageForType:IconTypeLightbulb size:CGSizeMake(16, 16) color:dt ? [iOS6Theme tintColor] : [UIColor grayColor]];
    UIImage *globe = [IconDrawing imageForType:IconTypeGlobe size:CGSizeMake(16, 16) color:ws ? [iOS6Theme tintColor] : [UIColor grayColor]];
    UIImage *cam = [IconDrawing imageForType:IconTypeCamera size:CGSizeMake(16, 16) color:[UIColor grayColor]];
    UIImage *arrow = [IconDrawing imageForType:IconTypeSendArrow size:CGSizeMake(18, 18) color:[iOS6Theme tintColor]];
    [_deepThinkingButton setImage:bulb forState:UIControlStateNormal];
    [_webSearchButton setImage:globe forState:UIControlStateNormal];
    [_imageButton setImage:cam forState:UIControlStateNormal];
    [_sendButton setImage:arrow forState:UIControlStateNormal];
    // Check if model supports images — hide button if not.
    BOOL imgSupport = [[NSUserDefaults standardUserDefaults] boolForKey:@"modelSupportsImages"];
    _imageButton.hidden = !imgSupport;
    _imageBadge.hidden = !imgSupport || ([_pendingImages count] == 0);
    _imageBadge.text = [NSString stringWithFormat:@"%d", (int)[_pendingImages count]];
}

#pragma mark - Image picker

- (void)_imageButtonTapped
{
    UIImagePickerController *picker = [[[UIImagePickerController alloc] init] autorelease];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.allowsEditing = NO;
    picker.delegate = self;
    UIView *v = self;
    while (v && ![v.nextResponder isKindOfClass:[UIViewController class]]) v = v.superview;
    UIViewController *vc = (UIViewController *)v.nextResponder;
    if (vc) [vc presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info
{
    UIImage *image = [info objectForKey:UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!image) return;

    // Compress: read max dimension from settings.
    // maxDim == 0 means "原图" (original) — skip compression entirely.
    NSInteger maxDim = [[NSUserDefaults standardUserDefaults] integerForKey:@"imageMaxDim"];
    if (maxDim > 0) {
        CGFloat w = image.size.width, h = image.size.height;
        if (w > maxDim || h > maxDim) {
        CGFloat scale = (CGFloat)maxDim / MAX(w, h);
        w = (NSInteger)(w * scale);
        h = (NSInteger)(h * scale);
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 0.0);
        [image drawInRect:CGRectMake(0, 0, w, h)];
        image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }
    }
    // maxDim == 0: send original image (no resize).
    NSData *jpegData = UIImageJPEGRepresentation(image, 0.7);
    if (!jpegData) return;
    NSString *base64 = [jpegData base64String]; // uses our NSDataBase64 category
    NSString *dataUrl = [NSString stringWithFormat:@"data:image/jpeg;base64,%@", base64];
    [_pendingImages addObject:dataUrl];
    [self _refreshToggleVisuals];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Send

- (void)_sendTapped
{
    NSString *text = [_textView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0 && [_pendingImages count] == 0) return;
    [_textView resignFirstResponder];

    BOOL dt = [[self class] deepThinkingEnabled];
    BOOL ws = [[self class] webSearchEnabled];
    NSArray *imgs = [_pendingImages count] > 0 ? [NSArray arrayWithArray:_pendingImages] : nil;

    if ([_delegate respondsToSelector:@selector(composer:didSendText:images:deepThinking:webSearch:)]) {
        [_delegate composer:self didSendText:text images:imgs deepThinking:dt webSearch:ws];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:ComposerViewSendMessageNotification object:self
        userInfo:@{
            ComposerViewSendMessageTextKey: text ?: @"",
            ComposerViewSendMessageDeepThinkingKey: @(dt),
            ComposerViewSendMessageWebSearchKey: @(ws),
            ComposerViewSendMessageImagesKey: imgs ?: [NSNull null]
        }];

    [self clearText];
}

- (void)clearText
{
    _textView.text = @"";
    [_pendingImages removeAllObjects];
    [self _refreshToggleVisuals];
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
    [_deepThinkingButton release];
    [_webSearchButton release];
    [_imageButton release];
    [_imageBadge release];
    [_pendingImages release];
    [super dealloc];
}

@end

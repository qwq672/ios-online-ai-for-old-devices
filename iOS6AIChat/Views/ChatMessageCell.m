//
//  ChatMessageCell.m
//  iOS6AIChat
//
//  Major rewrite for v261018:
//    1. Cached message heights (NSMutableDictionary keyed by messageID +
//       width) so we don't recompute Markdown on every height query —
//       this fixes the "messages 一多就卡死" issue.
//    2. Async image decoding using a global NSCache so images decoded
//       once stay decoded; the cell shows a placeholder until the
//       decode finishes, and never crashes on malformed base64.
//    3. Deep thinking UI: a collapsible block at the top of the bubble
//       showing the assistant's reasoning content (separate from the
//       answer). Tapping the header toggles collapse/expand.
//    4. Dark mode: textview + thinking block now use theme colors.
//

#import "ChatMessageCell.h"
#import "iOS6Theme.h"
#import <QuartzCore/QuartzCore.h>
#import "NSDataBase64.h"
#import "MarkdownParser.h"

// ---- Global image cache (one per app, shared across cells) --------------
// NSCache auto-evicts under memory pressure so we don't blow up.
static NSCache *gImageCache = nil;
static NSCache *gHeightCache = nil;   // messageID@width -> NSNumber height
static NSMutableDictionary *gExpandedThinking = nil;  // messageID -> @"1"

+ (void)_initializeCaches
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gImageCache = [[NSCache alloc] init];
        [gImageCache setCountLimit:64];           // up to 64 decoded images
        [gImageCache setTotalCostLimit:32 * 1024 * 1024];  // 32 MB cap
        gHeightCache = [[NSCache alloc] init];
        [gHeightCache setCountLimit:512];
        gExpandedThinking = [[NSMutableDictionary alloc] init];
    });
}

+ (void)_markThinkingExpanded:(NSString *)mid expanded:(BOOL)e
{
    [self _initializeCaches];
    @synchronized(gExpandedThinking) {
        if (e) [gExpandedThinking setObject:@"1" forKey:mid];
        else [gExpandedThinking removeObjectForKey:mid];
        // Invalidate the height cache for this message — the row height
        // changed since the expand/collapse state affects it.
        for (NSString *key in [gHeightCache allKeys]) {
            if ([key hasPrefix:mid]) [gHeightCache removeObjectForKey:key];
        }
    }
}

+ (BOOL)_isThinkingExpanded:(NSString *)mid
{
    [self _initializeCaches];
    @synchronized(gExpandedThinking) {
        return [gExpandedThinking objectForKey:mid] != nil;
    }
}

// Run base64 decode + UIImage creation on a background queue, then call
// back on main. Uses messageID+imageIndex as cache key.
+ (void)decodeImageWithDataURL:(NSString *)dataURL
                          key:(NSString *)key
                       callback:(void (^)(UIImage *))callback
{
    [self _initializeCaches];
    // Cache hit — synchronous, no decode needed.
    UIImage *cached = [gImageCache objectForKey:key];
    if (cached) {
        dispatch_async(dispatch_get_main_queue(), ^{ callback(cached); });
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            // Strip the data: URL prefix safely. Support multiple formats:
            //   data:image/jpeg;base64,XXXX
            //   data:image/png;base64,XXXX
            //   data:image/webp;base64,XXXX
            NSString *base64 = dataURL;
            NSRange comma = [dataURL rangeOfString:@","];
            if (comma.location != NSNotFound) {
                base64 = [dataURL substringFromIndex:comma.location + comma.length];
            }
            NSData *imgData = [NSData dataFromBase64String:base64];
            if (!imgData || [imgData length] == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{ callback(nil); });
                return;
            }
            UIImage *img = [UIImage imageWithData:imgData];
            if (img) {
                NSUInteger cost = [imgData length];
                [gImageCache setObject:img forKey:key cost:cost];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(img);
            });
        } @catch (NSException *e) {
            dispatch_async(dispatch_get_main_queue(), ^{ callback(nil); });
        }
    });
}

@interface ChatMessageCell () {
    BOOL _thinkingCollapsed;
    NSMutableArray *_imageViews;       // weak refs to image subviews (autoreleased on assign to subview, but we keep for layout)
    NSString *_currentMessageKey;      // for cache key generation
}
@property (nonatomic, retain) UIView *thinkingBlock;
@property (nonatomic, retain) UIButton *thinkingToggle;
@property (nonatomic, retain) UILabel *thinkingLabel;
@property (nonatomic, retain) UIView *thinkingSep;
@end

@implementation ChatMessageCell

@synthesize textView=_textView, bubble=_bubble, message=_message, renderedAttr=_renderedAttr;
@synthesize thinkingBlock=_thinkingBlock, thinkingToggle=_thinkingToggle,
            thinkingLabel=_thinkingLabel, thinkingSep=_thinkingSep;

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if (self = [super initWithStyle:style reuseIdentifier:reuseIdentifier]) {
        [self.class _initializeCaches];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.contentView.backgroundColor = [UIColor clearColor];

        _bubble = [[ChatBubbleView alloc] initWithFrame:CGRectZero];
        [self.contentView addSubview:_bubble];

        _textView = [[UITextView alloc] initWithFrame:CGRectZero];
        _textView.backgroundColor = [UIColor clearColor];
        _textView.editable = NO;
        _textView.scrollEnabled = NO;
        if ([_textView respondsToSelector:@selector(setTextContainerInset:)]) {
            [_textView performSelector:@selector(setTextContainerInset:)
                             withObject:[NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(7, 10, 7, 10)]];
        }
        _textView.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        _textView.textColor = [iOS6Theme textColor];
        _textView.dataDetectorTypes = UIDataDetectorTypeLink;
        _textView.userInteractionEnabled = YES;
        [_bubble addSubview:_textView];

        // Thinking block — collapsible reasoning display.
        _thinkingBlock = [[UIView alloc] initWithFrame:CGRectZero];
        _thinkingBlock.backgroundColor = [iOS6Theme thinkingBackgroundColor];
        _thinkingBlock.layer.cornerRadius = 6.0f;
        _thinkingBlock.layer.borderWidth = 1.0f;
        _thinkingBlock.layer.borderColor = [[iOS6Theme thinkingBorderColor] CGColor];
        _thinkingBlock.clipsToBounds = YES;
        _thinkingBlock.hidden = YES;
        [_bubble addSubview:_thinkingBlock];

        _thinkingToggle = [UIButton buttonWithType:UIButtonTypeCustom];
        _thinkingToggle.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        _thinkingToggle.contentEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 6);
        _thinkingToggle.titleLabel.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:12]];
        [_thinkingToggle setTitleColor:[iOS6Theme secondaryTextColor] forState:UIControlStateNormal];
        [_thinkingToggle addTarget:self action:@selector(_toggleThinking)
                  forControlEvents:UIControlEventTouchUpInside];
        [_thinkingBlock addSubview:_thinkingToggle];

        _thinkingLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _thinkingLabel.numberOfLines = 0;
        _thinkingLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:12]];
        _thinkingLabel.textColor = [iOS6Theme secondaryTextColor];
        _thinkingLabel.backgroundColor = [UIColor clearColor];
        _thinkingLabel.hidden = YES;  // hidden by default (collapsed)
        [_thinkingBlock addSubview:_thinkingLabel];
        _thinkingSep = [[UIView alloc] initWithFrame:CGRectZero];
        _thinkingSep.backgroundColor = [iOS6Theme thinkingBorderColor];
        _thinkingSep.hidden = YES;
        [_thinkingBlock addSubview:_thinkingSep];

        _imageViews = [[NSMutableArray alloc] init];

        // Listen for theme changes.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_themeChanged)
                                                     name:@"iOS6ThemeDidChangeNotification"
                                                   object:nil];

        _thinkingCollapsed = YES;
    }
    return self;
}

- (void)_themeChanged
{
    _textView.textColor = [iOS6Theme textColor];
    _textView.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
    _thinkingBlock.backgroundColor = [iOS6Theme thinkingBackgroundColor];
    _thinkingBlock.layer.borderColor = [[iOS6Theme thinkingBorderColor] CGColor];
    _thinkingSep.backgroundColor = [iOS6Theme thinkingBorderColor];
    _thinkingLabel.textColor = [iOS6Theme secondaryTextColor];
    _thinkingLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:12]];
    _thinkingToggle.titleLabel.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:12]];
    [_thinkingToggle setTitleColor:[iOS6Theme secondaryTextColor] forState:UIControlStateNormal];
    if (_message) [self applyMessage:_message];
}

- (void)prepareForReuse
{
    [super prepareForReuse];
    // Cancel any pending image loads for the previous message — the async
    // callback checks _currentMessageKey and ignores stale callbacks.
    [_currentMessageKey release];
    _currentMessageKey = nil;
    for (UIView *v in _imageViews) {
        [v removeFromSuperview];
    }
    [_imageViews removeAllObjects];
    _thinkingBlock.hidden = YES;
    _thinkingLabel.text = @"";
    _thinkingLabel.hidden = YES;
    _thinkingSep.hidden = YES;
    _thinkingCollapsed = YES;
    self.renderedAttr = nil;
    _textView.attributedText = nil;
}

- (void)_setCurrentMessageKey:(NSString *)key
{
    if (_currentMessageKey != key) {
        [_currentMessageKey release];
        _currentMessageKey = [key copy];
    }
}

- (void)_toggleThinking
{
    _thinkingCollapsed = !_thinkingCollapsed;
    _thinkingLabel.hidden = _thinkingCollapsed;
    _thinkingSep.hidden = _thinkingCollapsed;
    [self.class _markThinkingExpanded:_currentMessageKey expanded:!_thinkingCollapsed];
    [self setNeedsLayout];
    // Tell the table view to re-query row heights — the expanded state
    // changes the cell's required height. Walk up the view tree to find
    // the parent UITableView.
    UIView *v = self.superview;
    while (v && ![v isKindOfClass:[UITableView class]]) v = v.superview;
    if ([v isKindOfClass:[UITableView class]]) {
        UITableView *tv = (UITableView *)v;
        [tv beginUpdates];
        [tv endUpdates];
    }
}

- (void)applyMessage:(Message *)message
{
    self.message = message;
    [self _setCurrentMessageKey:message.messageID];

    BubbleRole role = message.isUser ? BubbleRoleUser : BubbleRoleAssistant;
    _bubble.role = role;

    UIFont *base = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
    CGFloat textWidth = self.bounds.size.width - 2 * 12 - 2 * 10 - 8;
    if (textWidth < 100) textWidth = 200;

    // Build the attributed string.
    self.renderedAttr = [MarkdownParser attributedStringFromMarkdown:message.content
                                                             baseFont:base
                                                                width:textWidth];

    // === Deep thinking block ===
    // If the message has a non-empty `thinking` string, show a collapsible
    // block at the top of the bubble with the reasoning content.
    if (message.thinking.length > 0 && !message.isUser) {
        _thinkingBlock.hidden = NO;
        // Restore the per-message expanded state from the static dict.
        _thinkingCollapsed = ![ChatMessageCell _isThinkingExpanded:message.messageID];
        _thinkingLabel.hidden = _thinkingCollapsed;
        _thinkingSep.hidden = _thinkingCollapsed;
        NSString *headerTitle = _thinkingCollapsed
            ? [NSString stringWithFormat:@"💭 深度思考 (点击展开) — %lu 字",
               (unsigned long)message.thinking.length]
            : [NSString stringWithFormat:@"💭 深度思考 (点击收起)"];
        [_thinkingToggle setTitle:headerTitle forState:UIControlStateNormal];

        // Render thinking content as plain text.
        _thinkingLabel.text = message.thinking;
    } else {
        _thinkingBlock.hidden = YES;
    }

    // === Images ===
    // Remove old image views before adding new ones.
    for (UIView *v in _imageViews) {
        [v removeFromSuperview];
    }
    [_imageViews removeAllObjects];

    if (message.images && [message.images count] > 0) {
        // Append "X images" indicator below the text.
        NSMutableAttributedString *withImages = [NSMutableAttributedString new];
        [withImages appendAttributedString:_renderedAttr];
        [withImages appendAttributedString:[[[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"\n📎 %lu 张图片", (unsigned long)[message.images count]]
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12],
                          NSForegroundColorAttributeName: [iOS6Theme secondaryTextColor]}] autorelease]];
        self.renderedAttr = [withImages autorelease];

        // Build image views lazily — decode on background.
        CGFloat imgW = 80, imgH = 80;
        NSUInteger imgCount = MIN([message.images count], 3);
        for (NSUInteger i = 0; i < imgCount; i++) {
            NSString *dataUrl = [message.images objectAtIndex:i];
            UIImageView *iv = [[[UIImageView alloc] initWithFrame:CGRectZero] autorelease];
            iv.contentMode = UIViewContentModeScaleAspectFill;
            iv.clipsToBounds = YES;
            iv.layer.cornerRadius = 6.0f;
            iv.backgroundColor = [iOS6Theme codeBackgroundColor];  // placeholder bg
            iv.tag = 9000 + (NSInteger)i;
            [_bubble addSubview:iv];
            [_imageViews addObject:iv];

            // Cache key per message + image index.
            NSString *cacheKey = [NSString stringWithFormat:@"%@_%d", message.messageID, (int)i];
            [ChatMessageCell decodeImageWithDataURL:dataUrl
                                                 key:cacheKey
                                              callback:^(UIImage *img) {
                // Stale callback check.
                NSString *currentKey = self->_currentMessageKey;
                if (![currentKey isEqualToString:message.messageID]) return;
                if (img) {
                    iv.image = img;
                } else {
                    // Show broken-image placeholder.
                    iv.backgroundColor = [iOS6Theme secondaryTextColor];
                }
                [self setNeedsLayout];
            }];
        }
    }
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

    // === Thinking block sizing ===
    CGFloat thinkingH = 0;
    if (!_thinkingBlock.hidden) {
        CGFloat thinkingToggleH = 22;
        CGFloat thinkingLabelH = 0;
        if (!_thinkingLabel.hidden && _thinkingLabel.text.length > 0) {
            // Wrap the NSString in an NSAttributedString so we can use
            // boundingRectWithSize:options:context: (iOS 6+ method on
            // NSAttributedString — the NSString version requires the
            // attributes: parameter which is iOS 7+).
            NSAttributedString *thinkAttr = [[[NSAttributedString alloc]
                initWithString:_thinkingLabel.text
                    attributes:@{NSFontAttributeName: _thinkingLabel.font}] autorelease];
            CGSize thinkSize = [thinkAttr
                boundingRectWithSize:CGSizeMake(availTextWidth - 4, CGFLOAT_MAX)
                              options:(NSStringDrawingUsesLineFragmentOrigin |
                                       NSStringDrawingUsesFontLeading)
                              context:nil].size;
            thinkingLabelH = ceilf(thinkSize.height) + 6;
        }
        thinkingH = thinkingToggleH + thinkingLabelH + 6;
        _thinkingToggle.frame = CGRectMake(4, 3, availTextWidth, thinkingToggleH);
        _thinkingLabel.frame = CGRectMake(6, thinkingToggleH + 2, availTextWidth - 4, thinkingLabelH);
        _thinkingSep.frame = CGRectMake(6, thinkingToggleH, availTextWidth - 12, 1);
    }

    // === Main text sizing ===
    CGRect textRect = CGRectZero;
    if (_renderedAttr) {
        textRect = [_renderedAttr boundingRectWithSize:CGSizeMake(availTextWidth, CGFLOAT_MAX)
                                                options:(NSStringDrawingUsesLineFragmentOrigin |
                                                         NSStringDrawingUsesFontLeading)
                                                context:nil];
    }
    if (textRect.size.height < 20) textRect.size.height = 20;

    // === Image strip sizing (if images present) ===
    CGFloat imagesH = 0;
    NSUInteger imgCount = [_imageViews count];
    if (imgCount > 0) {
        imagesH = 80 + 6;  // 80x80 thumbnails + gap
        // Lay them out horizontally.
        CGFloat imgW = 80, imgH = 80, imgGap = 4;
        for (NSUInteger i = 0; i < imgCount; i++) {
            UIView *iv = [_imageViews objectAtIndex:i];
            iv.frame = CGRectMake(4 + (CGFloat)i * (imgW + imgGap), 0, imgW, imgH);
        }
    }

    CGFloat bubbleWidth  = MAX(textRect.size.width + 2 * bubbleInnerHPad + 8, 60);
    bubbleWidth = MIN(bubbleWidth, maxBubbleWidth);
    CGFloat bubbleHeight = textRect.size.height + 2 * bubbleInnerVPad + 6 + 4
                          + thinkingH + imagesH;
    if (bubbleHeight < 40) bubbleHeight = 40;

    CGFloat bubbleX;
    if (_message.isUser) {
        bubbleX = self.bounds.size.width - bubbleWidth - pad;
    } else {
        bubbleX = pad;
    }
    CGFloat bubbleY = verticalPad;
    CGRect bubbleRect = CGRectMake(bubbleX, bubbleY, bubbleWidth, bubbleHeight);
    _bubble.frame = bubbleRect;

    // Place thinking block at top of bubble.
    CGFloat yOffset = 4;
    if (!_thinkingBlock.hidden) {
        _thinkingBlock.frame = CGRectMake(4, yOffset, bubbleWidth - 8, thinkingH);
        yOffset += thinkingH + 4;
    }
    // Text view below thinking block.
    CGFloat textH = bubbleHeight - yOffset - imagesH - 4;
    _textView.frame = CGRectMake(4, yOffset, bubbleWidth - 8, textH);

    // Images at bottom of bubble.
    if (imgCount > 0) {
        CGFloat imgY = bubbleHeight - imagesH - 4;
        for (NSUInteger i = 0; i < imgCount; i++) {
            UIView *iv = [_imageViews objectAtIndex:i];
            CGRect f = iv.frame;
            f.origin.y = imgY;
            iv.frame = f;
        }
    }
}

+ (CGFloat)heightForMessage:(Message *)message width:(CGFloat)width
{
    if (!message) return 60;
    [self _initializeCaches];

    // Cache key — message ID + width + content hash (cheap: just length).
    // Note: during streaming the content changes, so we must include a
    // content length component to invalidate the cache when chunks arrive.
    NSString *cacheKey = [NSString stringWithFormat:@"%@_%.0f_%lu_%lu",
                          message.messageID, (double)width,
                          (unsigned long)message.content.length,
                          (unsigned long)message.thinking.length];
    NSNumber *cached = [gHeightCache objectForKey:cacheKey];
    if (cached) {
        return [cached floatValue];
    }

    CGFloat pad = 12.0f;
    CGFloat bubbleInnerHPad = 10.0f;
    CGFloat bubbleInnerVPad = 7.0f;
    CGFloat verticalPad = 6.0f;
    CGFloat maxBubbleWidth = width - 2 * pad;
    maxBubbleWidth = MIN(maxBubbleWidth, 280.0f);
    CGFloat availTextWidth = maxBubbleWidth - 2 * bubbleInnerHPad - 8;
    if (availTextWidth < 60) availTextWidth = 60;

    UIFont *base = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
    NSAttributedString *attr = [MarkdownParser attributedStringFromMarkdown:message.content
                                                                    baseFont:base
                                                                       width:availTextWidth];
    CGRect textRect = [attr boundingRectWithSize:CGSizeMake(availTextWidth, CGFLOAT_MAX)
                                         options:(NSStringDrawingUsesLineFragmentOrigin |
                                                  NSStringDrawingUsesFontLeading)
                                         context:nil];

    // Thinking block height. Default: collapsed (just the toggle header).
    // If the user has expanded this message, compute the full height.
    CGFloat thinkingH = 0;
    if (message.thinking.length > 0 && !message.isUser) {
        CGFloat thinkingToggleH = 22;
        CGFloat thinkingLabelH = 0;
        if ([self _isThinkingExpanded:message.messageID]) {
            // Compute full thinking label height by wrapping the text
            // at availTextWidth - 4 (the label's actual content width).
            UIFont *thinkFont = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:12]];
            NSAttributedString *thinkAttr = [[[NSAttributedString alloc]
                initWithString:message.thinking
                    attributes:@{NSFontAttributeName: thinkFont}] autorelease];
            CGFloat availW = availTextWidth - 4;
            if (availW < 50) availW = 50;
            // boundingRectWithSize:options:context: is the iOS 6+ method
            // (without attributes parameter — that's iOS 7+ only).
            CGRect thinkRect = [thinkAttr boundingRectWithSize:CGSizeMake(availW, CGFLOAT_MAX)
                                                        options:(NSStringDrawingUsesLineFragmentOrigin |
                                                                 NSStringDrawingUsesFontLeading)
                                                        context:nil];
            thinkingLabelH = ceilf(thinkRect.size.height) + 6;
        }
        thinkingH = thinkingToggleH + thinkingLabelH + 6;
    }

    // Images section.
    CGFloat imagesH = 0;
    if (message.images && [message.images count] > 0) {
        imagesH = 80 + 6;
    }

    CGFloat bubbleHeight = textRect.size.height + 2 * bubbleInnerVPad + 6 + 4
                          + thinkingH + imagesH + 8;
    CGFloat result = bubbleHeight + 2 * verticalPad;
    if (result < 50) result = 50;

    [gHeightCache setObject:[NSNumber numberWithFloat:result] forKey:cacheKey];
    return result;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_bubble release];
    [_textView release];
    [_message release];
    [_renderedAttr release];
    [_thinkingBlock release];
    [_thinkingToggle release];
    [_thinkingLabel release];
    [_thinkingSep release];
    [_imageViews release];
    [_currentMessageKey release];
    [super dealloc];
}

@end

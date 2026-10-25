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
#import "IconDrawing.h"

// ---- Global image cache (one per app, shared across cells) --------------
// NSCache auto-evicts under memory pressure so we don't blow up.
static NSCache *gImageCache = nil;
static NSCache *gHeightCache = nil;   // messageID@width -> NSNumber height
static NSCache *gRenderedAttrCache = nil;  // messageID+contentLen -> NSAttributedString
                                          // shared between cell render + height calc
                                          // so we don't run MarkdownParser twice.
static NSMutableDictionary *gExpandedThinking = nil;  // messageID -> @"1"

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
            thinkingLabel=_thinkingLabel, thinkingSep=_thinkingSep,
            delegate=_delegate,
            regenerateButton=_regenerateButton, clipboardButton=_clipboardButton;

#pragma mark - Cache management (class methods)

+ (void)_initializeCaches
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gImageCache = [[NSCache alloc] init];
        [gImageCache setCountLimit:64];           // up to 64 decoded images
        [gImageCache setTotalCostLimit:32 * 1024 * 1024];  // 32 MB cap
        gHeightCache = [[NSCache alloc] init];
        [gHeightCache setCountLimit:512];
        gRenderedAttrCache = [[NSCache alloc] init];
        [gRenderedAttrCache setCountLimit:256];   // up to 256 rendered attrs
        gExpandedThinking = [[NSMutableDictionary alloc] init];
    });
}

// Flush ALL render caches. Call when theme (dark/light) or font size
// changes — cached attributed strings bake in colors from the theme
// that was active when they were rendered, so switching themes without
// flushing leaves stale-colored text (user-reported: toggle dark mode
// → text stays black).
+ (void)flushCaches
{
    [self _initializeCaches];
    [gRenderedAttrCache removeAllObjects];
    [gHeightCache removeAllObjects];
    // Don't flush image cache — decoded images are theme-independent.
    @synchronized(gExpandedThinking) {
        // Keep expanded-state (user intent), it's theme-independent too.
    }
}

// v261024-16 fix (text overflowing bubble bottom):
// The text-measurement width, the height-calc width and the ACTUAL
// UITextView layout width used to be THREE DIFFERENT numbers
// (boundsWidth-44 vs maxBubbleWidth-28 vs bubbleWidth-38), so the
// rendered attributed string wrapped at a wider width than the text
// container actually offers → real line count > computed line count →
// bottom lines drawn outside the bubble. This single helper is now the
// ONE source of truth used by applyMessage (render), layoutSubviews
// (bubble sizing) AND heightForMessage (row height), so all three wrap
// identically. It models the real iOS 6 text container: bubble inner
// frame inset 4pt per side, textContainerInset 10pt per side, plus
// lineFragmentPadding 5pt per side (NOT settable pre-iOS 7).
+ (CGFloat)unifiedTextWidthForOuterWidth:(CGFloat)outerWidth
{
    CGFloat pad = 12.0f;
    CGFloat maxBubbleWidth = outerWidth - 2 * pad;
    maxBubbleWidth = MIN(maxBubbleWidth, 280.0f);
    CGFloat w = maxBubbleWidth - 2 * 4 - 2 * 10 - 2 * 5;  // = maxBubbleWidth - 38
    if (w < 60) w = 60;
    return w;
}

// Look up or compute the rendered attributed string for a message.
// Shared by both the cell render and the height calc — saves one
// MarkdownParser run per streaming chunk (which was the perf killer
// for long AI replies).
+ (NSAttributedString *)_renderedAttrForMessage:(Message *)message
                                        width:(CGFloat)width
{
    [self _initializeCaches];
    if (!message) return nil;
    NSString *cacheKey = [NSString stringWithFormat:@"%@_%.0f_%lu",
                          message.messageID, (double)width,
                          (unsigned long)message.content.length];
    NSAttributedString *cached = [gRenderedAttrCache objectForKey:cacheKey];
    if (cached) return cached;
    UIFont *base = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
    NSAttributedString *attr = nil;
    // For very long content (>10K chars), skip Markdown parsing — it's
    // too slow and can cause memory pressure on iOS 6. Use plain text
    // rendering instead. (User-reported crash: app dies when AI
    // generates a lot of text.)
    if (message.content.length > 10000) {
        attr = [[[NSAttributedString alloc] initWithString:(message.content ?: @"")
                                                attributes:@{NSFontAttributeName: base,
                                                              NSForegroundColorAttributeName: [iOS6Theme textColor]}] autorelease];
    } else {
        // v261024-19: NO @try — if parser returns nil, fall back to plain.
        attr = [MarkdownParser attributedStringFromMarkdown:message.content
                                                     baseFont:base
                                                        width:width];
        if (!attr) {
            attr = [[[NSAttributedString alloc] initWithString:(message.content ?: @"")
                                                    attributes:@{NSFontAttributeName: base,
                                                                  NSForegroundColorAttributeName: [iOS6Theme textColor]}] autorelease];
        }
    }
    if (attr) {
        // v261025-4: USER messages sit on the saturated green glass
        // bubble (classic iOS 6 Messages) → remap the baked base text
        // colors to white so they stay readable. Only runs for user
        // messages and only on the MISS path (the remapped string is
        // what lands in the cache, so hits stay free).
        if (message.isUser) {
            NSMutableAttributedString *m = [[attr mutableCopy] autorelease];
            if (m) {
                UIColor *base = [iOS6Theme textColor];
                UIColor *sec  = [iOS6Theme secondaryTextColor];
                [m enumerateAttribute:NSForegroundColorAttributeName
                              inRange:NSMakeRange(0, [m length])
                              options:0
                         usingBlock:^(id value, NSRange range, BOOL *stop) {
                    if (![(NSObject *)value isKindOfClass:[UIColor class]]) return;
                    UIColor *c = (UIColor *)value;
                    // Exact-component matches only — code blocks, links
                    // and syntax colors keep their own palette.
                    if ([c isEqual:base]) {
                        [m addAttribute:NSForegroundColorAttributeName
                                  value:[UIColor whiteColor] range:range];
                    } else if ([c isEqual:sec]) {
                        [m addAttribute:NSForegroundColorAttributeName
                                  value:[UIColor colorWithWhite:1.0f alpha:0.82f]
                                          range:range];
                    }
                }];
                attr = m;
            }
        }
        [gRenderedAttrCache setObject:attr forKey:cacheKey
                              cost:(NSInteger)[message.content length]];
    }
    return attr;
}

+ (void)_markThinkingExpanded:(NSString *)mid expanded:(BOOL)e
{
    [self _initializeCaches];
    @synchronized(gExpandedThinking) {
        if (e) [gExpandedThinking setObject:@"1" forKey:mid];
        else [gExpandedThinking removeObjectForKey:mid];
        // NSCache on iOS 6 doesn't expose `allKeys`, so we can't
        // selectively invalidate entries by message ID prefix.
        // Just flush the whole height cache — it'll be re-populated
        // lazily as the table view queries heightForRow again.
        // The cost is one extra Markdown re-render pass per visible
        // message, which is acceptable for a tap-driven action.
        [gHeightCache removeAllObjects];
    }
}

+ (BOOL)_isThinkingExpanded:(NSString *)mid
{
    [self _initializeCaches];
    @synchronized(gExpandedThinking) {
        return [gExpandedThinking objectForKey:mid] != nil;
    }
}

// "Thinking live" — the AI is STILL reasoning: reasoning_content is
// streaming in but the final answer hasn't started yet (content is empty
// or still the "…" placeholder). While live, the thinking block
// auto-expands so the user can watch the reasoning stream in (user-
// reported: bubble stayed "three dots" tall and hid the thinking).
// Once real content arrives the block auto-collapses back to the header,
// unless the user manually expanded it for this message.
+ (BOOL)_isThinkingLive:(Message *)message
{
    if (!message || message.isUser) return NO;
    if (message.thinking.length == 0) return NO;
    NSString *c = message.content;
    if (c.length == 0 || [c isEqualToString:@"…"]) return YES;
    return NO;
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
        // v261025-1: @autoreleasepool — GCD worker threads have NO pool;
        // the autoreleased NSData/UIImage below leaked per decode.
        @autoreleasepool {
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
        }
    });
}

#pragma mark - Init / lifecycle

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

        // Regenerate + Copy buttons (only shown for AI assistant messages).
        _regenerateButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _regenerateButton.frame = CGRectMake(0, 0, 36, 24);
        [_regenerateButton setImage:[IconDrawing imageForType:IconTypeRefresh
                                                           size:CGSizeMake(16, 16)
                                                          color:[iOS6Theme secondaryTextColor]]
                          forState:UIControlStateNormal];
        [_regenerateButton addTarget:self action:@selector(_regenerateTapped)
                     forControlEvents:UIControlEventTouchUpInside];
        _regenerateButton.hidden = YES;
        [self.contentView addSubview:_regenerateButton];

        _clipboardButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _clipboardButton.frame = CGRectMake(0, 0, 36, 24);
        [_clipboardButton setImage:[IconDrawing imageForType:IconTypeCopy
                                                    size:CGSizeMake(16, 16)
                                                   color:[iOS6Theme secondaryTextColor]]
                   forState:UIControlStateNormal];
        [_clipboardButton addTarget:self action:@selector(_copyTapped)
                      forControlEvents:UIControlEventTouchUpInside];
        _clipboardButton.hidden = YES;
        [self.contentView addSubview:_clipboardButton];

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
    // Flush caches — the cached attributed strings have the OLD theme's
    // colors baked in.
    [ChatMessageCell flushCaches];
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
    _regenerateButton.hidden = YES;
    _clipboardButton.hidden = YES;
}

- (void)_setCurrentMessageKey:(NSString *)key
{
    if (_currentMessageKey != key) {
        [_currentMessageKey release];
        _currentMessageKey = [key copy];
    }
}

- (void)_regenerateTapped
{
    if ([self.delegate respondsToSelector:@selector(chatCell:didTapRegenerate:)]) {
        [self.delegate chatCell:self didTapRegenerate:_message];
    }
}

- (void)_copyTapped
{
    if ([self.delegate respondsToSelector:@selector(chatCell:didTapCopy:)]) {
        [self.delegate chatCell:self didTapCopy:_message];
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
    // v261024-19: NO @try — caller-side nil-guard + the internal func
    // does its own checks. If something is malformed, the worst case is
    // a sparse bubble, not a crash.
    if (!message) {
        _textView.text = @"⚠️ 消息为空";
        _textView.textColor = [iOS6Theme textColor];
        _thinkingBlock.hidden = YES;
        return;
    }
    [self _applyMessageInternal:message];
}

- (void)_applyMessageInternal:(Message *)message
{
    self.message = message;
    [self _setCurrentMessageKey:message.messageID];

    BubbleRole role = message.isUser ? BubbleRoleUser : BubbleRoleAssistant;
    _bubble.role = role;

    // v261025-4: base text color follows the bubble — white on the
    // green user glass, theme color on the silver/charcoal AI glass.
    // (Only affects plain-text fallbacks; the attributed string above
    // is the real render path.)
    _textView.textColor = message.isUser ? [UIColor whiteColor]
                                          : [iOS6Theme textColor];

    // Compute text width — MUST use the same unified width as
    // heightForMessage and _layoutInternal so the Markdown re-wrap and
    // the height calc agree (see unifiedTextWidthForOuterWidth:).
    // self.bounds may be 0 on first apply (cell created but not laid out
    // yet) — fall back to screen width.
    CGFloat boundsWidth = self.bounds.size.width;
    if (boundsWidth < 100) {
        boundsWidth = [UIScreen mainScreen].bounds.size.width;
    }
    CGFloat textWidth = [ChatMessageCell unifiedTextWidthForOuterWidth:boundsWidth];

    // Build the attributed string. Use the shared cache so we don't
    // run MarkdownParser twice per streaming chunk (cell render + height
    // calc). This was the perf killer for long AI replies.
    self.renderedAttr = [ChatMessageCell _renderedAttrForMessage:message
                                                            width:textWidth];

    // === Deep thinking block ===
    // If the message has a non-empty `thinking` string, show a collapsible
    // block at the top of the bubble with the reasoning content.
    if (message.thinking.length > 0 && !message.isUser) {
        _thinkingBlock.hidden = NO;
        // Restore the per-message expanded state from the static dict.
        // While the AI is still mid-reasoning (thinking live) force-expand
        // so the streaming reasoning is visible in real time.
        BOOL thinkingLive = [ChatMessageCell _isThinkingLive:message];
        _thinkingCollapsed = !([ChatMessageCell _isThinkingExpanded:message.messageID]
                                || thinkingLive);
        _thinkingLabel.hidden = _thinkingCollapsed;
        _thinkingSep.hidden = _thinkingCollapsed;
        NSString *headerTitle;
        if (thinkingLive) {
            headerTitle = @"💭 深度思考中…";
        } else if (_thinkingCollapsed) {
            headerTitle = [NSString stringWithFormat:@"💭 深度思考 (点击展开) — %lu 字",
               (unsigned long)message.thinking.length];
        } else {
            headerTitle = @"💭 深度思考 (点击收起)";
        }
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
        // v261025-4: translucent white on the green user bubble.
        NSMutableAttributedString *withImages = [NSMutableAttributedString new];
        [withImages appendAttributedString:_renderedAttr];
        UIColor *imgNoteColor = message.isUser
            ? [UIColor colorWithWhite:1.0f alpha:0.82f]
            : [iOS6Theme secondaryTextColor];
        [withImages appendAttributedString:[[[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"\n📎 %lu 张图片", (unsigned long)[message.images count]]
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12],
                          NSForegroundColorAttributeName: imgNoteColor}] autorelease]];
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
    // v261024-19: NO @try — _layoutInternal does its own nil-guards.
    [self _layoutInternal];
}

- (void)_layoutInternal
{
    CGFloat pad = 12.0f;
    CGFloat bubbleInnerHPad = 10.0f;
    CGFloat bubbleInnerVPad = 7.0f;
    CGFloat verticalPad = 6.0f;
    CGFloat maxBubbleWidth = self.bounds.size.width - 2 * pad;
    maxBubbleWidth = MIN(maxBubbleWidth, 280.0f);

    // v261024-16: unified width — same value as heightForMessage uses,
    // matching the UITextView's REAL line-breaking width. The old value
    // (maxBubbleWidth - 28) was 10pt wider than the text container's
    // actual width, so long messages wrapped into MORE lines at render
    // time than the height calc predicted → text spilled past the bubble
    // bottom (user-reported AGAIN after v261024-12's fix).
    CGFloat availTextWidth = [ChatMessageCell unifiedTextWidthForOuterWidth:self.bounds.size.width];
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

    // Bubble width.
    // While the AI is still mid-reasoning (thinking live, content empty or
    // just "…"), the text width is near zero, which used to collapse the
    // bubble to the 60pt minimum — visually identical to the three-dot
    // loading animation. Stretch the bubble to maxBubbleWidth in this case
    // so the streaming reasoning text has room to flow. Once the final
    // answer arrives, fall back to width-follows-text.
    // v261024-16: short-text width uses +38 (the unified per-side insets:
    // 4 frame + 10 container inset + 5 line fragment padding) so the text
    // container can actually fit the measured single-line width.
    BOOL thinkingLive = [ChatMessageCell _isThinkingLive:_message];
    CGFloat bubbleWidth;
    if (thinkingLive) {
        bubbleWidth = maxBubbleWidth;
    } else {
        bubbleWidth = MAX(textRect.size.width + 38, 60);
        bubbleWidth = MIN(bubbleWidth, maxBubbleWidth);
    }
    // Bubble height: text + vertical padding + tail (6) + bottom safety (12).
    // The +12 (was +8) gives extra room so the last line of text isn't
    // clipped by the bubble's tail drawing — iOS 6 boundingRectWithSize
    // systematically under-reports CJK line heights by 1-3pt per line.
    CGFloat tailHeight = 6.0f;
    CGFloat bubbleHeight = textRect.size.height + 2 * bubbleInnerVPad + tailHeight + 12
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
    // Text view below thinking block. Leave room for the tail at the bottom
    // (tailHeight + 4px safety) so text isn't clipped.
    CGFloat textH = bubbleHeight - yOffset - imagesH - tailHeight - 4;
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

    // === Action buttons (regenerate + copy) — AI assistant only ===
    BOOL showButtons = !_message.isUser && _message.content.length > 0;
    _regenerateButton.hidden = !showButtons;
    _clipboardButton.hidden = !showButtons;
    if (showButtons) {
        CGFloat btnY = bubbleY + bubbleHeight + 2;
        CGFloat btnW = 36, btnH = 24, btnGap = 4;
        // Left-align buttons under the bubble.
        CGFloat regenX = bubbleX;
        _regenerateButton.frame = CGRectMake(regenX, btnY, btnW, btnH);
        _clipboardButton.frame = CGRectMake(regenX + btnW + btnGap, btnY, btnW, btnH);
    }
}

+ (CGFloat)heightForMessage:(Message *)message width:(CGFloat)width
{
    // v261024-19: NO @try — internal func does its own checks.
    if (!message) return 60;
    return [self _heightForMessageInternal:message width:width];
}

+ (CGFloat)_heightForMessageInternal:(Message *)message width:(CGFloat)width
{
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
    CGFloat bubbleInnerVPad = 7.0f;
    CGFloat verticalPad = 6.0f;
    // v261024-16: unified width — MUST match _applyMessageInternal and
    // _layoutInternal so the row height reflects the rendered wrap.
    CGFloat availTextWidth = [ChatMessageCell unifiedTextWidthForOuterWidth:width];
    if (availTextWidth < 60) availTextWidth = 60;

    // Use the SHARED rendered-attr cache — saves a MarkdownParser run
    // per streaming chunk (which was the perf killer for long AI replies).
    // The cache invalidates automatically when content.length changes.
    NSAttributedString *attr = [ChatMessageCell _renderedAttrForMessage:message
                                                                   width:availTextWidth];
    CGRect textRect = [attr boundingRectWithSize:CGSizeMake(availTextWidth, CGFLOAT_MAX)
                                         options:(NSStringDrawingUsesLineFragmentOrigin |
                                                  NSStringDrawingUsesFontLeading)
                                         context:nil];

    // Thinking block height. Default: collapsed (just the toggle header).
    // If the user has expanded this message, OR the AI is still actively
    // thinking (streaming reasoning, no final answer yet), compute the
    // FULL height so the bubble grows with the reasoning text.
    CGFloat thinkingH = 0;
    if (message.thinking.length > 0 && !message.isUser) {
        CGFloat thinkingToggleH = 22;
        CGFloat thinkingLabelH = 0;
        if ([self _isThinkingExpanded:message.messageID] ||
            [self _isThinkingLive:message]) {
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

    // Match layoutSubviews: text + vpad + tail(6) + safety(12) + thinking + images.
    // Plus 2*verticalPad for cell padding.
    // Plus action buttons height (24+2=26) for AI assistant messages.
    CGFloat buttonH = (!message.isUser && message.content.length > 0) ? 26 : 0;
    CGFloat bubbleHeight = textRect.size.height + 2 * bubbleInnerVPad + 6 + 12
                          + thinkingH + imagesH;
    CGFloat result = bubbleHeight + 2 * verticalPad + buttonH;
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
    [_regenerateButton release];
    [_clipboardButton release];
    [super dealloc];
}

@end

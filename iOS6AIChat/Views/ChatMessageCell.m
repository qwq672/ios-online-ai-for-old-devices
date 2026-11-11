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
// v261103-1: set of messageIDs currently being streamed. The render cache
// uses a FAST path (no emoji-font / color-remap / table / math passes) for
// streaming messages to keep streaming smooth on long content; the FULL
// path runs once on completion.
static NSMutableSet *gStreamingMessageIDs = nil;

@interface ChatMessageCell () {
    BOOL _thinkingCollapsed;
    NSMutableArray *_imageViews;
    NSString *_currentMessageKey;
    UIImageView *_generatedImageView;
    UIColor *_thinkingBorderUIColor;
    UIColor *_thinkingBgUIColor;
    UIColor *_thinkingSepUIColor;
    UIView *_accentLine;
    UIColor *_accentLineColor;
    // v261103-33: 穿插思考卡片 — 从 content 解析出的 section 数组
    // 每个 section = NSMutableDictionary: {type, title, content, toggle, label, sep, collapsed, height}
    // type: "thinking" / "text" / "tool"
    NSMutableArray *_inlineSections;
}
@property (nonatomic, retain) UIView *thinkingBlock;
@property (nonatomic, retain) UIButton *thinkingToggle;
@property (nonatomic, retain) UILabel *thinkingLabel;
@property (nonatomic, retain) UIView *thinkingSep;
@property (nonatomic, retain) NSMutableArray *thinkingSegments;
@property (nonatomic, retain) NSMutableArray *inlineSections;  // v261103-33
@property (nonatomic, retain) UIView *sectionsContainer;  // v261103-33: 容器 view
@property (nonatomic, retain) UIImageView *generatedImageView;
@end

@implementation ChatMessageCell

@synthesize textView=_textView, bubble=_bubble, message=_message, renderedAttr=_renderedAttr;
@synthesize thinkingBlock=_thinkingBlock, thinkingToggle=_thinkingToggle,
            thinkingLabel=_thinkingLabel, thinkingSep=_thinkingSep,
            thinkingSegments=_thinkingSegments,
            inlineSections=_inlineSections, sectionsContainer=_sectionsContainer,
            generatedImageView=_generatedImageView,
            delegate=_delegate,
            regenerateButton=_regenerateButton, clipboardButton=_clipboardButton,
            editButton=_editButton,
            variantPrevButton=_variantPrevButton,
            variantNextButton=_variantNextButton,
            variantIndexLabel=_variantIndexLabel;

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
        gStreamingMessageIDs = [[NSMutableSet alloc] init];
    });
}

// v261103-1: streaming-mode signaling. ChatViewController marks the
// assistant message as "streaming" when chunks start arriving, and
// "done" when didFinish fires. The render cache uses a FAST path
// during streaming to avoid the lag from full MarkdownParser +
// emoji-font + color-remap passes on every chunk.
+ (void)markMessageStreaming:(NSString *)messageID
{
    if (!messageID) return;
    [self _initializeCaches];
    @synchronized(gStreamingMessageIDs) {
        [gStreamingMessageIDs addObject:messageID];
    }
    // Invalidate any existing cached render for this message — the next
    // render will use the fast path and produce a new (lighter) attr.
    // (NSCache doesn't support prefix eviction, so we just bump the cost
    // limit; the entry will be evicted naturally. For correctness, the
    // cache key includes contentLength so a stale fast-path entry would
    // be overwritten anyway.)
}

+ (void)markMessageDone:(NSString *)messageID
{
    if (!messageID) return;
    [self _initializeCaches];
    @synchronized(gStreamingMessageIDs) {
        [gStreamingMessageIDs removeObject:messageID];
    }
    // The next render will use the FULL path. The cache key includes
    // contentLength, so the final render (with the last content length)
    // won't collide with the streaming-rendered entry. But to be safe,
    // flush the whole renderedAttr cache so the next render re-runs the
    // full MarkdownParser. (Height cache stays — heights are computed
    // from the same attr, so re-rendering invalidates them too.)
    [gRenderedAttrCache removeAllObjects];
    [gHeightCache removeAllObjects];
}

+ (BOOL)isMessageStreaming:(NSString *)messageID
{
    if (!messageID) return NO;
    [self _initializeCaches];
    @synchronized(gStreamingMessageIDs) {
        return [gStreamingMessageIDs containsObject:messageID];
    }
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

// v261025-8: drop only the height cache (see header). One-shot cost —
// the next heightForRow pass repopulates lazily.
+ (void)invalidateHeightCache
{
    [self _initializeCaches];
    [gHeightCache removeAllObjects];
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
    // v261025-32: user messages keep bubble padding; AI messages get
    // wider text area (no bubble). This is called for BOTH user + AI,
    // so we return the USER width here (the conservative/narrower one).
    // AI width is calculated inline in _layoutInternal + heightForMessage.
    CGFloat pad = 8.0f;
    CGFloat maxBubbleWidth = outerWidth - 2 * pad;
    maxBubbleWidth = MIN(maxBubbleWidth, 280.0f);
    CGFloat w = maxBubbleWidth - 2 * 4 - 2 * 10 - 2 * 5;  // = maxBubbleWidth - 38
    if (w < 60) w = 60;
    return w;
}

// v261025-32: AI text width — no bubble, wider area.
// 2pt accent + 6pt gap + 4pt right margin + 2*4 textContainerInset + 2*5 lineFragment
+ (CGFloat)aiTextWidthForOuterWidth:(CGFloat)outerWidth
{
    CGFloat w = outerWidth - 2 - 6 - 4 - 8 - 10;  // = outerWidth - 30
    if (w < 60) w = 60;
    return w;
}

// Look up or compute the rendered attributed string for a message.
// Shared by both the cell render and the height calc — saves one
// MarkdownParser run per streaming chunk (which was the perf killer
// for long AI replies).
// v261103-1: FAST vs FULL render path. When the message is currently
// streaming (gStreamingMessageIDs contains its ID), use the FAST path:
//   - MarkdownParser with fast=YES (skips table, math, emoji-font pass)
//   - Skip the user-message color remap (enumerateAttribute)
// This cuts the per-chunk render cost from ~200ms to ~50ms on a 5K-char
// message, eliminating the lag/crash on long streaming replies.
+ (NSAttributedString *)_renderedAttrForMessage:(Message *)message
                                        width:(CGFloat)width
{
    [self _initializeCaches];
    if (!message) return nil;
    // v261103-1: streaming flag → fast path. Cache key includes the flag
    // so a streaming-mode entry doesn't get returned for a final render
    // (or vice versa).
    BOOL fast = [ChatMessageCell isMessageStreaming:message.messageID];
    NSString *cacheKey = [NSString stringWithFormat:@"%@_%.0f_%lu_%@",
                          message.messageID, (double)width,
                          (unsigned long)message.content.length,
                          fast ? @"F" : @"S"];
    NSAttributedString *cached = [gRenderedAttrCache objectForKey:cacheKey];
    if (cached) return cached;
    UIFont *base = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
    NSAttributedString *attr = nil;
    // v261103-1: threshold lowered from 10000 → 4000 for the plain-text
    // fallback during streaming. Plain text rendering is ~10x faster than
    // markdown parsing, and for streaming the visual degradation is
    // acceptable (the final full-path render at completion restores
    // formatting). NON-streaming messages keep the 10000 threshold so
    // already-finished long messages still get markdown.
    NSUInteger plainTextThreshold = fast ? 4000 : 10000;
    if (message.content.length > plainTextThreshold) {
        attr = [[[NSAttributedString alloc] initWithString:(message.content ?: @"")
                                                attributes:@{NSFontAttributeName: base,
                                                              NSForegroundColorAttributeName: [iOS6Theme textColor]}] autorelease];
    } else {
        // v261024-19: NO @try — if parser returns nil, fall back to plain.
        attr = [MarkdownParser attributedStringFromMarkdown:message.content
                                                     baseFont:base
                                                        width:width
                                                        fast:fast];
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
        // v261103-1: skip the color remap during streaming (fast path)
        // — user messages are short, but the enumerateAttribute pass
        // is O(n) and unnecessary while chunks are still arriving.
        // The final full-path render will apply the remap.
        if (message.isUser && !fast) {
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
    // v261103-42: nil key 防御 — removeObjectForKey:nil / setObject:forKey:nil
    // 会 NSInvalidArgumentException 闪退（日志定位）
    if (!mid) return;
    [self _initializeCaches];
    @synchronized(gExpandedThinking) {
        if (e) [gExpandedThinking setObject:@"1" forKey:mid];
        else [gExpandedThinking removeObjectForKey:mid];
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

// v261025-8: decode a generated-image FILE (Documents/genimg/<uuid>.png)
// off the main thread, caching by messageID. Mirrors
// decodeImageWithDataURL:key:callback: but reads from disk.
+ (void)decodeImageWithFile:(NSString *)path
                        key:(NSString *)key
                   callback:(void (^)(UIImage *))callback
{
    [self _initializeCaches];
    if (!path || path.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ callback(nil); });
        return;
    }
    UIImage *cached = [gImageCache objectForKey:key];
    if (cached) {
        dispatch_async(dispatch_get_main_queue(), ^{ callback(cached); });
        return;
    }
    NSString *pathCopy = [path copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            UIImage *img = [UIImage imageWithContentsOfFile:pathCopy];
            if (img) {
                // cost ~ file size; estimate from pixel dims (4 bytes/px).
                NSUInteger cost = (NSUInteger)(img.size.width * img.size.height * 4);
                if (cost > 0) {
                    [gImageCache setObject:img forKey:key cost:cost];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(img);
            });
        }
        [pathCopy release];
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

        // v261025-32: accent line for AI messages (left edge, 2pt wide).
        _accentLine = [[UIView alloc] initWithFrame:CGRectZero];
        _accentLine.backgroundColor = [UIColor clearColor];
        _accentLine.hidden = YES;
        [self.contentView addSubview:_accentLine];

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

        // v261103-33: sectionsContainer — 穿插思考卡片的容器
        _sectionsContainer = [[UIView alloc] initWithFrame:CGRectZero];
        _sectionsContainer.backgroundColor = [UIColor clearColor];
        _sectionsContainer.hidden = YES;  // 默认隐藏，有思考块时显示
        [_bubble addSubview:_sectionsContainer];

        // Thinking block — collapsible reasoning display.
        _thinkingBlock = [[UIView alloc] initWithFrame:CGRectZero];
        // v261025-5: retain the theme colors in ivars so the layer's
        // borderColor / the view's backgroundColor hold a strong reference
        // to a UIColor that lives for the lifetime of the cell. The
        // previous pattern (`layer.borderColor = [autoreleased CGColor]`)
        // left a dangling CGColorRef once the pool popped — the user's
        // v261025-4 SIGSEGV crash family was this exact bug.
        _thinkingBgUIColor = [[iOS6Theme thinkingBackgroundColor] retain];
        _thinkingBlock.backgroundColor = _thinkingBgUIColor;
        _thinkingBlock.layer.cornerRadius = 10.0f;   // v261025-11: 6->10, harmonized with outer bubble R14
        _thinkingBlock.layer.borderWidth = 1.0f;
        _thinkingBorderUIColor = [[iOS6Theme thinkingBorderColor] retain];
        _thinkingBlock.layer.borderColor = [_thinkingBorderUIColor CGColor];
        _thinkingBlock.clipsToBounds = YES;
        _thinkingBlock.hidden = YES;
        [_bubble addSubview:_thinkingBlock];

        _thinkingToggle = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
        // v261025-7 CRITICAL: +[UIButton buttonWithType:] returns an
        // AUTORELEASED (+0) object. The OLD code assigned it directly to
        // the ivar — bypassing the synthesized (retain) setter — so NO
        // retain happened, yet dealloc released it → over-release by 1.
        // The button then dealloc'd WHILE STILL A SUBVIEW, and the later
        // view-hierarchy teardown released the freed object again →
        // use-after-free SIGSEGV. THIS is the root cause of the
        // "两轮对话必闪退" crash family (v261025-4 logs: ChatMessageCell
        // dealloc / ChatBubbleView dealloc / _CFAutoreleasePoolPop).
        // Every buttonWithType: assignment in this file now retains.
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
        _thinkingSepUIColor = [[iOS6Theme thinkingBorderColor] retain];
        _thinkingSep.backgroundColor = _thinkingSepUIColor;
        _thinkingSep.hidden = YES;
        [_thinkingBlock addSubview:_thinkingSep];

        _imageViews = [[NSMutableArray alloc] init];

        // v261025-8: 生图 result view — big rounded image in the bubble.
        // Retained via the synthesized (retain) property setter below.
        _generatedImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _generatedImageView.contentMode = UIViewContentModeScaleAspectFit;
        _generatedImageView.clipsToBounds = YES;
        _generatedImageView.layer.cornerRadius = 8.0f;
        _generatedImageView.backgroundColor = [iOS6Theme codeBackgroundColor];
        _generatedImageView.hidden = YES;
        // v261025-8: tap → full-screen viewer (delegate hook).
        _generatedImageView.userInteractionEnabled = YES;
        UITapGestureRecognizer *genTap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(_genImageTapped)];
        genTap.numberOfTapsRequired = 1;
        [_generatedImageView addGestureRecognizer:genTap];
        [genTap release];
        [_bubble addSubview:_generatedImageView];

        // Regenerate + Copy buttons (only shown for AI assistant messages).
        _regenerateButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
        _regenerateButton.frame = CGRectMake(0, 0, 36, 24);
        [_regenerateButton setImage:[IconDrawing imageForType:IconTypeRefresh
                                                           size:CGSizeMake(16, 16)
                                                          color:[iOS6Theme secondaryTextColor]]
                          forState:UIControlStateNormal];
        [_regenerateButton addTarget:self action:@selector(_regenerateTapped)
                     forControlEvents:UIControlEventTouchUpInside];
        _regenerateButton.hidden = YES;
        [self.contentView addSubview:_regenerateButton];

        _clipboardButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
        _clipboardButton.frame = CGRectMake(0, 0, 36, 24);
        [_clipboardButton setImage:[IconDrawing imageForType:IconTypeCopy
                                                    size:CGSizeMake(16, 16)
                                                   color:[iOS6Theme secondaryTextColor]]
                   forState:UIControlStateNormal];
        [_clipboardButton addTarget:self action:@selector(_copyTapped)
                      forControlEvents:UIControlEventTouchUpInside];
        _clipboardButton.hidden = YES;
        [self.contentView addSubview:_clipboardButton];

        // v261025-6: user-message edit button — pencil icon, only shown on
        // user cells. Tap fires didTapEditUserMessage: on the delegate,
        // which pops an alert pre-filled with the user's original text.
        _editButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
        _editButton.frame = CGRectMake(0, 0, 36, 24);
        [_editButton setImage:[IconDrawing imageForType:IconTypeRefresh
                                                    size:CGSizeMake(16, 16)
                                                   color:[iOS6Theme secondaryTextColor]]
                  forState:UIControlStateNormal];
        // Pencil icon isn't in IconDrawing — reuse the copy icon shape
        // but tint it differently so it reads as "edit" not "copy".
        // TODO: add a proper pencil icon type if needed.
        [_editButton setImage:[IconDrawing imageForType:IconTypeCopy
                                                    size:CGSizeMake(16, 16)
                                                   color:[iOS6Theme tintColor]]
                  forState:UIControlStateNormal];
        [_editButton addTarget:self action:@selector(_editTapped)
                  forControlEvents:UIControlEventTouchUpInside];
        _editButton.hidden = YES;
        [self.contentView addSubview:_editButton];

        // v261025-6: variant pager — "‹ 1/N ›" UI + prev/next arrows.
        // Hidden by default; only shown on AI cells where variants.count
        // >= 1 (i.e. the user has regenerated at least once).
        _variantPrevButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
        _variantPrevButton.frame = CGRectMake(0, 0, 28, 24);
        _variantPrevButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        // v261025-7: plain ASCII "<" — U+2039 ‹ may lack a glyph in iOS 6
        // Helvetica (never gamble on exotic codepoints there).
        [_variantPrevButton setTitle:@"<" forState:UIControlStateNormal];
        [_variantPrevButton setTitleColor:[iOS6Theme tintColor]
                               forState:UIControlStateNormal];
        [_variantPrevButton addTarget:self action:@selector(_variantPrevTapped)
                       forControlEvents:UIControlEventTouchUpInside];
        _variantPrevButton.hidden = YES;
        [self.contentView addSubview:_variantPrevButton];

        _variantNextButton = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
        _variantNextButton.frame = CGRectMake(0, 0, 28, 24);
        _variantNextButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        // v261025-7: plain ASCII ">" (same glyph-safety reason).
        [_variantNextButton setTitle:@">" forState:UIControlStateNormal];
        [_variantNextButton setTitleColor:[iOS6Theme tintColor]
                               forState:UIControlStateNormal];
        [_variantNextButton addTarget:self action:@selector(_variantNextTapped)
                       forControlEvents:UIControlEventTouchUpInside];
        _variantNextButton.hidden = YES;
        [self.contentView addSubview:_variantNextButton];

        _variantIndexLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 50, 24)];
        _variantIndexLabel.font = [UIFont systemFontOfSize:12];
        _variantIndexLabel.textColor = [iOS6Theme secondaryTextColor];
        _variantIndexLabel.backgroundColor = [UIColor clearColor];
        _variantIndexLabel.textAlignment = NSTextAlignmentCenter;
        _variantIndexLabel.text = @"";
        _variantIndexLabel.hidden = YES;
        [self.contentView addSubview:_variantIndexLabel];

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
    // v261025-5: refresh the retained UIColor ivars too so the layer
    // borderColor keeps pointing at a live UIColor (and a live CGColor)
    // after the theme flip.
    [_thinkingBgUIColor release];
    _thinkingBgUIColor = [[iOS6Theme thinkingBackgroundColor] retain];
    _thinkingBlock.backgroundColor = _thinkingBgUIColor;
    [_thinkingBorderUIColor release];
    _thinkingBorderUIColor = [[iOS6Theme thinkingBorderColor] retain];
    _thinkingBlock.layer.borderColor = [_thinkingBorderUIColor CGColor];
    [_thinkingSepUIColor release];
    _thinkingSepUIColor = [[iOS6Theme thinkingBorderColor] retain];
    _thinkingSep.backgroundColor = _thinkingSepUIColor;
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
    // v261025-6: hide the new edit + pager buttons on reuse.
    _editButton.hidden = YES;
    _variantPrevButton.hidden = YES;
    _variantNextButton.hidden = YES;
    _variantIndexLabel.hidden = YES;
    // v261025-8: reset the 生图 result view.
    _generatedImageView.hidden = YES;
    _generatedImageView.image = nil;
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

// v261025-6: user-message edit — fires the edit delegate, which shows an
// alert pre-filled with the user's text and on save truncates from this
// message onward and re-sends (possibly edited).
- (void)_editTapped
{
    if ([self.delegate respondsToSelector:@selector(chatCell:didTapEditUserMessage:)]) {
        [self.delegate chatCell:self didTapEditUserMessage:_message];
    }
}

// v261025-6: variant pager — prev / next arrows.
- (void)_variantPrevTapped
{
    if ([self.delegate respondsToSelector:@selector(chatCell:didTapVariantArrow:direction:)]) {
        [self.delegate chatCell:self didTapVariantArrow:_message direction:-1];
    }
}

- (void)_variantNextTapped
{
    if ([self.delegate respondsToSelector:@selector(chatCell:didTapVariantArrow:direction:)]) {
        [self.delegate chatCell:self didTapVariantArrow:_message direction:+1];
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

// v261103-22: 多段思考卡片的 toggle — sender.tag = segment index
// v261103-33: 解析 \x00THINK\x00 标记，创建穿插可折叠卡片
// 标记格式: \x00THINK\x00标题\x01内容\x00END\x00
// 解析后 _textView 只显示非标记文字，思考卡片在 sectionsContainer 里
- (void)_parseInlineThinkingSections:(NSString *)content message:(Message *)message
{
    // 清理旧 sections
    // v261103-42: 修复文字上下重叠 — 原来只 remove "view" key（思考卡片 cardView），
    // 文字段的 UILabel（key="label"）直接加在 _sectionsContainer 上没 remove →
    // 流式刷新重新解析时新旧 UILabel 叠在一起 → 上下重叠。
    // 改成遍历 _sectionsContainer.subviews 全部 remove，最干净。
    if (_inlineSections) {
        for (UIView *sub in [_sectionsContainer subviews]) {
            [sub removeFromSuperview];
        }
        [_inlineSections removeAllObjects];
    } else {
        self.inlineSections = [NSMutableArray array];
    }

    // v261103-40: 穿插布局 — 文字段不再拼接进 cleanText，
    // 而是创建 UILabel 加入 _inlineSections（type=text），
    // 和思考卡片交替堆叠，实现真正的穿插。
    NSInteger thinkIdx = 0;
    CGFloat boundsWidth = self.bounds.size.width;
    if (boundsWidth < 100) boundsWidth = [UIScreen mainScreen].bounds.size.width;
    CGFloat textWidth = [ChatMessageCell aiTextWidthForOuterWidth:boundsWidth];
    UIFont *baseFont = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];

    NSUInteger searchStart = 0;
    NSString *thinkTag = @"\x00THINK\x00";
    NSString *endTag = @"\x00END\x00";
    NSString *sep = @"\x01";

    // helper: 创建文字段 UILabel 加入 _inlineSections
    void (^addTextSection)(NSString *) = ^(NSString *textSeg) {
        if (!textSeg || textSeg.length == 0) return;
        UILabel *textLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        textLabel.numberOfLines = 0;
        textLabel.font = baseFont;
        textLabel.textColor = [iOS6Theme textColor];
        textLabel.backgroundColor = [UIColor clearColor];
        NSAttributedString *renderedText = [MarkdownParser attributedStringFromMarkdown:textSeg
                                                                           baseFont:baseFont
                                                                              width:textWidth];
        textLabel.attributedText = renderedText;
        textLabel.lineBreakMode = NSLineBreakByWordWrapping;
        [_sectionsContainer addSubview:textLabel];
        NSMutableDictionary *textSec = [NSMutableDictionary dictionaryWithObjectsAndKeys:
            @"text", @"type",
            textSeg, @"content",
            textLabel, @"label",
            nil];
        [_inlineSections addObject:textSec];
        [textLabel release];
    };

    while (searchStart < [content length]) {
        NSRange thinkRange = [content rangeOfString:thinkTag
                                            options:0
                                              range:NSMakeRange(searchStart, [content length] - searchStart)];
        if (thinkRange.location == NSNotFound) {
            // 剩余都是普通文字 — 创建 UILabel 加入 sections
            NSString *remaining = [content substringFromIndex:searchStart];
            addTextSection(remaining);
            break;
        }

        // thinkRange.location 之前的文字是普通段 — 创建 UILabel
        if (thinkRange.location > searchStart) {
            NSString *textBefore = [content substringWithRange:NSMakeRange(searchStart, thinkRange.location - searchStart)];
            addTextSection(textBefore);
        }

        // 找 \x00END\x00
        NSUInteger endSearchStart = thinkRange.location + thinkRange.length;
        NSRange endRange = [content rangeOfString:endTag
                                          options:0
                                            range:NSMakeRange(endSearchStart, [content length] - endSearchStart)];
        if (endRange.location == NSNotFound) break;

        // 提取 title + content（用 \x01 分隔）
        NSString *thinkContent = [content substringWithRange:NSMakeRange(endSearchStart, endRange.location - endSearchStart)];
        NSRange sepRange = [thinkContent rangeOfString:sep];
        NSString *title = sepRange.location != NSNotFound ? [thinkContent substringToIndex:sepRange.location] : @"思考";
        NSString *thinkText = sepRange.location != NSNotFound ? [thinkContent substringFromIndex:sepRange.location + sepRange.length] : thinkContent;

        // 创建可折叠卡片 view
        UIView *cardView = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
        cardView.backgroundColor = [iOS6Theme thinkingBackgroundColor];
        cardView.layer.cornerRadius = 8.0f;
        cardView.layer.borderWidth = 1.0f;
        // 保留 borderColor 的 UIColor
        UIColor *borderColor = [[iOS6Theme thinkingBorderColor] retain];
        cardView.layer.borderColor = [borderColor CGColor];
        cardView.clipsToBounds = YES;

        // toggle 按钮
        UIButton *toggle = [UIButton buttonWithType:UIButtonTypeCustom];
        toggle.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        toggle.contentEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 6);
        toggle.titleLabel.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:12]];
        [toggle setTitleColor:[iOS6Theme tintColor] forState:UIControlStateNormal];
        // v261103-42: toggle.tag 用 _inlineSections 实际 index（addObject 前），
        // 不用 thinkIdx — 穿插布局后 _inlineSections 含文字段，
        // thinkIdx（思考序号）和数组 index 不对应，点卡片取错 section → 崩溃
        toggle.tag = [_inlineSections count];
        [toggle addTarget:self action:@selector(_toggleInlineThinking:)
            forControlEvents:UIControlEventTouchUpInside];

        // 检查展开状态
        NSString *secKey = [NSString stringWithFormat:@"%@_inline_%ld", message.messageID, (long)thinkIdx];
        BOOL collapsed = ![ChatMessageCell _isThinkingExpanded:secKey];

        // v261103-41: 恢复旧版样式 — “点击展开/收起”文字（无箭头无 emoji）
        NSString *toggleTitle;
        if (collapsed) {
            toggleTitle = [NSString stringWithFormat:@"%@ · 点击展开", title];
        } else {
            toggleTitle = [NSString stringWithFormat:@"%@ · 点击收起", title];
        }
        [toggle setTitle:toggleTitle forState:UIControlStateNormal];
        [cardView addSubview:toggle];

        // 内容 label
        UILabel *contentLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        contentLabel.numberOfLines = 0;
        contentLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:12]];
        contentLabel.textColor = [iOS6Theme secondaryTextColor];
        contentLabel.backgroundColor = [UIColor clearColor];
        contentLabel.text = thinkText;
        contentLabel.hidden = collapsed;
        [cardView addSubview:contentLabel];
        [contentLabel release];

        // 分隔线
        UIView *sep2 = [[UIView alloc] initWithFrame:CGRectZero];
        sep2.backgroundColor = [iOS6Theme hairlineColor];
        sep2.hidden = collapsed;
        [cardView addSubview:sep2];
        [sep2 release];

        [_sectionsContainer addSubview:cardView];

        // 记录 section — v261103-40: 用 NSMutableDictionary（was NSDictionary）
        // _toggleInlineThinking 会 setObject:forKey:@"collapsed" 修改它，
        // immutable dict 调 setObject 会 NSInvalidArgumentException 闪退。
        NSMutableDictionary *sec = [NSMutableDictionary dictionaryWithObjectsAndKeys:
            @"thinking", @"type",
            title, @"title",
            thinkText, @"content",
            cardView, @"view",
            toggle, @"toggle",
            contentLabel, @"label",
            sep2, @"sep",
            [NSNumber numberWithBool:collapsed], @"collapsed",
            borderColor, @"borderColor",
            secKey, @"key",
            nil];
        [_inlineSections addObject:sec];
        thinkIdx++;

        searchStart = endRange.location + endRange.length;
    }

    // v261103-40: 穿插布局 — 不再用 cleanText + _textView
    // 文字段已作为 UILabel 加入 _inlineSections，_textView 隐藏
    self.renderedAttr = nil;
    _textView.hidden = YES;
}

// v261103-33: 穿插思考卡片的 toggle
- (void)_toggleInlineThinking:(UIButton *)sender
{
    NSInteger idx = sender.tag;
    if (!_inlineSections || idx < 0 || idx >= (NSInteger)[_inlineSections count]) return;
    NSMutableDictionary *sec = [_inlineSections objectAtIndex:idx];
    // v261103-42: 防御性 — 确保是 thinking 类型（文字段 type=text 没有 toggle，
    // 但 tag 错位时可能取到文字段 → 没有 key/view/label 等字段 → 各种 nil 崩溃）
    NSString *type = [sec objectForKey:@"type"];
    if (![type isEqualToString:@"thinking"]) return;
    BOOL collapsed = [[sec objectForKey:@"collapsed"] boolValue];
    collapsed = !collapsed;
    [sec setObject:[NSNumber numberWithBool:collapsed] forKey:@"collapsed"];

    UILabel *label = [sec objectForKey:@"label"];
    UIView *sep = [sec objectForKey:@"sep"];
    label.hidden = collapsed;
    sep.hidden = collapsed;

    // v261103-41: 恢复旧版样式 — “点击展开/收起”文字（无箭头无 emoji）
    NSString *title = [sec objectForKey:@"title"];
    NSString *newTitle;
    if (collapsed) {
        newTitle = [NSString stringWithFormat:@"%@ · 点击展开", title];
    } else {
        newTitle = [NSString stringWithFormat:@"%@ · 点击收起", title];
    }
    [sender setTitle:newTitle forState:UIControlStateNormal];

    NSString *secKey = [sec objectForKey:@"key"];
    [self.class _markThinkingExpanded:secKey expanded:!collapsed];

    [self setNeedsLayout];
    UIView *v = self.superview;
    while (v && ![v isKindOfClass:[UITableView class]]) v = v.superview;
    if ([v isKindOfClass:[UITableView class]]) {
        UITableView *tv = (UITableView *)v;
        [tv beginUpdates];
        [tv endUpdates];
    }
}

- (void)_toggleThinkingSegment:(UIButton *)sender
{
    NSInteger idx = sender.tag;
    if (!_thinkingSegments || idx < 0 || idx >= (NSInteger)[_thinkingSegments count]) return;
    NSMutableDictionary *seg = [_thinkingSegments objectAtIndex:idx];
    BOOL collapsed = [[seg objectForKey:@"collapsed"] boolValue];
    collapsed = !collapsed;
    [seg setObject:[NSNumber numberWithBool:collapsed] forKey:@"collapsed"];
    UILabel *label = [seg objectForKey:@"label"];
    UIView *sep = [seg objectForKey:@"sep"];
    label.hidden = collapsed;
    sep.hidden = collapsed;
    // 更新标题
    NSString *text = [seg objectForKey:@"text"];
    NSString *title;
    if (collapsed) {
        title = [NSString stringWithFormat:@"思考 #%ld · 点击展开 — %lu 字",
                 (long)(idx + 1), (unsigned long)text.length];
    } else {
        title = [NSString stringWithFormat:@"思考 #%ld · 点击收起", (long)(idx + 1)];
    }
    [sender setTitle:title forState:UIControlStateNormal];
    // 记录展开状态（key = messageID_index）
    NSString *segKey = [NSString stringWithFormat:@"%@_%ld", _currentMessageKey, (long)idx];
    [self.class _markThinkingExpanded:segKey expanded:!collapsed];
    [self setNeedsLayout];
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

    // v261025-6: if this AI message has a currentVariantIndex pointing at
    // a saved snapshot (i.e. user navigated to an OLD variant), display
    // the snapshot's content + thinking instead of the live values. The
    // live values are preserved in the message's content/thinking for when
    // the user navigates back to the current variant.
    // For user messages or live AI responses, we use message.content/
    // thinking directly.
    NSString *displayedContent = [Message displayedContentForMessage:message];
    NSString *displayedThinking = [Message displayedThinkingForMessage:message];

    // v261025-32: detect error messages (start with ⚠️) → red error bubble.
    BOOL isError = !message.isUser && [displayedContent hasPrefix:@"⚠️"];
    BubbleRole role = message.isUser ? BubbleRoleUser
                      : (isError ? BubbleRoleError : BubbleRoleAssistant);
    _bubble.role = role;
    // v261025-33: AI normal = no bubble (drawBackground=NO).
    // AI error = bubble with no tail + red colors (drawBackground=YES).
    // User = normal bubble (drawBackground=YES).
    _bubble.drawBackground = message.isUser || isError;
    if (isError) {
        // Error bubble: no tail, just a rounded rect.
        _bubble.tailSize = CGSizeMake(0, 0);
    } else {
        _bubble.tailSize = CGSizeMake(12, 6);
    }
    if (!message.isUser) {
        // Tighter text container inset for AI (no bubble padding).
        if ([_textView respondsToSelector:@selector(setTextContainerInset:)]) {
            [_textView performSelector:@selector(setTextContainerInset:)
                             withObject:[NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(4, 4, 4, 4)]];
        }
    } else {
        // User: restore bubble-era text container inset.
        if ([_textView respondsToSelector:@selector(setTextContainerInset:)]) {
            [_textView performSelector:@selector(setTextContainerInset:)
                             withObject:[NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(7, 10, 7, 10)]];
        }
    }

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
    // v261025-6: when showing an OLD variant, we DON'T want to pull from
    // the cache (which would have the LIVE content keyed by messageID +
    // contentLen — different for the variant). Render fresh with the
    // displayed content as the source.
    if (message.currentVariantIndex < 0) {
        // LIVE — use the cached rendered attr (regular path).
        self.renderedAttr = [ChatMessageCell _renderedAttrForMessage:message
                                                                width:textWidth];
    } else {
        // OLD variant — render fresh from displayedContent.
        // Synthesize a temporary Message with the variant's content so
        // the cache key (messageID + contentLen) is unique to this variant.
        Message *tempMsg = [Message messageWithRole:message.role
                                              content:displayedContent ?: @""];
        tempMsg.messageID = [NSString stringWithFormat:@"%@_v%ld",
                             message.messageID, (long)message.currentVariantIndex];
        tempMsg.thinking = displayedThinking;
        self.renderedAttr = [ChatMessageCell _renderedAttrForMessage:tempMsg
                                                                width:textWidth];
    }

    // === Deep thinking block ===
    // v261103-33: 穿插思考卡片重构
    // 检查 _renderedAttr（MarkdownParser 渲染后的 attributed string）里是否有 \x00THINK\x00 标记
    // （标记由 MarkdownParser._appendToolStatus 插入，不在原始 content 里）
    NSString *renderedString = _renderedAttr ? [_renderedAttr string] : @"";
    BOOL hasInlineThinking = [renderedString rangeOfString:@"\x00THINK\x00"].location != NSNotFound;

    if (hasInlineThinking && !message.isUser) {
        // v261103-33: 解析 \x00THINK\x00 标记，创建穿插卡片
        // 用 renderedString（含标记）而不是 displayedContent（不含标记）
        [self _parseInlineThinkingSections:renderedString message:message];
        _thinkingBlock.hidden = YES;
        _sectionsContainer.hidden = NO;
    } else {
        // 旧逻辑 — 没有 :::thinking 标记
        _sectionsContainer.hidden = YES;
        // v261103-40: 重置 _textView.hidden（cell 复用时上次消息可能有穿插思考
        // 设了 hidden=YES，这次普通消息不重置会导致文字不显示）
        _textView.hidden = NO;

    BOOL hasInlineThinkingOld = [displayedContent rangeOfString:@":::thinking"].location != NSNotFound;
    if (displayedThinking.length > 0 && !message.isUser && !hasInlineThinkingOld) {
        _thinkingBlock.hidden = NO;
        BOOL thinkingLive = [ChatMessageCell _isThinkingLive:message];
        // v261103-22: 按 ────────── 分隔符拆分多段思考，每段独立卡片
        NSArray *segments = [displayedThinking componentsSeparatedByString:@"\n\n──────────\n\n"];
        // 清理旧 segment views
        if (_thinkingSegments) {
            for (NSDictionary *seg in _thinkingSegments) {
                UIView *toggle = [seg objectForKey:@"toggle"];
                UIView *label = [seg objectForKey:@"label"];
                UIView *sep = [seg objectForKey:@"sep"];
                [toggle removeFromSuperview]; [label removeFromSuperview]; [sep removeFromSuperview];
            }
            [_thinkingSegments removeAllObjects];
        } else {
            self.thinkingSegments = [NSMutableArray array];
        }
        // 为每段创建独立 toggle + label + sep
        NSInteger segIdx = 0;
        for (NSString *segText in segments) {
            NSString *trimmed = [segText stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length == 0) { segIdx++; continue; }
            BOOL segCollapsed = !thinkingLive;
            // 检查这个 segment 的展开状态（key = messageID_index）
            NSString *segKey = [NSString stringWithFormat:@"%@_%ld", message.messageID, (long)segIdx];
            if ([ChatMessageCell _isThinkingExpanded:segKey]) {
                segCollapsed = NO;
            }
            UIButton *segToggle = [UIButton buttonWithType:UIButtonTypeCustom];
            segToggle.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
            segToggle.contentEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 6);
            segToggle.titleLabel.font = [UIFont boldSystemFontOfSize:[iOS6Theme fontPointSizeForBase:12]];
            [segToggle setTitleColor:[iOS6Theme secondaryTextColor] forState:UIControlStateNormal];
            segToggle.tag = segIdx;
            [segToggle addTarget:self action:@selector(_toggleThinkingSegment:)
                forControlEvents:UIControlEventTouchUpInside];
            NSString *title;
            if (thinkingLive && segIdx == [segments count] - 1) {
                title = @"深度思考中…";
            } else if (segCollapsed) {
                title = [NSString stringWithFormat:@"思考 #%ld · 点击展开 — %lu 字",
                         (long)(segIdx + 1), (unsigned long)trimmed.length];
            } else {
                title = [NSString stringWithFormat:@"思考 #%ld · 点击收起", (long)(segIdx + 1)];
            }
            [segToggle setTitle:title forState:UIControlStateNormal];
            [_thinkingBlock addSubview:segToggle];

            UILabel *segLabel = [[UILabel alloc] initWithFrame:CGRectZero];
            segLabel.numberOfLines = 0;
            segLabel.font = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:12]];
            segLabel.textColor = [iOS6Theme secondaryTextColor];
            segLabel.backgroundColor = [UIColor clearColor];
            segLabel.text = trimmed;
            segLabel.hidden = segCollapsed;
            [_thinkingBlock addSubview:segLabel];
            [segLabel release];

            UIView *segSep = [[UIView alloc] initWithFrame:CGRectZero];
            segSep.backgroundColor = [iOS6Theme hairlineColor];
            segSep.hidden = segCollapsed;
            [_thinkingBlock addSubview:segSep];
            [segSep release];

            NSMutableDictionary *segDict = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                segToggle, @"toggle", segLabel, @"label", segSep, @"sep",
                [NSNumber numberWithBool:segCollapsed], @"collapsed",
                trimmed, @"text", nil];
            [_thinkingSegments addObject:segDict];
            segIdx++;
        }
        // 隐藏旧的单一 toggle/label/sep（v261103-22 之前创建的）
        _thinkingToggle.hidden = YES;
        _thinkingLabel.hidden = YES;
        _thinkingSep.hidden = YES;
    } else {
        // v261103-31: 清空 _thinkingSegments（思考在 content 流里，不需要 _thinkingBlock 卡片）
        if (_thinkingSegments) {
            for (NSDictionary *seg in _thinkingSegments) {
                [[seg objectForKey:@"toggle"] removeFromSuperview];
                [[seg objectForKey:@"label"] removeFromSuperview];
                [[seg objectForKey:@"sep"] removeFromSuperview];
            }
            [_thinkingSegments removeAllObjects];
        }
        _thinkingBlock.hidden = YES;
    }
    } // end else (旧逻辑)

    // === v261025-8: Generated image (生图 result) ===
    // The message carries a local file name; decode off-main and show a
    // big rounded image. content (the prompt) renders as the caption
    // BELOW the image; while the request is in flight content is the
    // "正在生成图片…" placeholder so the bubble reads as a loading state.
    if ([message isImageGenResult]) {
        NSString *absPath = [Message absolutePathForGeneratedImage:message.generatedImagePath];
        _generatedImageView.hidden = NO;
        [ChatMessageCell decodeImageWithFile:absPath
                                          key:message.messageID
                                      callback:^(UIImage *img) {
            // Stale callback check (same as vision thumbnails).
            NSString *currentKey = self->_currentMessageKey;
            if (![currentKey isEqualToString:message.messageID]) return;
            if (img) {
                self->_generatedImageView.image = img;
            } else {
                // File missing (e.g. conversation imported from another
                // device) — gray plate instead of a crash.
                self->_generatedImageView.backgroundColor = [iOS6Theme secondaryTextColor];
            }
            [self setNeedsLayout];
        }];
    } else {
        _generatedImageView.hidden = YES;
        _generatedImageView.image = nil;
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
            initWithString:[NSString stringWithFormat:@"\n%lu 张图片", (unsigned long)[message.images count]]
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

- (void)_genImageTapped
{
    // v261025-8: open the full-screen viewer via the delegate.
    if (_delegate && [_delegate respondsToSelector:
            @selector(chatCellDidTapGeneratedImage:message:)]) {
        [_delegate chatCellDidTapGeneratedImage:self message:_message];
    }
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
    BOOL isAI = !_message.isUser;  // v261025-32: Option ②
    NSString *currentContent = [Message displayedContentForMessage:_message];
    BOOL isErrorBubble = isAI && [currentContent hasPrefix:@"⚠️"];
    BOOL useBubble = _message.isUser || isErrorBubble;  // v261025-33
    CGFloat pad = useBubble ? 8.0f : 0;               // bubble msgs have pad
    CGFloat bubbleInnerHPad = 10.0f;
    CGFloat bubbleInnerVPad = useBubble ? 5.0f : 4.0f;
    CGFloat verticalPad = 3.0f;
    CGFloat maxBubbleWidth = useBubble ? (self.bounds.size.width - 2 * pad)
                                       : self.bounds.size.width;
    if (useBubble) maxBubbleWidth = MIN(maxBubbleWidth, 280.0f);

    CGFloat availTextWidth = useBubble
        ? [ChatMessageCell unifiedTextWidthForOuterWidth:self.bounds.size.width]
        : [ChatMessageCell aiTextWidthForOuterWidth:self.bounds.size.width];
    if (availTextWidth < 60) availTextWidth = 60;

    // === Thinking block sizing ===
    CGFloat thinkingH = 0;
    if (!_thinkingBlock.hidden) {
        // v261103-22: 多段思考卡片垂直堆叠布局
        if (_thinkingSegments && [_thinkingSegments count] > 0) {
            CGFloat yPos = 3;
            CGFloat thinkingToggleH = 22;
            for (NSInteger i = 0; i < (NSInteger)[_thinkingSegments count]; i++) {
                NSDictionary *seg = [_thinkingSegments objectAtIndex:i];
                UIButton *toggle = [seg objectForKey:@"toggle"];
                UILabel *label = [seg objectForKey:@"label"];
                UIView *sep = [seg objectForKey:@"sep"];
                BOOL collapsed = [[seg objectForKey:@"collapsed"] boolValue];
                toggle.frame = CGRectMake(4, yPos, availTextWidth, thinkingToggleH);
                yPos += thinkingToggleH;
                CGFloat labelH = 0;
                if (!collapsed && label.text.length > 0) {
                    NSAttributedString *attr = [[[NSAttributedString alloc]
                        initWithString:label.text
                            attributes:@{NSFontAttributeName: label.font}] autorelease];
                    CGSize sz = [attr boundingRectWithSize:CGSizeMake(availTextWidth - 4, CGFLOAT_MAX)
                                                   options:(NSStringDrawingUsesLineFragmentOrigin |
                                                            NSStringDrawingUsesFontLeading)
                                                   context:nil].size;
                    labelH = ceilf(sz.height) + 6;
                }
                sep.frame = CGRectMake(6, yPos, availTextWidth - 12, 1);
                label.frame = CGRectMake(6, yPos + 2, availTextWidth - 4, labelH);
                yPos += labelH + 4;
            }
            thinkingH = yPos + 3;
        } else {
            // 旧逻辑（单卡片）— 兼容回退
            CGFloat thinkingToggleH = 22;
            CGFloat thinkingLabelH = 0;
            if (!_thinkingLabel.hidden && _thinkingLabel.text.length > 0) {
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
    }

    // === Main text sizing ===
    // v261103-40: _textView 隐藏时（穿插布局），textRect 高度 0
    CGRect textRect = CGRectZero;
    if (_renderedAttr && !_textView.hidden) {
        textRect = [_renderedAttr boundingRectWithSize:CGSizeMake(availTextWidth, CGFLOAT_MAX)
                                                options:(NSStringDrawingUsesLineFragmentOrigin |
                                                         NSStringDrawingUsesFontLeading)
                                                context:nil];
    }
    if (!_textView.hidden && textRect.size.height < 20) textRect.size.height = 20;

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

    // === v261025-8: generated image sizing ===
    // Square estimate (we always request 1024x1024); true aspect ratio
    // applied once the image is decoded (AspectFit inside the square
    // frame keeps non-square results unclipped).
    CGFloat genImgH = 0;
    BOOL isGenImage = [_message isImageGenResult];
    if (isGenImage) {
        CGFloat gimgW = maxBubbleWidth - 8;
        genImgH = gimgW;
        UIImage *gimg = _generatedImageView.image;
        if (gimg && gimg.size.width > 0 && gimg.size.height > 0) {
            genImgH = floorf(gimgW * gimg.size.height / gimg.size.width);
        }
    }

    BOOL thinkingLive = [ChatMessageCell _isThinkingLive:_message];
    CGFloat tailHeight = useBubble ? 6.0f : 0;  // v261025-33: no tail for non-bubble AI
    // v261102-1: AI safety 8→24. boundingRectWithSize regularly UNDERESTIMATES
    // the real UITextView layout by one line (~17pt for a 15pt font). The old
    // 8pt slack was entirely consumed by the (4,4,4,4) textContainerInset
    // → any underestimate clipped the last line. 24pt leaves 16pt of headroom
    // past the inset, comfortably absorbing a 1-line drift.
    // v261103-38: safety 20/24 → 32/36 — 用户报最后一行被遮，boundingRectWithSize
    // 低估超过 20pt 时仍遮。32/36 多吸收一行（~17pt）。
    // v261103-40: 32/36 太大导致生成后大空白，回退到 26/30（折中）
    // v261103-42: _textView.hidden（穿插布局）时 safety/insetV=0，避免大空白
    CGFloat safety = _textView.hidden ? 0 : (useBubble ? 26 : 30);
    CGFloat insetV = _textView.hidden ? 0 : (useBubble ? 14 : 8);
    CGFloat bubbleWidth;
    if (!useBubble) {
        bubbleWidth = self.bounds.size.width;  // AI: full width
    } else if (isGenImage) {
        bubbleWidth = maxBubbleWidth;
    } else if (thinkingLive) {
        bubbleWidth = maxBubbleWidth;
    } else {
        bubbleWidth = MAX(textRect.size.width + 38, 60);
        bubbleWidth = MIN(bubbleWidth, maxBubbleWidth);
    }
    // v261103-33: 如果有穿插思考卡片，加 sections 高度
    CGFloat inlineSectionsH = 0;
    if (_inlineSections && [_inlineSections count] > 0) {
        CGFloat toggleH = 22;
        for (NSInteger i = 0; i < (NSInteger)[_inlineSections count]; i++) {
            NSDictionary *sec = [_inlineSections objectAtIndex:i];
            BOOL collapsed = [[sec objectForKey:@"collapsed"] boolValue];
            CGFloat cardH = toggleH + 4;
            if (!collapsed) {
                NSString *thinkText = [sec objectForKey:@"content"];
                if (thinkText.length > 0) {
                    UIFont *thinkFont = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:12]];
                    NSAttributedString *attr = [[[NSAttributedString alloc]
                        initWithString:thinkText
                            attributes:@{NSFontAttributeName: thinkFont}] autorelease];
                    CGSize sz = [attr boundingRectWithSize:CGSizeMake(availTextWidth - 8, CGFLOAT_MAX)
                                                   options:(NSStringDrawingUsesLineFragmentOrigin |
                                                            NSStringDrawingUsesFontLeading)
                                                   context:nil].size;
                    cardH += ceilf(sz.height) + 6 + 4;
                }
            }
            inlineSectionsH += cardH + 4;
        }
    }
    CGFloat bubbleHeight = textRect.size.height + insetV + 2 * bubbleInnerVPad + tailHeight + safety
                          + thinkingH + imagesH + genImgH + inlineSectionsH;
    if (bubbleHeight < 40) bubbleHeight = 40;

    CGFloat bubbleX;
    if (!useBubble) {
        bubbleX = 0;  // v261025-33: AI full width
    } else if (_message.isUser) {
        bubbleX = self.bounds.size.width - bubbleWidth - pad;
    } else if (isErrorBubble) {
        // v261103-1: error bubble — center horizontally (was left-aligned
        // like a normal AI message). Centered reads as "system notice"
        // rather than "AI reply", and visually distinguishes errors from
        // regular chat content. Cap at the bubble max width so very long
        // errors don't overflow.
        bubbleX = (self.bounds.size.width - bubbleWidth) / 2.0f;
        if (bubbleX < pad) bubbleX = pad;
    } else {
        bubbleX = pad;  // error bubble fallback (shouldn't reach)
    }
    CGFloat bubbleY = verticalPad;
    CGRect bubbleRect = CGRectMake(bubbleX, bubbleY, bubbleWidth, bubbleHeight);
    _bubble.frame = bubbleRect;

    // v261025-33: content offset — bubble msgs start at x=4,
    // non-bubble AI starts at x=8 (left margin).
    CGFloat contentX = useBubble ? 4 : 8;
    CGFloat contentW = useBubble ? (bubbleWidth - 8) : (bubbleWidth - 12);

    // Place thinking block at top of bubble.
    CGFloat yOffset = 4;
    if (!_sectionsContainer.hidden) {
        // v261103-40: 穿插布局 — 遍历 _inlineSections 按 type 堆叠
        // type=text: UILabel 文字段
        // type=thinking: 可折叠思考卡片
        CGFloat sectionY = 0;
        CGFloat toggleH = 22;
        for (NSInteger i = 0; i < (NSInteger)[_inlineSections count]; i++) {
            NSDictionary *sec = [_inlineSections objectAtIndex:i];
            NSString *type = [sec objectForKey:@"type"];
            
            if ([type isEqualToString:@"text"]) {
                // 文字段 UILabel
                UILabel *textLabel = [sec objectForKey:@"label"];
                NSAttributedString *textAttr = textLabel.attributedText;
                if (textAttr && textAttr.length > 0) {
                    CGSize sz = [textAttr boundingRectWithSize:CGSizeMake(contentW - 4, CGFLOAT_MAX)
                                                       options:(NSStringDrawingUsesLineFragmentOrigin |
                                                                NSStringDrawingUsesFontLeading)
                                                       context:nil].size;
                    CGFloat textH = ceilf(sz.height) + 4;
                    textLabel.frame = CGRectMake(2, sectionY, contentW - 4, textH);
                    sectionY += textH + 4;
                }
            } else {
                // thinking 卡片
                UIView *cardView = [sec objectForKey:@"view"];
                UIButton *toggle = [sec objectForKey:@"toggle"];
                UILabel *label = [sec objectForKey:@"label"];
                UIView *sepView = [sec objectForKey:@"sep"];
                BOOL collapsed = [[sec objectForKey:@"collapsed"] boolValue];

                toggle.frame = CGRectMake(2, 2, contentW - 4, toggleH);
                CGFloat cardH = toggleH + 4;

                if (!collapsed) {
                    NSString *thinkText = [sec objectForKey:@"content"];
                    if (thinkText.length > 0) {
                        NSAttributedString *attr = [[[NSAttributedString alloc]
                            initWithString:thinkText
                                attributes:@{NSFontAttributeName: label.font}] autorelease];
                        CGSize sz = [attr boundingRectWithSize:CGSizeMake(contentW - 8, CGFLOAT_MAX)
                                                       options:(NSStringDrawingUsesLineFragmentOrigin |
                                                                NSStringDrawingUsesFontLeading)
                                                       context:nil].size;
                        CGFloat labelH = ceilf(sz.height) + 6;
                        label.frame = CGRectMake(6, toggleH + 2, contentW - 8, labelH);
                        sepView.frame = CGRectMake(6, toggleH, contentW - 12, 1);
                        cardH += labelH + 4;
                    }
                }

                cardView.frame = CGRectMake(0, sectionY, contentW, cardH);
                sectionY += cardH + 4;
            }
        }

        CGFloat sectionsH = sectionY;
        _sectionsContainer.frame = CGRectMake(contentX, yOffset, contentW, sectionsH);
        yOffset += sectionsH + 4;
    } else if (!_thinkingBlock.hidden) {
        _thinkingBlock.frame = CGRectMake(contentX, yOffset, contentW, thinkingH);
        yOffset += thinkingH + 4;
    }
    // Text view below thinking block. Leave room for the tail at the bottom
    // (tailHeight + 4px safety) so text isn't clipped.
    // v261025-8: on 生图 messages the image sits at the top of the bubble
    // and the caption (prompt) flows below it.
    if (isGenImage) {
        CGFloat genImgW = isAI ? MIN(contentW, 272) : (bubbleWidth - 8);
        _generatedImageView.frame = CGRectMake(contentX, yOffset,
                                                genImgW, genImgH);
        yOffset += genImgH + 6;
    } else {
        _generatedImageView.hidden = YES;
    }
    // v261025-33: text height = bubbleHeight - consumed - bottom reserve.
    // insetV is already added to bubbleHeight (matches heightForMessage),
    // so the text frame now includes room for the textContainerInset.
    // v261103-42: _textView.hidden 时不占空间（textH=0）
    CGFloat textH = 0;
    if (!_textView.hidden) {
        textH = bubbleHeight - yOffset - imagesH - bottomReserve;
        if (textH < 20) textH = 20;
    }
    _textView.frame = CGRectMake(contentX, yOffset, contentW, textH);

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
    // v261025-6: layout now includes the variant pager (‹ 1/N ›) on the
    // right side, and the edit button on user cells.
    BOOL showAIButtons = !_message.isUser
                         && [Message displayedContentForMessage:_message].length > 0;
    BOOL showUserEditButton = _message.isUser
                              && _message.content.length > 0;
    BOOL showVariantPager = !_message.isUser
                            && [_message.variants isKindOfClass:[NSArray class]]
                            && [_message.variants count] > 0;
    _regenerateButton.hidden = !showAIButtons;
    _clipboardButton.hidden = !showAIButtons;
    _editButton.hidden = !showUserEditButton;
    _variantPrevButton.hidden = !showVariantPager;
    _variantNextButton.hidden = !showVariantPager;
    _variantIndexLabel.hidden = !showVariantPager;
    if (showVariantPager) {
        // "1/N" — currentVariantIndex = -1 means "the live (latest) variant",
        // displayed as N+1 out of N+1. Otherwise index+1 out of (variants.count + 1).
        NSInteger total = (NSInteger)[_message.variants count] + 1;
        NSInteger cur = (_message.currentVariantIndex < 0)
                        ? total
                        : (_message.currentVariantIndex + 1);
        _variantIndexLabel.text = [NSString stringWithFormat:@"%ld/%ld",
                                    (long)cur, (long)total];
    }
    if (showAIButtons) {
        CGFloat btnY = bubbleY + bubbleHeight + 2;
        CGFloat btnW = 36, btnH = 24, btnGap = 4;
        // Left-align buttons under the bubble.
        CGFloat regenX = bubbleX;
        _regenerateButton.frame = CGRectMake(regenX, btnY, btnW, btnH);
        _clipboardButton.frame = CGRectMake(regenX + btnW + btnGap, btnY, btnW, btnH);
        // v261025-6: variant pager to the right of clipboard button.
        if (showVariantPager) {
            CGFloat pagerX = regenX + 2 * (btnW + btnGap);
            CGFloat arrowW = 28, labelW = 50;
            _variantPrevButton.frame = CGRectMake(pagerX, btnY, arrowW, btnH);
            _variantIndexLabel.frame = CGRectMake(pagerX + arrowW + 2, btnY, labelW, btnH);
            _variantNextButton.frame = CGRectMake(pagerX + arrowW + labelW + 4, btnY, arrowW, btnH);
        }
    }
    if (showUserEditButton) {
        // v261025-6: edit button on the right side of the user bubble
        // (mirrors how iOS Messages shows a "..." on the user's bubble).
        CGFloat btnY = bubbleY + bubbleHeight + 2;
        CGFloat btnW = 36, btnH = 24;
        // For user messages, bubbleX is on the right; place edit button
        // under the bubble's left edge (so it doesn't run off-screen).
        CGFloat editX = bubbleX;
        _editButton.frame = CGRectMake(editX, btnY, btnW, btnH);
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
    // v261025-6: include currentVariantIndex in the key so switching
    // variants re-queries the height (different content length per variant).
    // v261103-36: 字重叠根因 C — 加 fast 标志。流式时 fast=YES 跳过 emoji-font
    // pass，emoji 用 Helvetica 字体显示成 □（窄）；完成时 fast=NO 跑 emoji-font
    // + 插零宽空格，emoji 用 AppleColorEmoji（宽）+ 多一个隐形字符 → 同一行
    // 文字流式时和完成时占的宽度不一样，行数可能差 1。heightCache 不带 fast
    // 标志会返回流式版（□）的高度，但 cell 实际渲染是完成版（彩色 emoji）→
    // 高度 < 实际内容 → 文字溢出 cell frame → 重叠到下一行。
    BOOL fast = [ChatMessageCell isMessageStreaming:message.messageID];
    NSString *cacheKey = [NSString stringWithFormat:@"%@_%.0f_%lu_%lu_%ld_%@",
                          message.messageID, (double)width,
                          (unsigned long)message.content.length,
                          (unsigned long)message.thinking.length,
                          (long)message.currentVariantIndex,
                          fast ? @"F" : @"S"];
    NSNumber *cached = [gHeightCache objectForKey:cacheKey];
    if (cached) {
        return [cached floatValue];
    }

    CGFloat pad = 8.0f;               // v261025-11: 12->8 (sync with _layoutInternal)
    CGFloat bubbleInnerVPad = 5.0f;   // v261025-11: 7->5
    CGFloat verticalPad = 3.0f;       // v261025-11: 6->3
    // v261024-16: unified width — MUST match _applyMessageInternal and
    // _layoutInternal so the row height reflects the rendered wrap.
    CGFloat availTextWidth = (message.isUser || [message.content hasPrefix:@"⚠️"])
        ? [ChatMessageCell unifiedTextWidthForOuterWidth:width]
        : [ChatMessageCell aiTextWidthForOuterWidth:width];  // v261025-33
    if (availTextWidth < 60) availTextWidth = 60;

    // v261025-6: if we're showing an OLD variant, use a temp Message
    // built from the variant's content+thinking (mirroring what
    // _applyMessageInternal: does) so the rendered attr matches the
    // displayed bubble content — otherwise the row height would be
    // measured against the LIVE content while the cell shows a variant.
    Message *msgForRender = message;
    Message *tempMsg = nil;  // retained only for the variant case
    if (message.currentVariantIndex >= 0) {
        NSString *dispContent = [Message displayedContentForMessage:message];
        NSString *dispThinking = [Message displayedThinkingForMessage:message];
        tempMsg = [[Message messageWithRole:message.role
                                      content:dispContent ?: @""] retain];
        tempMsg.messageID = [NSString stringWithFormat:@"%@_v%ld",
                             message.messageID, (long)message.currentVariantIndex];
        tempMsg.thinking = dispThinking;
        msgForRender = tempMsg;
    }

    // Use the SHARED rendered-attr cache — saves a MarkdownParser run
    // per streaming chunk (which was the perf killer for long AI replies).
    // The cache invalidates automatically when content.length changes.
    NSAttributedString *attr = [ChatMessageCell _renderedAttrForMessage:msgForRender
                                                                  width:availTextWidth];
    [tempMsg release];   // matched by the retain above (only in variant case)
    CGRect textRect = [attr boundingRectWithSize:CGSizeMake(availTextWidth, CGFLOAT_MAX)
                                         options:(NSStringDrawingUsesLineFragmentOrigin |
                                                  NSStringDrawingUsesFontLeading)
                                         context:nil];

    // Thinking block height. Default: collapsed (just the toggle header).
    // If the user has expanded this message, OR the AI is still actively
    // thinking (streaming reasoning, no final answer yet), compute the
    // FULL height so the bubble grows with the reasoning text.
    // v261025-6: use displayed thinking (variant-aware).
    NSString *dispThinkingForCalc = [Message displayedThinkingForMessage:message];
    // v261103-31: 如果 content 里有 :::thinking（交错布局），不计算 _thinkingBlock 高度
    // （思考已在 content 流里，_thinkingBlock 隐藏）
    NSString *dispContentForCalc = [Message displayedContentForMessage:message];
    // v261103-33: 检查渲染后的 attributed string 里是否有 \x00THINK\x00 标记
    // （标记由 MarkdownParser 插入，不在原始 content 里）
    NSAttributedString *renderedAttrForCheck = [ChatMessageCell _renderedAttrForMessage:msgForRender width:availTextWidth];
    NSString *renderedStrForCheck = renderedAttrForCheck ? [renderedAttrForCheck string] : @"";
    BOOL hasInlineThinkMarker = [renderedStrForCheck rangeOfString:@"\x00THINK\x00"].location != NSNotFound;
    BOOL hasInlineThinkingForCalc = [dispContentForCalc rangeOfString:@":::thinking"].location != NSNotFound || hasInlineThinkMarker;

    // v261103-40: 穿插布局高度计算 — 文字段 + 卡片交替
    // 文字段用 MarkdownParser 渲染算高度，卡片按折叠状态算高度
    CGFloat inlineThinkH = 0;
    if (hasInlineThinkMarker && !message.isUser) {
        NSString *thinkTag = @"\x00THINK\x00";
        NSString *endTag = @"\x00END\x00";
        NSString *thinkSep = @"\x01";
        NSUInteger searchStart = 0;
        CGFloat toggleH = 22;
        NSInteger thinkIdx = 0;
        UIFont *baseFont = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:15]];
        while (searchStart < [dispContentForCalc length]) {
            NSRange thinkRange = [dispContentForCalc rangeOfString:thinkTag
                                                           options:0
                                                             range:NSMakeRange(searchStart, [dispContentForCalc length] - searchStart)];
            if (thinkRange.location == NSNotFound) {
                // v261103-40: 剩余文字段 — 算高度
                NSString *remaining = [dispContentForCalc substringFromIndex:searchStart];
                if (remaining.length > 0) {
                    NSAttributedString *textAttr = [MarkdownParser attributedStringFromMarkdown:remaining
                                                                                       baseFont:baseFont
                                                                                          width:availTextWidth];
                    CGSize sz = [textAttr boundingRectWithSize:CGSizeMake(availTextWidth - 4, CGFLOAT_MAX)
                                                       options:(NSStringDrawingUsesLineFragmentOrigin |
                                                                NSStringDrawingUsesFontLeading)
                                                       context:nil].size;
                    inlineThinkH += ceilf(sz.height) + 4;
                }
                break;
            }
            // v261103-40: 标记前的文字段 — 算高度
            if (thinkRange.location > searchStart) {
                NSString *textBefore = [dispContentForCalc substringWithRange:NSMakeRange(searchStart, thinkRange.location - searchStart)];
                if (textBefore.length > 0) {
                    NSAttributedString *textAttr = [MarkdownParser attributedStringFromMarkdown:textBefore
                                                                                       baseFont:baseFont
                                                                                          width:availTextWidth];
                    CGSize sz = [textAttr boundingRectWithSize:CGSizeMake(availTextWidth - 4, CGFLOAT_MAX)
                                                       options:(NSStringDrawingUsesLineFragmentOrigin |
                                                                NSStringDrawingUsesFontLeading)
                                                       context:nil].size;
                    inlineThinkH += ceilf(sz.height) + 4;
                }
            }
            NSUInteger endSearchStart = thinkRange.location + thinkRange.length;
            NSRange endRange = [dispContentForCalc rangeOfString:endTag
                                                          options:0
                                                            range:NSMakeRange(endSearchStart, [dispContentForCalc length] - endSearchStart)];
            if (endRange.location == NSNotFound) break;
            NSString *thinkContent = [dispContentForCalc substringWithRange:NSMakeRange(endSearchStart, endRange.location - endSearchStart)];
            NSRange sepRange = [thinkContent rangeOfString:thinkSep];
            NSString *thinkText = sepRange.location != NSNotFound ? [thinkContent substringFromIndex:sepRange.location + sepRange.length] : thinkContent;

            // 检查展开状态
            NSString *secKey = [NSString stringWithFormat:@"%@_inline_%ld", message.messageID, (long)thinkIdx];
            BOOL collapsed = ![self _isThinkingExpanded:secKey];

            CGFloat cardH = toggleH + 4;
            if (!collapsed && thinkText.length > 0) {
                UIFont *thinkFont = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:12]];
                NSAttributedString *attr = [[[NSAttributedString alloc]
                    initWithString:thinkText
                        attributes:@{NSFontAttributeName: thinkFont}] autorelease];
                CGSize sz = [attr boundingRectWithSize:CGSizeMake(availTextWidth - 8, CGFLOAT_MAX)
                                               options:(NSStringDrawingUsesLineFragmentOrigin |
                                                        NSStringDrawingUsesFontLeading)
                                               context:nil].size;
                cardH += ceilf(sz.height) + 6 + 4;
            }
            inlineThinkH += cardH + 4;
            thinkIdx++;
            searchStart = endRange.location + endRange.length;
        }
        // v261103-40: 有穿插思考时，_textView 隐藏，textRect 高度归零
        // （文字高度已算进 inlineThinkH）
        textRect.size.height = 0;
    }

    CGFloat thinkingH = 0;
    if (dispThinkingForCalc.length > 0 && !message.isUser && !hasInlineThinkingForCalc) {
        // v261103-28: 多段思考卡片高度计算 — 按分隔符拆分，每段独立计算
        BOOL thinkingLive = [self _isThinkingLive:message];
        NSArray *segments = [dispThinkingForCalc componentsSeparatedByString:@"\n\n──────────\n\n"];
        CGFloat thinkingToggleH = 22;
        CGFloat yPos = 3;
        UIFont *thinkFont = [UIFont systemFontOfSize:[iOS6Theme fontPointSizeForBase:12]];
        CGFloat availW = availTextWidth - 4;
        if (availW < 50) availW = 50;

        NSInteger segIdx = 0;
        for (NSString *segText in segments) {
            NSString *trimmed = [segText stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length == 0) { segIdx++; continue; }
            // toggle 高度
            yPos += thinkingToggleH;
            // 检查这个 segment 是否展开
            NSString *segKey = [NSString stringWithFormat:@"%@_%ld", message.messageID, (long)segIdx];
            BOOL segExpanded = [self _isThinkingExpanded:segKey] || thinkingLive;
            if (segExpanded) {
                NSAttributedString *segAttr = [[[NSAttributedString alloc]
                    initWithString:trimmed
                        attributes:@{NSFontAttributeName: thinkFont}] autorelease];
                CGRect segRect = [segAttr boundingRectWithSize:CGSizeMake(availW, CGFLOAT_MAX)
                                                        options:(NSStringDrawingUsesLineFragmentOrigin |
                                                                 NSStringDrawingUsesFontLeading)
                                                        context:nil];
                yPos += ceilf(segRect.size.height) + 6 + 4;
            } else {
                yPos += 4;  // 折叠时空隙
            }
            segIdx++;
        }
        thinkingH = yPos + 3;
    }

    // Images section.
    CGFloat imagesH = 0;
    if (message.images && [message.images count] > 0) {
        imagesH = 80 + 6;
    }

    // === v261025-8: generated-image messages ===
    // Square image (we request 1024x1024) + caption + action buttons.
    // Mirrors _layoutInternal's math exactly.
    if ([message isImageGenResult]) {
        CGFloat maxBubbleW = width - 2 * pad;
        maxBubbleW = MIN(maxBubbleW, 280.0f);
        CGFloat gimgW = maxBubbleW - 8;
        CGFloat genImgH = gimgW;   // square estimate (AspectFit if not)
        CGFloat captionH = textRect.size.height;
        if (captionH < 20) captionH = 20;
        CGFloat genBubbleHeight = genImgH + captionH + 2 * bubbleInnerVPad + 6 + 20;
        CGFloat genResult = genBubbleHeight + 2 * verticalPad + 26;  // buttons
        if (genResult < 50) genResult = 50;
        [gHeightCache setObject:[NSNumber numberWithFloat:genResult] forKey:cacheKey];
        return genResult;
    }

    // Match layoutSubviews: text + vpad + tail(6) + safety(12) + thinking + images.
    // Plus 2*verticalPad for cell padding.
    // Plus action buttons height (24+2=26) for AI assistant messages AND
    // user messages (both have buttons under the bubble now: AI has
    // regenerate/copy/variant-pager; user has edit).
    // v261025-6: user messages now have an edit button, so they need
    // the same 26pt action-button allowance as AI messages.
    BOOL hasActionButtons = (message.content.length > 0);  // both roles
    CGFloat buttonH = hasActionButtons ? 26 : 0;
    BOOL useBubble = message.isUser || [message.content hasPrefix:@"⚠️"];
    // v261025-33: CRITICAL — the UITextView's textContainerInset adds
    // vertical space INSIDE the text view that boundingRectWithSize does
    // NOT measure. AI inset=(4,4,4,4) → +8pt; user inset=(7,10,7,10) → +14pt.
    // The old formula omitted this → text frame 8-14pt shorter than needed
    // → last line ALWAYS clipped. Now we add it to the height.
    // v261102-1: AI safety 8→24 (sync with _layoutInternal) — see comment there.
    // v261103-42: 有穿插思考时 _textView 隐藏，safety/insetV=0（同 _layoutInternal）
    BOOL hasInlineLayout = hasInlineThinkMarker && !message.isUser;
    CGFloat insetV = hasInlineLayout ? 0 : (useBubble ? 14 : 8);
    CGFloat tailH = useBubble ? 6 : 0;
    CGFloat vPad = useBubble ? 5 : 4;
    // v261103-38: safety 20/24 → 32/36（与 _layoutInternal 同步，吸收 boundingRectWithSize 低估）
    // v261103-40: 32/36 太大导致空白，回退到 26/30
    // v261103-42: 有穿插布局时 safety=0
    CGFloat safety = hasInlineLayout ? 0 : (useBubble ? 26 : 30);
    CGFloat bubbleHeight = textRect.size.height + insetV + 2 * vPad + tailH + safety
                          + thinkingH + imagesH + inlineThinkH;
    CGFloat result = bubbleHeight + 2 * verticalPad + buttonH;
    if (result < 50) result = 50;

    [gHeightCache setObject:[NSNumber numberWithFloat:result] forKey:cacheKey];
    return result;
}

- (void)dealloc
{
    // v261025-5: snapshot-then-nil pattern across the WHOLE dealloc.
    // The user-reported -[ChatMessageCell dealloc +758] / -[ChatBubbleView
    // dealloc +210] SIGSEGV family was triggered by UIKit's subview
    // teardown (during super.dealloc) hitting a CGColor / UIColor that had
    // already been released earlier in this same dealloc pass — QuartzCore
    // then called CFRelease on a dangling pointer → crash inside
    // _CFAutoreleasePoolPop. Snapshotting to locals + clearing ivars first
    // guarantees no double-release, and means a subview-teardown callback
    // fired mid-dealloc reads nil ivars instead of dangling ones.
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    // Snapshot all ivars to locals + clear ivars FIRST so any re-entrant
    // access (e.g. a subview's dealloc calling back into the cell) reads
    // nil ivars instead of dangling pointers.
    UIColor *tbBg = _thinkingBgUIColor;
    UIColor *tbBd = _thinkingBorderUIColor;
    UIColor *tbSp = _thinkingSepUIColor;
    _thinkingBgUIColor = nil;
    _thinkingBorderUIColor = nil;
    _thinkingSepUIColor = nil;

    UIView *bubble = _bubble;              _bubble = nil;
    UITextView *tv = _textView;             _textView = nil;
    Message *msg = _message;                _message = nil;
    NSAttributedString *attr = _renderedAttr; _renderedAttr = nil;
    UIView *tb = _thinkingBlock;            _thinkingBlock = nil;
    UIButton *tt = _thinkingToggle;         _thinkingToggle = nil;
    UILabel *tl = _thinkingLabel;           _thinkingLabel = nil;
    UIView *ts = _thinkingSep;              _thinkingSep = nil;
    // v261103-22: 清理多段思考卡片
    NSMutableArray *tsegs = _thinkingSegments; _thinkingSegments = nil;
    // v261103-33: 清理穿插思考卡片
    NSMutableArray *inlSecs = _inlineSections; _inlineSections = nil;
    UIView *secCont = _sectionsContainer; _sectionsContainer = nil;
    NSMutableArray *ivs = _imageViews;      _imageViews = nil;
    NSString *cmk = _currentMessageKey;     _currentMessageKey = nil;
    UIButton *rb = _regenerateButton;       _regenerateButton = nil;
    UIButton *cb = _clipboardButton;        _clipboardButton = nil;
    // v261025-6: new buttons + label.
    UIButton *eb = _editButton;             _editButton = nil;
    UIButton *vpb = _variantPrevButton;     _variantPrevButton = nil;
    UIButton *vnb = _variantNextButton;     _variantNextButton = nil;
    UILabel *vil = _variantIndexLabel;      _variantIndexLabel = nil;
    // v261025-8: 生图 result view.
    UIImageView *giv = _generatedImageView; _generatedImageView = nil;

    // Release the VIEWS first (so each view's layer.dealloc can do its
    // CGColorRelease cleanly), THEN release the retained UIColor ivars
    // that backed those CGColors. Order matters: dropping the UIColor
    // retain first would free the CGColor and leave the layer holding a
    // dangling ref → SIGSEGV in QuartzCore. The layer's CGColorRelease
    // brings RC 2→1 (we still hold one), then our release 1→0.
    [bubble release];
    [tv release];
    [msg release];
    [attr release];
    [tb release];
    [tt release];
    [tl release];
    [ts release];
    [tsegs release];   // v261103-22: 多段思考卡片
    [inlSecs release]; // v261103-33: 穿插思考卡片
    [secCont release]; // v261103-33: sectionsContainer
    [ivs release];
    [cmk release];
    [rb release];
    [cb release];
    // v261025-6: new buttons + label.
    [eb release];
    [vpb release];
    [vnb release];
    [vil release];
    // v261025-8: 生图 result view (subview of bubble — released BEFORE
    // the UIColors, same ordering rule).
    [giv release];

    [tbBg release];
    [tbBd release];
    [tbSp release];
    // v261025-32: accent line + color.
    [_accentLine release]; _accentLine = nil;
    [_accentLineColor release]; _accentLineColor = nil;

    [super dealloc];
}

@end

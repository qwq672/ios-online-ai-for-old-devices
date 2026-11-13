//
//  ChatBubbleView.m
//  iOS6AIChat
//

#import "ChatBubbleView.h"
#import "iOS6Theme.h"

@interface ChatBubbleView ()
@property (nonatomic, retain) UIColor *fillColor;
@property (nonatomic, retain) UIColor *borderColor;
@property (nonatomic, retain) UIColor *shadowColor;
@end

@implementation ChatBubbleView

@synthesize role=_role, cornerRadius=_cornerRadius, tailSize=_tailSize, drawBackground=_drawBackground;
@synthesize documentPanel=_documentPanel;
@synthesize fillColor=_fillColor, borderColor=_borderColor, shadowColor=_shadowColor;

- (id)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor clearColor];
        _cornerRadius = 14.0f;
        _tailSize = CGSizeMake(12.0f, 6.0f);
        _role = BubbleRoleUser;
        _drawBackground = YES; // default: draw bubble background
        _documentPanel = NO;
        [self _applyRoleColors];
    }
    return self;
}

- (void)setDocumentPanel:(BOOL)documentPanel
{
    if (_documentPanel == documentPanel) return;
    _documentPanel = documentPanel;
    [self setNeedsDisplay];
}

- (void)setCornerRadius:(CGFloat)cornerRadius
{
    if (_cornerRadius == cornerRadius) return;
    _cornerRadius = cornerRadius;
    [self setNeedsDisplay];
}

- (void)setRole:(BubbleRole)role
{
    _role = role;
    [self _applyRoleColors];
    [self setNeedsDisplay];
}

- (void)_applyRoleColors
{
    // v261025-5: snapshot-and-nil pattern — release old colors, set ivars
    // to nil BEFORE the new retain runs, so a mid-call failure (rare but
    // possible under memory pressure) leaves the ivars in a clean state
    // instead of holding a dangling pointer. The user-reported
    // -[ChatBubbleView dealloc +210] crash family was triggered by exactly
    // this: an early return between release and re-assign left _shadowColor
    // dangling, and the eventual dealloc tried to release it again.
    UIColor *oldFill = [_fillColor retain];
    UIColor *oldBorder = [_borderColor retain];
    UIColor *oldShadow = [_shadowColor retain];
    [_fillColor release];
    [_borderColor release];
    [_shadowColor release];
    _fillColor = nil;
    _borderColor = nil;
    _shadowColor = nil;
    if (_role == BubbleRoleUser) {
        _fillColor = [[iOS6Theme bubbleUserColor] retain];
        _borderColor = [[iOS6Theme bubbleUserBorderColor] retain];
    } else if (_role == BubbleRoleError) {
        // v261025-32: red-tinted error bubble — distinct from normal AI.
        // v261103-1: dark-mode aware — light mode keeps the warm pink tint,
        // dark mode uses a deep red on charcoal so the error reads as
        // "danger" without blowing out the eye in low-light.
        if ([iOS6Theme isDarkMode]) {
            _fillColor = [[UIColor colorWithRed:0.22f green:0.10f blue:0.10f alpha:1.0f] retain];
            _borderColor = [[UIColor colorWithRed:0.70f green:0.25f blue:0.25f alpha:0.85f] retain];
        } else {
            _fillColor = [[UIColor colorWithRed:0.96f green:0.92f blue:0.92f alpha:1.0f] retain];
            _borderColor = [[UIColor colorWithRed:0.85f green:0.30f blue:0.30f alpha:0.6f] retain];
        }
    } else {
        // iOS 6: white glass card; iOS 7+: flat grouped surface.
        _fillColor = [[iOS6Theme assistantPanelColor] retain];
        _borderColor = [[iOS6Theme bubbleAssistantBorderColor] retain];
    }
    _shadowColor = [[UIColor colorWithRed:0 green:0 blue:0 alpha:0.18f] retain];
    [oldFill release];
    [oldBorder release];
    [oldShadow release];
    [self setNeedsDisplay];
}

// v261114: AI document panel. Deliberately does NOT share the bubble path:
// solid fill, no gradient/gloss/drop shadow/outline. iOS 6 uses a paper
// surface (1px top inner shadow); iOS 7+ uses a flat surface with a subtle
// left rail so the block reads as "content", not "a bubble without a tail".
- (void)_drawDocumentPanelInRect:(CGRect)rect
{
    if (CGRectGetWidth(rect) < 12.0f || CGRectGetHeight(rect) < 12.0f) return;

    CGRect body = CGRectInset(rect, 1.0f, 1.0f);
    CGFloat r = _cornerRadius;
    CGFloat maxR = MIN(body.size.width, body.size.height) / 2.0f;
    if (r > maxR) r = maxR;
    if (r < 0) r = 0;

    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:body
                                                       cornerRadius:r];
    [_fillColor setFill];
    [path fill];

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    BOOL flatUI = [iOS6Theme isFlatUI];
    if (!flatUI) {
        // Paper: a single 1px dark line just inside the top edge. No
        // gradient, no white gloss, no outer border, no drop shadow.
        CGContextSaveGState(ctx);
        [path addClip];
        CGFloat alpha = [iOS6Theme isDarkMode] ? 0.22f : 0.10f;
        [[UIColor colorWithWhite:0.0f alpha:alpha] setFill];
        CGContextFillRect(ctx, CGRectMake(CGRectGetMinX(body) + 1.0f,
                                          CGRectGetMinY(body) + 1.0f,
                                          body.size.width - 2.0f,
                                          1.0f));
        CGContextRestoreGState(ctx);
    } else {
        // Flat: 2px neutral rail at the document's left edge. Neutral grey,
        // not tint — tint stays reserved for interactive elements.
        CGContextSaveGState(ctx);
        [path addClip];
        UIColor *rail = [[iOS6Theme secondaryTextColor] colorWithAlphaComponent:0.22f];
        [rail setFill];
        CGFloat railX = CGRectGetMinX(body) + 3.0f;
        CGFloat railY = CGRectGetMinY(body) + r + 2.0f;
        CGFloat railH = body.size.height - 2.0f * (r + 2.0f);
        if (railH > 0) {
            CGContextFillRect(ctx, CGRectMake(railX, railY, 2.0f, railH));
        }
        CGContextRestoreGState(ctx);
    }
}

- (void)drawRect:(CGRect)rect
{
    // v261025-32: skip drawing when drawBackground=NO (AI messages use
    // accent line instead of bubble). Subviews remain visible.
    if (!_drawBackground) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    // v261114: dedicated AI content surface — never the bubble path.
    if (_documentPanel) {
        [self _drawDocumentPanelInRect:self.bounds];
        return;
    }

    // v261025-4: PRE-RENDERED stretchable bubble. The gradient body,
    // fixed-height gloss band, inner highlight, hairline border, baked
    // drop shadow AND the tail all live in ONE cached template image
    // (built once per role per theme in iOS6Theme, caps 30/40 so the
    // tail and corners never stretch). drawRect is now a single blit —
    // the old code re-ran gradient + live shadow CoreGraphics on EVERY
    // frame of every bubble, which was the biggest scrolling cost on
    // iPhone 3GS.
    BOOL flatUI = [iOS6Theme isFlatUI];
    // iOS 7+: never build/blit the iOS 6 glossy template (gradient + gloss
    // + baked shadow). Flat design uses the vector path below.
    UIImage *tmpl = nil;
    if (!flatUI) {
        tmpl = [iOS6Theme stretchableBubbleImageForUser:
                    (self.role == BubbleRoleUser)];
    }
    // v261025-32: error role skips template — uses vector fallback with
    // red fill/border colors set in _applyRoleColors.
    if (self.role == BubbleRoleError) tmpl = nil;
    // v261113: AI panel 不用 stretchable image（image 里有 tail，
    // 设 tailSize=(0,0) 不会去掉 image 里 baked 的 tail）
    // AI panel 走 iOS 7+ 扁平路径 或 iOS 6 vector fallback（都不画 tail）
    if (self.role == BubbleRoleAssistant && _tailSize.width == 0) tmpl = nil;
    if (tmpl) {
        [tmpl drawInRect:self.bounds];
        return;
    }

    // v261112-5 / v261113: iOS 7+ 扁平渲染 — solid fill + rounded body,
    // optional flat (non-glossy) tail, no gradient/shadow/highlight.
    if (flatUI) {
        CGRect body = CGRectInset(self.bounds, 1.0f, 1.0f);
        CGFloat tailH = (_tailSize.width > 0 && _tailSize.height > 0)
            ? _tailSize.height : 0.0f;
        body.size.height -= tailH;
        if (body.size.height < 8.0f) body.size.height = 8.0f;
        CGFloat r = _cornerRadius;
        if (r > body.size.height / 2.0f) r = body.size.height / 2.0f;

        if (tailH > 0) {
            // Union of the rounded body and a flat tail triangle.
            UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:body
                                                               cornerRadius:r];
            UIBezierPath *tail = [UIBezierPath bezierPath];
            if (self.role == BubbleRoleUser) {
                [tail moveToPoint:CGPointMake(CGRectGetMaxX(body) - 22.0f,
                                              CGRectGetMaxY(body))];
                [tail addLineToPoint:CGPointMake(CGRectGetMaxX(body) - 4.0f,
                                                 CGRectGetMaxY(body) + tailH)];
                [tail addLineToPoint:CGPointMake(CGRectGetMaxX(body) - 12.0f,
                                                 CGRectGetMaxY(body))];
            } else {
                [tail moveToPoint:CGPointMake(CGRectGetMinX(body) + 22.0f,
                                              CGRectGetMaxY(body))];
                [tail addLineToPoint:CGPointMake(CGRectGetMinX(body) + 4.0f,
                                                 CGRectGetMaxY(body) + tailH)];
                [tail addLineToPoint:CGPointMake(CGRectGetMinX(body) + 12.0f,
                                                 CGRectGetMaxY(body))];
            }
            [tail closePath];
            [path appendPath:tail];
            [_fillColor setFill];
            [path fill];
        } else {
            // AI panel / error card: borderless-looking flat rounded card
            // with a single hairline for edge definition on light surfaces.
            UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:body
                                                               cornerRadius:r];
            [_fillColor setFill];
            [path fill];
            if (_borderColor) {
                [_borderColor setStroke];
                [path setLineWidth:0.5f];
                [path stroke];
            }
        }
        return;
    }

    // ---- Fallback (template draw failed): legacy vector drawing -------
    BubbleRole role = _role;
    BOOL isUser = (role == BubbleRoleUser);

    // Inset for the rounded body so there's room for the tail + shadow.
    CGFloat tailH = _tailSize.height;
    CGRect body = CGRectInset(rect, 2.0f, 2.0f);
    body.size.height -= tailH;
    if (body.size.height < 8) body.size.height = 8;

    // --- Drop shadow ---
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0.0f, 1.5f), 3.0f, [_shadowColor CGColor]);

    // Build a path that combines the body rect and the tail triangle.
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGFloat r = _cornerRadius;
    CGRect inset = CGRectInset(body, r, r);

    // Start at top-left after corner
    CGPoint topLeft = CGPointMake(body.origin.x + r, body.origin.y);
    [path moveToPoint:topLeft];

    // Top edge to top-right before corner
    [path addLineToPoint:CGPointMake(body.origin.x + body.size.width - r, body.origin.y)];

    // Top-right corner
    [path addArcWithCenter:CGPointMake(body.origin.x + body.size.width - r,
                                       body.origin.y + r)
                      radius:r
                  startAngle:-M_PI_2
                    endAngle:0
                   clockwise:YES];

    // Right edge down to tail start
    CGFloat tailBaseX = isUser ? (body.origin.x + body.size.width - 22.0f)
                               : (body.origin.x + 22.0f);
    if (isUser) {
        // Tail on bottom-right
        [path addLineToPoint:CGPointMake(body.origin.x + body.size.width,
                                          body.origin.y + body.size.height - r)];
        // Bottom-right corner
        [path addArcWithCenter:CGPointMake(body.origin.x + body.size.width - r,
                                            body.origin.y + body.size.height - r)
                          radius:r
                      startAngle:0
                        endAngle:M_PI_2
                       clockwise:YES];
        // Tail base X (closer to right side)
        [path addLineToPoint:CGPointMake(body.origin.x + body.size.width - 14.0f,
                                          body.origin.y + body.size.height)];
        // Tail tip
        [path addLineToPoint:CGPointMake(body.origin.x + body.size.width - 4.0f,
                                          body.origin.y + body.size.height + tailH)];
        // Back to left of tail
        [path addLineToPoint:CGPointMake(body.origin.x + body.size.width - 22.0f,
                                          body.origin.y + body.size.height)];
        // Bottom-left edge to corner
        [path addLineToPoint:CGPointMake(body.origin.x + r,
                                          body.origin.y + body.size.height)];
        // Bottom-left corner
        [path addArcWithCenter:CGPointMake(body.origin.x + r,
                                            body.origin.y + body.size.height - r)
                          radius:r
                      startAngle:M_PI_2
                        endAngle:M_PI
                       clockwise:YES];
    } else {
        // Tail on bottom-left (v261113: skip tail if tailSize.width==0)
        [path addLineToPoint:CGPointMake(body.origin.x + body.size.width,
                                          body.origin.y + body.size.height - r)];
        // Bottom-right corner
        [path addArcWithCenter:CGPointMake(body.origin.x + body.size.width - r,
                                            body.origin.y + body.size.height - r)
                          radius:r
                      startAngle:0
                        endAngle:M_PI_2
                       clockwise:YES];
        if (_tailSize.width > 0) {
            // Tail nub on the left
            [path addLineToPoint:CGPointMake(body.origin.x + 22.0f,
                                              body.origin.y + body.size.height)];
            [path addLineToPoint:CGPointMake(body.origin.x + 4.0f,
                                              body.origin.y + body.size.height + tailH)];
            [path addLineToPoint:CGPointMake(body.origin.x + 14.0f,
                                              body.origin.y + body.size.height)];
        }
        [path addLineToPoint:CGPointMake(body.origin.x + r,
                                          body.origin.y + body.size.height)];
        // Bottom-left corner
        [path addArcWithCenter:CGPointMake(body.origin.x + r,
                                            body.origin.y + body.size.height - r)
                          radius:r
                      startAngle:M_PI_2
                        endAngle:M_PI
                       clockwise:YES];
    }

    // Left edge up to start
    [path addLineToPoint:CGPointMake(body.origin.x,
                                      body.origin.y + r)];
    // Top-left corner
    [path addArcWithCenter:CGPointMake(body.origin.x + r,
                                        body.origin.y + r)
                      radius:r
                  startAngle:M_PI
                    endAngle:-M_PI_2
                   clockwise:YES];

    [path closePath];

    // Fill: a subtle vertical gradient (lighter top, slightly darker bottom)
    CGContextSaveGState(ctx);
    [path addClip];

    UIColor *topCol = _fillColor;
    UIColor *botCol = [iOS6Theme darkerColor:_fillColor by:0.06f];
    CGRect gradRect = body;
    // v261025-1: CFArrayCreate pattern — no (id)CGColor casts into NSArray
    // (same hardening as the rest of the theme code).
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGColorRef gc0 = CGColorRetain(topCol.CGColor);
    CGColorRef gc1 = CGColorRetain(botCol.CGColor);
    const void *gvals[] = { gc0, gc1 };
    CFArrayRef cols = CFArrayCreate(kCFAllocatorDefault, gvals, 2,
                                    &kCFTypeArrayCallBacks);
    CGFloat locs[] = {0.0f, 1.0f};
    CGGradientRef grad = CGGradientCreateWithColors(cs, cols, locs);
    CGContextDrawLinearGradient(ctx, grad,
                                CGPointMake(CGRectGetMidX(gradRect), CGRectGetMinY(gradRect)),
                                CGPointMake(CGRectGetMidX(gradRect), CGRectGetMaxY(gradRect)),
                                0);
    if (grad) CGGradientRelease(grad);
    if (cols) CFRelease(cols);
    if (gc1) CGColorRelease(gc1);
    if (gc0) CGColorRelease(gc0);
    if (cs) CGColorSpaceRelease(cs);
    CGContextRestoreGState(ctx);

    // Inner top highlight (1px white line)
    CGContextSaveGState(ctx);
    [path addClip];
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0f alpha:0.5f].CGColor);
    CGContextSetLineWidth(ctx, 1.0f);
    CGContextMoveToPoint(ctx, body.origin.x + 4.0f, body.origin.y + 1.5f);
    CGContextAddLineToPoint(ctx, body.origin.x + body.size.width - 4.0f,
                              body.origin.y + 1.5f);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);

    CGContextRestoreGState(ctx); // shadow

    // Outer hairline
    CGContextSetStrokeColorWithColor(ctx, [_borderColor CGColor]);
    CGContextSetLineWidth(ctx, 1.0f);
    [path stroke];
}

- (void)dealloc
{
    // v261025-5: snapshot-then-nil pattern. The user-reported
    // -[ChatBubbleView dealloc +210] SIGSEGV (visible in the v261025-4
    // crash logs every time the user opened 设置/模型管理 after entering
    // a history conversation) was caused by UIKit teardown of the
    // ChatMessageCell calling ChatBubbleView.dealloc on a view whose
    // _shadowColor had been released by a previous _applyRoleColors pass
    // but the ivar still pointed at the freed instance. By snapshotting to
    // a local first and clearing the ivar, a subsequent _applyRoleColors
    // or dealloc call cannot double-release.
    UIColor *f = _fillColor;     UIColor *b = _borderColor;     UIColor *s = _shadowColor;
    _fillColor = nil;            _borderColor = nil;            _shadowColor = nil;
    [f release];
    [b release];
    [s release];
    [super dealloc];
}

@end

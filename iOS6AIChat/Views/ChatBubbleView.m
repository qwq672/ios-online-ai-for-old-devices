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

@synthesize role=_role, cornerRadius=_cornerRadius, tailSize=_tailSize;
@synthesize fillColor=_fillColor, borderColor=_borderColor, shadowColor=_shadowColor;

- (id)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor clearColor];
        _cornerRadius = 14.0f;
        _tailSize = CGSizeMake(12.0f, 6.0f);
        _role = BubbleRoleUser;
        [self _applyRoleColors];
    }
    return self;
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
    } else {
        _fillColor = [[iOS6Theme bubbleAssistantColor] retain];
        _borderColor = [[iOS6Theme bubbleAssistantBorderColor] retain];
    }
    _shadowColor = [[UIColor colorWithRed:0 green:0 blue:0 alpha:0.18f] retain];
    [oldFill release];
    [oldBorder release];
    [oldShadow release];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect
{
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    // v261025-4: PRE-RENDERED stretchable bubble. The gradient body,
    // fixed-height gloss band, inner highlight, hairline border, baked
    // drop shadow AND the tail all live in ONE cached template image
    // (built once per role per theme in iOS6Theme, caps 30/40 so the
    // tail and corners never stretch). drawRect is now a single blit —
    // the old code re-ran gradient + live shadow CoreGraphics on EVERY
    // frame of every bubble, which was the biggest scrolling cost on
    // iPhone 3GS.
    UIImage *tmpl = [iOS6Theme stretchableBubbleImageForUser:(self.role == BubbleRoleUser)];
    if (tmpl) {
        // The template's geometry mirrors the legacy drawRect: 2pt
        // transparent margins + body + 6pt tail zone — i.e. it maps
        // 1:1 onto the view's bounds.
        [tmpl drawInRect:self.bounds];
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
        // Tail on bottom-left
        [path addLineToPoint:CGPointMake(body.origin.x + body.size.width,
                                          body.origin.y + body.size.height - r)];
        // Bottom-right corner
        [path addArcWithCenter:CGPointMake(body.origin.x + body.size.width - r,
                                            body.origin.y + body.size.height - r)
                          radius:r
                      startAngle:0
                        endAngle:M_PI_2
                       clockwise:YES];
        // Bottom edge leftward past tail base, with a tail nub on the left.
        [path addLineToPoint:CGPointMake(body.origin.x + 22.0f,
                                          body.origin.y + body.size.height)];
        [path addLineToPoint:CGPointMake(body.origin.x + 4.0f,
                                          body.origin.y + body.size.height + tailH)];
        [path addLineToPoint:CGPointMake(body.origin.x + 14.0f,
                                          body.origin.y + body.size.height)];
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

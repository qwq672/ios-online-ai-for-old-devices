//
//  IconDrawing.m
//  iOS6AIChat
//
//  Each icon is drawn at the centre of the requested size box. Stroke
//  weights and proportions are tuned for ~28pt button icons.
//

#import "IconDrawing.h"

@implementation IconDrawing

+ (UIImage *)imageForType:(IconType)type
                     size:(CGSize)size
                    color:(UIColor *)color
{
    if (!color) color = [UIColor blackColor];

    // For icons that have PNG assets (from user-provided SVGs), load the
    // PNG and tint it with the requested color. This gives nicer-looking
    // icons than the hand-drawn CoreGraphics versions.
    NSString *pngName = nil;
    switch (type) {
        case IconTypeLightbulb:   pngName = @"lightbulb";   break;
        case IconTypeCamera:      pngName = @"camera";      break;
        case IconTypeSendArrow:   pngName = @"send";        break;
        default: break;  // other types use CoreGraphics below
    }
    if (pngName) {
        UIImage *base = [UIImage imageNamed:pngName];
        if (base) {
            return [self _tintImage:base withColor:color size:size];
        }
        // Fall through to CoreGraphics if PNG not found.
    }

    // CoreGraphics fallback for all icons.
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, color.CGColor);
    CGContextSetStrokeColorWithColor(ctx, color.CGColor);

    CGFloat w = size.width, h = size.height;
    CGFloat cx = w * 0.5f, cy = h * 0.5f;

    switch (type) {
        case IconTypeLightbulb:   [self _drawLightbulb:ctx cx:cx cy:cy w:w h:h]; break;
        case IconTypeGlobe:        [self _drawGlobe:ctx cx:cx cy:cy w:w h:h]; break;
        case IconTypeCamera:       [self _drawCamera:ctx cx:cx cy:cy w:w h:h]; break;
        case IconTypeSendArrow:    [self _drawSendArrow:ctx cx:cx cy:cy w:w h:h]; break;
        case IconTypeGear:         [self _drawGear:ctx cx:cx cy:cy w:w h:h]; break;
        case IconTypeChatBubble:   [self _drawChatBubble:ctx cx:cx cy:cy w:w h:h]; break;
        case IconTypeClock:        [self _drawClock:ctx cx:cx cy:cy w:w h:h]; break;
        case IconTypeRefresh:      [self _drawRefresh:ctx cx:cx cy:cy w:w h:h]; break;
        case IconTypeCopy:         [self _drawCopy:ctx cx:cx cy:cy w:w h:h]; break;
        case IconTypeHamburger:    [self _drawHamburger:ctx cx:cx cy:cy w:w h:h]; break;
        case IconTypeLayers:       [self _drawLayers:ctx cx:cx cy:cy w:w h:h]; break;
        case IconTypePerson:       [self _drawPerson:ctx cx:cx cy:cy w:w h:h]; break;
        case IconTypeDoc:          [self _drawDoc:ctx cx:cx cy:cy w:w h:h]; break;
    }

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// Tint a PNG image (with alpha) with a solid color, scaled to the
// requested size. Uses drawInRect: + kCGBlendModeSourceIn for correct
// orientation (drawInRect handles UIKit coordinate system, unlike
// CGContextClipToMask which uses CGImage's bottom-left origin and
// flips the image).
+ (UIImage *)_tintImage:(UIImage *)image withColor:(UIColor *)color size:(CGSize)size
{
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect area = CGRectMake(0, 0, size.width, size.height);

    // Step 1: Draw the image scaled to target size. drawInRect: handles
    // the UIKit coordinate system (top-left origin) correctly — no flip.
    [image drawInRect:area];

    // Step 2: Use SourceIn blend mode to replace the image's RGB with
    // the fill color, keeping the alpha channel. This effectively tints
    // the image with the desired color.
    CGContextSetBlendMode(ctx, kCGBlendModeSourceIn);
    CGContextSetFillColorWithColor(ctx, color.CGColor);
    CGContextFillRect(ctx, area);

    UIImage *tinted = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return tinted;
}

#pragma mark - Lightbulb

+ (void)_drawLightbulb:(CGContextRef)ctx cx:(CGFloat)cx cy:(CGFloat)cy w:(CGFloat)w h:(CGFloat)h
{
    // Bulb: circle at upper-middle.
    CGFloat bulbR = MIN(w, h) * 0.32f;
    CGRect bulbRect = CGRectMake(cx - bulbR, cy - bulbR * 1.05f, bulbR * 2, bulbR * 2);
    CGContextFillEllipseInRect(ctx, bulbRect);

    // Base: trapezoid below the bulb.
    CGFloat baseTopW = bulbR * 1.2f;
    CGFloat baseBotW = bulbR * 0.9f;
    CGFloat baseH = bulbR * 0.6f;
    CGFloat baseTop = cy + bulbR * 0.85f;
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, cx - baseTopW/2, baseTop);
    CGContextAddLineToPoint(ctx, cx + baseTopW/2, baseTop);
    CGContextAddLineToPoint(ctx, cx + baseBotW/2, baseTop + baseH);
    CGContextAddLineToPoint(ctx, cx - baseBotW/2, baseTop + baseH);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);

    // Two thin base rings.
    CGFloat ringH = MAX(1.0f, bulbR * 0.12f);
    for (NSInteger i = 0; i < 2; i++) {
        CGFloat ry = baseTop + baseH * 0.35f + ringH * 2.0f * i;
        CGRect rrect = CGRectMake(cx - baseBotW * 0.55f, ry, baseBotW * 1.1f, ringH);
        CGContextFillRect(ctx, rrect);
    }

    // Filament hint: a small "M" shape inside the bulb (in cutout style).
    // For simplicity, we just leave the bulb solid — silhouette icons
    // typically don't show interior detail at this size.
}

+ (void)_drawGlobe:(CGContextRef)ctx cx:(CGFloat)cx cy:(CGFloat)cy w:(CGFloat)w h:(CGFloat)h
{
    CGFloat r = MIN(w, h) * 0.42f;
    CGRect circle = CGRectMake(cx - r, cy - r, r * 2, r * 2);

    // Outline (ring).
    CGContextSetLineWidth(ctx, MAX(1.5f, r * 0.12f));
    CGContextStrokeEllipseInRect(ctx, circle);

    // Vertical ellipse (prime meridian).
    CGRect merid = CGRectMake(cx - r * 0.45f, cy - r, r * 0.9f, r * 2);
    CGContextStrokeEllipseInRect(ctx, merid);

    // Horizontal lines (equator + 2 tropics).
    CGContextSetLineWidth(ctx, MAX(1.0f, r * 0.08f));
    // Equator (straight line through middle).
    CGContextMoveToPoint(ctx, cx - r, cy);
    CGContextAddLineToPoint(ctx, cx + r, cy);
    CGContextStrokePath(ctx);

    // Upper tropic (slight curve).
    CGRect tropicUp = CGRectMake(cx - r, cy - r * 0.55f, r * 2, r * 0.5f);
    CGContextStrokeEllipseInRect(ctx, tropicUp);
    // Clip the upper half by re-stroking a small arc only:
    // Simpler: just draw two horizontal chords to simulate tropics.
    // Already have the equator; the upper tropic arc appears as the
    // top half of the small ellipse — the bottom half overlaps the
    // globe body, so visually it looks fine.

    // Lower tropic.
    CGRect tropicDn = CGRectMake(cx - r, cy + r * 0.05f, r * 2, r * 0.5f);
    CGContextStrokeEllipseInRect(ctx, tropicDn);
}

#pragma mark - Camera

+ (void)_drawCamera:(CGContextRef)ctx cx:(CGFloat)cx cy:(CGFloat)cy w:(CGFloat)w h:(CGFloat)h
{
    CGFloat bodyW = w * 0.7f;
    CGFloat bodyH = h * 0.5f;
    CGFloat cornerR = bodyH * 0.18f;
    CGRect body = CGRectMake(cx - bodyW/2, cy - bodyH/2 + bodyH*0.1f, bodyW, bodyH);

    // Body: rounded rectangle.
    UIBezierPath *bp = [UIBezierPath bezierPathWithRoundedRect:body cornerRadius:cornerR];
    CGContextAddPath(ctx, [bp CGPath]);
    CGContextFillPath(ctx);

    // Lens: circle in the body.
    CGFloat lensR = bodyH * 0.4f;
    CGRect lens = CGRectMake(cx - lensR, cy + bodyH*0.1f - lensR, lensR * 2, lensR * 2);
    // Cut out a hole by using EO-fill (draw body again + lens, even-odd).
    CGContextAddEllipseInRect(ctx, lens);
    CGContextAddPath(ctx, [bp CGPath]);
    CGContextEOFillPath(ctx);

    // Flash hump on top.
    CGFloat humpW = bodyW * 0.35f;
    CGFloat humpH = bodyH * 0.35f;
    CGRect hump = CGRectMake(cx - humpW/2, body.origin.y - humpH, humpW, humpH);
    CGContextAddRect(ctx, hump);
    CGContextFillRect(ctx, hump);

    // Outer lens ring (thin outline).
    CGFloat ringInset = lensR * 0.25f;
    CGRect ring = CGRectInset(lens, ringInset, ringInset);
    CGContextSetLineWidth(ctx, MAX(1.0f, lensR * 0.18f));
    CGContextStrokeEllipseInRect(ctx, ring);
}

#pragma mark - Send Arrow

+ (void)_drawSendArrow:(CGContextRef)ctx cx:(CGFloat)cx cy:(CGFloat)cy w:(CGFloat)w h:(CGFloat)h
{
    // Paper-plane style arrow pointing right.
    CGFloat arrowW = w * 0.55f;
    CGFloat arrowH = h * 0.55f;
    CGFloat tipX = cx + arrowW * 0.5f;
    CGFloat tailX = cx - arrowW * 0.5f;
    CGFloat topY = cy - arrowH * 0.5f;
    CGFloat botY = cy + arrowH * 0.5f;
    CGFloat midY = cy;

    // Triangle body.
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, tipX, midY);
    CGContextAddLineToPoint(ctx, tailX, topY);
    CGContextAddLineToPoint(ctx, tailX, botY);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);

    // Fold line (white cut through middle — visually splits the paper plane).
    CGContextSetBlendMode(ctx, kCGBlendModeDestinationOut);
    CGContextSetLineWidth(ctx, MAX(1.0f, arrowH * 0.15f));
    CGContextMoveToPoint(ctx, tipX, midY);
    CGContextAddLineToPoint(ctx, tailX, midY);
    CGContextStrokePath(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeNormal);
}

#pragma mark - Gear

+ (void)_drawGear:(CGContextRef)ctx cx:(CGFloat)cx cy:(CGFloat)cy w:(CGFloat)w h:(CGFloat)h
{
    // N teeth around a circle. iOS 6 tab bar icons are 30x30pt — make
    // the gear ~22pt diameter to leave 4pt padding on each side.
    CGFloat r = MIN(w, h) * 0.42f;
    CGFloat toothLen = r * 0.22f;
    NSInteger nTeeth = 8;
    CGFloat toothHalfAngle = M_PI / (nTeeth * 2.6f);

    CGContextBeginPath(ctx);
    for (NSInteger i = 0; i < nTeeth; i++) {
        CGFloat a = (CGFloat)i * 2.0f * M_PI / (CGFloat)nTeeth;
        // Tooth corners: tip1, tip2 (outside), valley1, valley2 (inside).
        CGFloat aTip1 = a - toothHalfAngle;
        CGFloat aTip2 = a + toothHalfAngle;
        CGFloat aValley1 = a + toothHalfAngle;
        CGFloat aValley2 = a + (2.0f * M_PI / nTeeth) - toothHalfAngle;

        CGFloat rOuter = r + toothLen;
        CGFloat rInner = r;

        // Outer arc point 1
        CGFloat x1 = cx + rOuter * cosf(aTip1);
        CGFloat y1 = cy + rOuter * sinf(aTip1);
        // Outer arc point 2
        CGFloat x2 = cx + rOuter * cosf(aTip2);
        CGFloat y2 = cy + rOuter * sinf(aTip2);
        // Inner arc point 1 (end of tooth 1, start of valley)
        CGFloat x3 = cx + rInner * cosf(aValley1);
        CGFloat y3 = cy + rInner * sinf(aValley1);
        // Inner arc point 2 (end of valley, start of tooth 2)
        CGFloat x4 = cx + rInner * cosf(aValley2);
        CGFloat y4 = cy + rInner * sinf(aValley2);

        if (i == 0) CGContextMoveToPoint(ctx, x1, y1);
        else CGContextAddLineToPoint(ctx, x1, y1);
        CGContextAddLineToPoint(ctx, x2, y2);
        CGContextAddLineToPoint(ctx, x3, y3);
        // Valley arc (small inner arc to next tooth start).
        CGContextAddArc(ctx, cx, cy, rInner, aValley1, aValley2, 0);
        (void)x4; (void)y4;
    }
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);

    // Centre hole (cut out).
    CGFloat holeR = r * 0.4f;
    CGRect hole = CGRectMake(cx - holeR, cy - holeR, holeR * 2, holeR * 2);
    CGContextSetBlendMode(ctx, kCGBlendModeDestinationOut);
    CGContextFillEllipseInRect(ctx, hole);
    CGContextSetBlendMode(ctx, kCGBlendModeNormal);
}

#pragma mark - Chat bubble

+ (void)_drawChatBubble:(CGContextRef)ctx cx:(CGFloat)cx cy:(CGFloat)cy w:(CGFloat)w h:(CGFloat)h
{
    CGFloat bw = w * 0.7f;
    CGFloat bh = h * 0.55f;
    CGFloat cornerR = bh * 0.2f;
    CGRect body = CGRectMake(cx - bw/2, cy - bh/2 - h*0.05f, bw, bh);

    // Bubble body (rounded rectangle).
    UIBezierPath *bp = [UIBezierPath bezierPathWithRoundedRect:body cornerRadius:cornerR];
    CGContextAddPath(ctx, [bp CGPath]);
    CGContextFillPath(ctx);

    // Tail (triangle at bottom-left).
    CGFloat tailW = bw * 0.18f;
    CGFloat tailH = bh * 0.4f;
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, body.origin.x + bw * 0.18f, body.origin.y + body.size.height);
    CGContextAddLineToPoint(ctx, body.origin.x + bw * 0.18f + tailW, body.origin.y + body.size.height);
    CGContextAddLineToPoint(ctx, body.origin.x + bw * 0.18f + tailW * 0.4f, body.origin.y + body.size.height + tailH);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);

    // Three dots inside the bubble (white cutouts).
    CGFloat dotR = bh * 0.08f;
    CGFloat dotY = body.origin.y + body.size.height * 0.5f;
    CGFloat dotSpacing = bw * 0.18f;
    CGContextSetBlendMode(ctx, kCGBlendModeDestinationOut);
    for (NSInteger i = -1; i <= 1; i++) {
        CGRect dot = CGRectMake(cx + i * dotSpacing - dotR, dotY - dotR, dotR * 2, dotR * 2);
        CGContextFillEllipseInRect(ctx, dot);
    }
    CGContextSetBlendMode(ctx, kCGBlendModeNormal);
}

#pragma mark - Clock

+ (void)_drawClock:(CGContextRef)ctx cx:(CGFloat)cx cy:(CGFloat)cy w:(CGFloat)w h:(CGFloat)h
{
    CGFloat r = MIN(w, h) * 0.42f;
    CGRect circle = CGRectMake(cx - r, cy - r, r * 2, r * 2);
    CGContextSetLineWidth(ctx, MAX(2.0f, r * 0.18f));
    CGContextStrokeEllipseInRect(ctx, circle);

    // Hour hand (short, up).
    CGContextSetLineWidth(ctx, MAX(1.5f, r * 0.14f));
    CGContextMoveToPoint(ctx, cx, cy);
    CGContextAddLineToPoint(ctx, cx, cy - r * 0.5f);
    CGContextStrokePath(ctx);

    // Minute hand (longer, right).
    CGContextMoveToPoint(ctx, cx, cy);
    CGContextAddLineToPoint(ctx, cx + r * 0.75f, cy);
    CGContextStrokePath(ctx);

    // Centre dot.
    CGFloat dotR = r * 0.1f;
    CGRect dot = CGRectMake(cx - dotR, cy - dotR, dotR * 2, dotR * 2);
    CGContextFillEllipseInRect(ctx, dot);
}

+ (void)_drawRefresh:(CGContextRef)ctx cx:(CGFloat)cx cy:(CGFloat)cy w:(CGFloat)w h:(CGFloat)h
{
    // Circular arrow (regenerate icon).
    CGFloat r = MIN(w, h) * 0.38f;
    CGFloat startAngle = -M_PI * 0.25f;   // start from upper right
    CGFloat endAngle   = -M_PI * 0.25f + M_PI * 1.5f;  // 3/4 circle, clockwise

    CGContextSetLineWidth(ctx, MAX(1.5f, r * 0.15f));
    CGContextSetLineCap(ctx, kCGLineCapRound);

    // Draw 3/4 arc.
    CGContextAddArc(ctx, cx, cy, r, startAngle, endAngle, 0);  // 0 = clockwise
    CGContextStrokePath(ctx);

    // Arrowhead at end of arc.
    CGFloat arrowAngle = endAngle;
    CGFloat arrowX = cx + r * cos(arrowAngle);
    CGFloat arrowY = cy + r * sin(arrowAngle);
    CGFloat aSize = r * 0.35f;
    // Draw a filled triangle as the arrowhead, pointing in the direction
    // of the arc's tangent at the end point.
    CGFloat tangentAngle = arrowAngle + M_PI_2;  // tangent is perpendicular to radius, clockwise
    CGFloat p1x = arrowX + aSize * cos(tangentAngle);
    CGFloat p1y = arrowY + aSize * sin(tangentAngle);
    CGFloat p2x = arrowX - aSize * cos(tangentAngle);
    CGFloat p2y = arrowY - aSize * sin(tangentAngle);
    CGFloat p3x = arrowX + aSize * cos(arrowAngle);
    CGFloat p3y = arrowY + aSize * sin(arrowAngle);
    CGContextMoveToPoint(ctx, p1x, p1y);
    CGContextAddLineToPoint(ctx, p2x, p2y);
    CGContextAddLineToPoint(ctx, p3x, p3y);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
}

+ (void)_drawCopy:(CGContextRef)ctx cx:(CGFloat)cx cy:(CGFloat)cy w:(CGFloat)w h:(CGFloat)h
{
    // Two overlapping rectangles (copy icon).
    CGFloat rectW = w * 0.35f;
    CGFloat rectH = h * 0.35f;
    CGFloat lineW = MAX(1.5f, rectW * 0.12f);
    CGContextSetLineWidth(ctx, lineW);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);

    // Back rectangle (offset upper-right).
    CGFloat backX = cx - rectW * 0.1f;
    CGFloat backY = cy - rectH * 0.6f;
    CGRect backRect = CGRectMake(backX, backY, rectW, rectH);
    CGContextStrokeRect(ctx, backRect);

    // Front rectangle (offset lower-left, filled with bg to mask back).
    CGFloat frontX = cx - rectW * 0.9f;
    CGFloat frontY = cy - rectH * 0.1f;
    CGRect frontRect = CGRectMake(frontX, frontY, rectW, rectH);
    // Fill front rect with current fill color (solid).
    CGContextFillRect(ctx, frontRect);
    // Then stroke it.
    CGContextStrokeRect(ctx, frontRect);
}

+ (void)_drawHamburger:(CGContextRef)ctx cx:(CGFloat)cx cy:(CGFloat)cy w:(CGFloat)w h:(CGFloat)h
{
    // Three horizontal bars with round caps (drawer "hamburger" icon).
    // Tuned to read clearly at 22pt navbar size.
    CGFloat lineW = MAX(2.0f, h * 0.10f);
    CGFloat spanW = w * 0.74f;
    CGFloat gap   = h * 0.21f;
    CGContextSetLineWidth(ctx, lineW);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);

    CGFloat x0 = cx - spanW * 0.5f;
    CGFloat x1 = cx + spanW * 0.5f;
    for (NSInteger i = -1; i <= 1; i++) {
        CGFloat y = cy + gap * (CGFloat)i;
        CGContextMoveToPoint(ctx, x0, y);
        CGContextAddLineToPoint(ctx, x1, y);
    }
    CGContextStrokePath(ctx);
}

+ (void)_drawLayers:(CGContextRef)ctx cx:(CGFloat)cx cy:(CGFloat)cy w:(CGFloat)w h:(CGFloat)h
{
    // Model management: three stacked rounded "cards" (like a layer stack /
    // database symbol). Reads as "a list of models" at 26pt.
    CGFloat cardW = w * 0.62f;
    CGFloat cardH = h * 0.16f;
    CGFloat gap   = h * 0.085f;
    CGFloat lineW = MAX(1.6f, cardH * 0.30f);
    CGContextSetLineWidth(ctx, lineW);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextSetLineCap(ctx, kCGLineCapRound);

    // Top card: filled diamond-ish rounded rect (solid = "current default").
    // Middle + bottom cards: outlined.
    CGFloat totalH = cardH * 3 + gap * 2;
    CGFloat topY = cy - totalH * 0.5f;

    for (NSInteger i = 0; i < 3; i++) {
        CGFloat y = topY + (cardH + gap) * (CGFloat)i;
        CGRect card = CGRectMake(cx - cardW * 0.5f, y, cardW, cardH);
        if (i == 0) {
            // Filled top card with slightly rounded corners.
            CGFloat r = cardH * 0.35f;
            UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:card cornerRadius:r];
            CGContextAddPath(ctx, p.CGPath);
            CGContextFillPath(ctx);
        } else {
            CGFloat r = cardH * 0.35f;
            UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:card cornerRadius:r];
            CGContextAddPath(ctx, p.CGPath);
            CGContextStrokePath(ctx);
        }
    }
}

+ (void)_drawPerson:(CGContextRef)ctx cx:(CGFloat)cx cy:(CGFloat)cy w:(CGFloat)w h:(CGFloat)h
{
    // Character management: head + shoulders silhouette ( Contacts-app
    // style person). Reads clearly at 26pt.
    CGFloat headR = MIN(w, h) * 0.155f;
    CGFloat headCY = cy - h * 0.16f;

    // Head (filled circle).
    CGRect head = CGRectMake(cx - headR, headCY - headR, headR * 2, headR * 2);
    CGContextFillEllipseInRect(ctx, head);

    // Shoulders (filled half-ellipse / dome).
    CGFloat domeW = w * 0.56f;
    CGFloat domeH = h * 0.30f;
    CGFloat domeTop = cy + h * 0.04f;
    // Draw the dome as an ellipse clipped to its upper half.
    CGRect dome = CGRectMake(cx - domeW * 0.5f, domeTop, domeW, domeH * 2.0f);
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, CGRectMake(dome.origin.x, dome.origin.y,
                                         dome.size.width, dome.size.height));
    CGContextFillEllipseInRect(ctx, dome);
    CGContextRestoreGState(ctx);
}

+ (void)_drawDoc:(CGContextRef)ctx cx:(CGFloat)cx cy:(CGFloat)cy w:(CGFloat)w h:(CGFloat)h
{
    // Log viewer: document sheet with text lines (Notes-app style).
    CGFloat docW = w * 0.52f;
    CGFloat docH = h * 0.62f;
    CGFloat lineW = MAX(1.4f, docW * 0.07f);
    CGContextSetLineWidth(ctx, lineW);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextSetLineCap(ctx, kCGLineCapRound);

    CGRect doc = CGRectMake(cx - docW * 0.5f, cy - docH * 0.5f, docW, docH);
    // Slightly rounded document corners.
    CGFloat r = MIN(docW, docH) * 0.12f;
    UIBezierPath *bp = [UIBezierPath bezierPathWithRoundedRect:doc cornerRadius:r];
    CGContextAddPath(ctx, bp.CGPath);
    CGContextStrokePath(ctx);

    // Three text lines inside; the middle one shorter (classic doc glyph).
    CGFloat insetX = docW * 0.20f;
    CGFloat lineGap = docH * 0.24f;
    CGFloat firstY  = doc.origin.y + docH * 0.26f;
    NSArray *fracs = [NSArray arrayWithObjects:
                      [NSNumber numberWithFloat:1.0f],
                      [NSNumber numberWithFloat:0.62f],
                      [NSNumber numberWithFloat:1.0f], nil];
    for (NSInteger i = 0; i < 3; i++) {
        CGFloat frac = [(NSNumber *)[fracs objectAtIndex:i] floatValue];
        CGFloat y = firstY + lineGap * (CGFloat)i;
        CGFloat x0 = doc.origin.x + insetX;
        // Shorten from the right for the middle line.
        CGFloat x1 = doc.origin.x + (docW - insetX * 2.0f) * frac + insetX;
        CGContextMoveToPoint(ctx, x0, y);
        CGContextAddLineToPoint(ctx, x1, y);
    }
    CGContextStrokePath(ctx);
}

@end

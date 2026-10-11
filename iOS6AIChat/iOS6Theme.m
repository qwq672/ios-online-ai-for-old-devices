//
//  iOS6Theme.m
//  iOS6AIChat
//

#import "iOS6Theme.h"

@implementation iOS6Theme

+ (UIColor *)tintColor
{
    // The classic iOS 6 vivid blue (#1180E0-ish, just a touch brighter).
    return [UIColor colorWithRed:0.067f green:0.502f blue:0.902f alpha:1.0f];
}

+ (UIColor *)navbarTopColor
{
    // Top half of the navbar gradient — bright tint with a hint of cyan.
    return [UIColor colorWithRed:0.31f green:0.62f blue:0.92f alpha:1.0f];
}

+ (UIColor *)navbarBottomColor
{
    // Bottom half — same hue but darker.
    return [UIColor colorWithRed:0.04f green:0.31f blue:0.67f alpha:1.0f];
}

+ (UIColor *)tabbarTopColor
{
    return [UIColor colorWithRed:0.91f green:0.93f blue:0.96f alpha:1.0f];
}

+ (UIColor *)tabbarBottomColor
{
    return [UIColor colorWithRed:0.62f green:0.66f blue:0.72f alpha:1.0f];
}

+ (UIColor *)pinstripeColor
{
    // The faint repeated band that gave the iOS 6 Settings app its sheen.
    return [UIColor colorWithRed:0.94f green:0.94f blue:0.96f alpha:1.0f];
}

+ (UIColor *)pinstripeBackground
{
    return [UIColor colorWithRed:0.86f green:0.86f blue:0.88f alpha:1.0f];
}

+ (UIColor *)bubbleUserColor
{
    // Soft cyan-blue for outgoing messages.
    return [UIColor colorWithRed:0.78f green:0.89f blue:0.99f alpha:1.0f];
}

+ (UIColor *)bubbleUserBorderColor
{
    return [UIColor colorWithRed:0.36f green:0.58f blue:0.84f alpha:0.9f];
}

+ (UIColor *)bubbleAssistantColor
{
    // Off-white like the original iOS 6 SMS bubble.
    return [UIColor colorWithRed:0.96f green:0.96f blue:0.96f alpha:1.0f];
}

+ (UIColor *)bubbleAssistantBorderColor
{
    return [UIColor colorWithRed:0.70f green:0.70f blue:0.72f alpha:0.9f];
}

+ (UIColor *)textColor
{
    return [UIColor colorWithRed:0.10f green:0.10f blue:0.10f alpha:1.0f];
}

+ (UIColor *)secondaryTextColor
{
    return [UIColor colorWithRed:0.45f green:0.45f blue:0.47f alpha:1.0f];
}

+ (UIColor *)codeBackgroundColor
{
    return [UIColor colorWithRed:0.95f green:0.95f blue:0.97f alpha:1.0f];
}

+ (UIColor *)codeBorderColor
{
    return [UIColor colorWithRed:0.78f green:0.79f blue:0.83f alpha:1.0f];
}

#pragma mark - Gradients & strokes

+ (void)drawLinearGradientInRect:(CGRect)rect
                          context:(CGContextRef)ctx
                          topColor:(UIColor *)top
                       bottomColor:(UIColor *)bottom
{
    if (!ctx) return;
    CGColorSpaceRef colorspace = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = [NSArray arrayWithObjects:(id)top.CGColor, (id)bottom.CGColor, nil];
    CGFloat locations[] = { 0.0f, 1.0f };
    CGGradientRef gradient = CGGradientCreateWithColors(colorspace,
                                                       (__bridge CFArrayRef)colors,
                                                       locations);
    CGPoint startPoint = CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect));
    CGPoint endPoint   = CGPointMake(CGRectGetMidX(rect), CGRectGetMaxY(rect));

    CGContextSaveGState(ctx);
    CGContextAddRect(ctx, rect);
    CGContextClip(ctx);
    CGContextDrawLinearGradient(ctx, gradient, startPoint, endPoint, 0);
    CGContextRestoreGState(ctx);

    CGGradientRelease(gradient);
    CGColorSpaceRelease(colorspace);
}

+ (void)drawGlossInRect:(CGRect)rect context:(CGContextRef)ctx
{
    // The signature iOS 6 "sheen" — a bright translucent band in the top half.
    if (!ctx) return;
    CGRect glossRect = CGRectMake(rect.origin.x, rect.origin.y,
                                 rect.size.width, rect.size.height * 0.5f);
    CGColorSpaceRef colorspace = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = [NSArray arrayWithObjects:
                       (id)[UIColor colorWithWhite:1.0f alpha:0.45f].CGColor,
                       (id)[UIColor colorWithWhite:1.0f alpha:0.0f].CGColor, nil];
    CGFloat locations[] = { 0.0f, 1.0f };
    CGGradientRef gradient = CGGradientCreateWithColors(colorspace,
                                                       (__bridge CFArrayRef)colors,
                                                       locations);
    CGPoint start = CGPointMake(CGRectGetMidX(glossRect), CGRectGetMinY(glossRect));
    CGPoint end   = CGPointMake(CGRectGetMidX(glossRect), CGRectGetMaxY(glossRect));
    CGContextSaveGState(ctx);
    CGContextAddRect(ctx, glossRect);
    CGContextClip(ctx);
    CGContextDrawLinearGradient(ctx, gradient, start, end, 0);
    CGContextRestoreGState(ctx);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(colorspace);
}

+ (void)drawInnerHighlightInRect:(CGRect)rect context:(CGContextRef)ctx
{
    // 1px white line 1pt inside the top edge — gives the pressed-in feel.
    if (!ctx) return;
    CGContextSaveGState(ctx);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0f alpha:0.55f].CGColor);
    CGContextSetLineWidth(ctx, 1.0f);
    CGContextMoveToPoint(ctx, rect.origin.x + 1.5f, rect.origin.y + 1.5f);
    CGContextAddLineToPoint(ctx, rect.origin.x + rect.size.width - 1.5f, rect.origin.y + 1.5f);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
}

+ (void)drawOuterHairlineInRect:(CGRect)rect context:(CGContextRef)ctx color:(UIColor *)color
{
    if (!ctx || !color) return;
    CGContextSaveGState(ctx);
    CGContextSetStrokeColorWithColor(ctx, color.CGColor);
    CGContextSetLineWidth(ctx, 1.0f);
    CGRect strokeRect = CGRectInset(rect, 0.5f, 0.5f);
    CGContextAddRect(ctx, strokeRect);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
}

+ (void)fillRoundedButtonBackgroundInRect:(CGRect)rect
                                   context:(CGContextRef)ctx
                                  tintColor:(UIColor *)tint
                                 highlighted:(BOOL)highlighted
{
    if (!ctx || !tint) return;
    CGFloat radius = 8.0f;
    CGContextSaveGState(ctx);
    UIBezierPath *roundedPath = [UIBezierPath bezierPathWithRoundedRect:rect
                                                            cornerRadius:radius];
    CGContextAddPath(ctx, [roundedPath CGPath]);
    CGContextClip(ctx);

    // Base gradient: tint top lighter, bottom darker.
    UIColor *top = [tint respondsToSelector:@selector(highlightedColor)] ? tint : tint;
    UIColor *bottom = [self _darker:tint by:0.25f];

    [self drawLinearGradientInRect:rect context:ctx
                          topColor:top bottomColor:bottom];

    // Gloss sheen.
    [self drawGlossInRect:rect context:ctx];

    // If highlighted, dim slightly to suggest press.
    if (highlighted) {
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0f alpha:0.15f].CGColor);
        CGContextFillRect(ctx, rect);
    }
    CGContextRestoreGState(ctx);

    // Hairline border in a deeper tint.
    [self drawOuterHairlineInRect:rect context:ctx color:[self _darker:tint by:0.45f]];
}

+ (UIColor *)darkerColor:(UIColor *)color by:(CGFloat)amount
{
    // Quick-and-dirty HSB-darken helper.
    if (!color) return nil;
    CGFloat h, s, b, a;
    [color getHue:&h saturation:&s brightness:&b alpha:&a];
    b = MAX(0.0f, b - amount);
    return [UIColor colorWithHue:h saturation:s brightness:b alpha:a];
}

// Back-compat alias for the underscore-prefixed name used internally.
+ (UIColor *)_darker:(UIColor *)color by:(CGFloat)amount
{
    return [self darkerColor:color by:amount];
}

#pragma mark - UIKit chrome styling

+ (void)styleNavigationController:(UINavigationController *)nav
                            title:(NSString *)title
                       systemIcon:(UITabBarSystemItem)systemIcon
{
    if (!nav) return;
    nav.navigationBar.barStyle = UIBarStyleDefault;       // gives the iOS 6 gradient look
    nav.navigationBar.tintColor = [self tintColor];
    nav.tabBarItem = [[[UITabBarItem alloc] initWithTabBarSystemItem:systemIcon tag:0] autorelease];
    nav.tabBarItem.title = title;
    nav.navigationBar.translucent = NO;

    // On iOS 6, set title through the top VC.
    nav.topViewController.title = title;
}

+ (void)styleTabBarController:(UITabBarController *)tbc
{
    if (!tbc) return;
    // tabBar.barStyle is iOS 7+; on iOS 6 the barStyle is not settable
    // via the property. Use performSelector:withObject: to avoid a
    // compile-time error against the iOS 6 SDK where the property
    // doesn't exist.
    if ([tbc.tabBar respondsToSelector:@selector(setBarStyle:)]) {
        [tbc.tabBar performSelector:@selector(setBarStyle:)
                         withObject:@(UIBarStyleDefault)];
    }
    tbc.tabBar.tintColor = [self tintColor];
}

@end

//
//  iOS6Theme.m
//  iOS6AIChat
//
//  Dynamic theme with:
//    - Light palette: warm parchment + aged-leather bronze
//    - Dark palette:  deep charcoal + warm amber gold
//    - Font size scaling persisted across launches
//
//  The palette deliberately avoids the original "iOS 6 vivid blue" —
//  the user requested a more premium (高级) look. The bronze + parchment
//  combo evokes old leather-bound books and aged metal, which suits the
//  skeuomorphic intent.
//

#import "iOS6Theme.h"

// UserDefaults keys.
static NSString * const kUDKeyDarkMode  = @"theme.darkMode";
static NSString * const kUDKeyFontSize = @"theme.fontSize";

// Font size multipliers.
static CGFloat const kFontScale[] = { 0.85f, 1.0f, 1.15f, 1.3f, 1.5f };

// Light palette — warm parchment + bronze.
static NSString * const kHexLightTint           = @"#8B5A2B";   // aged-leather bronze
static NSString * const kHexLightNavbarTop      = @"#B8895A";   // warm tan
static NSString * const kHexLightNavbarBottom   = @"#5A3818";   // dark leather
static NSString * const kHexLightTabbarTop      = @"#EAE0CD";   // cream
static NSString * const kHexLightTabbarBottom   = @"#A89A82";   // tan-grey
static NSString * const kHexLightPinstripe      = @"#F4ECDC";   // very light cream
static NSString * const kHexLightPinstripeBG    = @"#E8DFC9";   // warm beige
static NSString * const kHexLightBubbleUser     = @"#E8DDC8";   // soft beige
static NSString * const kHexLightBubbleUserB    = @"#7A5A38";   // bronze border
static NSString * const kHexLightBubbleAI       = @"#FBF6EA";   // near-white cream
static NSString * const kHexLightBubbleAIB      = @"#B0A48C";   // soft tan border
static NSString * const kHexLightText           = @"#1F1A14";   // warm black
static NSString * const kHexLightTextSecondary  = @"#6B5D4A";   // warm grey
static NSString * const kHexLightCodeBG         = @"#F2EBD9";   // soft cream
static NSString * const kHexLightCodeBorder     = @"#B0A48C";

// Dark palette — deep charcoal + warm amber gold.
static NSString * const kHexDarkTint            = @"#D4A661";   // amber gold
static NSString * const kHexDarkNavbarTop       = @"#2C2C2C";   // dark grey
static NSString * const kHexDarkNavbarBottom    = @"#0F0F0F";   // near-black
static NSString * const kHexDarkTabbarTop        = @"#1F1F1F";
static NSString * const kHexDarkTabbarBottom     = @"#0A0A0A";
static NSString * const kHexDarkPinstripe        = @"#252525";
static NSString * const kHexDarkPinstripeBG     = @"#1A1A1A";
static NSString * const kHexDarkBubbleUser      = @"#3A2A1A";   // dark warm brown
static NSString * const kHexDarkBubbleUserB     = @"#8B5A2B";
static NSString * const kHexDarkBubbleAI        = @"#2A2A2A";   // dark grey
static NSString * const kHexDarkBubbleAIB       = @"#5A5A5A";
static NSString * const kHexDarkText            = @"#F5EFE0";   // warm cream
static NSString * const kHexDarkTextSecondary   = @"#A8A098";
static NSString * const kHexDarkCodeBG          = @"#252525";
static NSString * const kHexDarkCodeBorder      = @"#3A3A3A";

@implementation iOS6Theme

#pragma mark - Mode toggles

+ (BOOL)isDarkMode
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:kUDKeyDarkMode];
}

+ (void)setDarkMode:(BOOL)enabled
{
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kUDKeyDarkMode];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (iOS6ThemeFontSize)fontSize
{
    NSInteger v = [[NSUserDefaults standardUserDefaults] integerForKey:kUDKeyFontSize];
    if (v < 0 || v > 4) v = 1; // default medium
    return (iOS6ThemeFontSize)v;
}

+ (void)setFontSize:(iOS6ThemeFontSize)size
{
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)size forKey:kUDKeyFontSize];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (CGFloat)fontPointSizeForBase:(CGFloat)base
{
    iOS6ThemeFontSize fs = [self fontSize];
    CGFloat scale = kFontScale[(NSInteger)fs];
    CGFloat pt = base * scale;
    // Round to nearest 0.5pt for crisp rendering.
    return (CGFloat)((int)(pt * 2.0f + 0.5f)) / 2.0f;
}

#pragma mark - Palette resolver

// Pick light or dark hex based on current mode.
+ (UIColor *)_colorLight:(NSString *)lightHex dark:(NSString *)darkHex
{
    return [self isDarkMode]
            ? [self colorWithHex:darkHex]
            : [self colorWithHex:lightHex];
}

+ (UIColor *)tintColor             { return [self _colorLight:kHexLightTint           dark:kHexDarkTint]; }
+ (UIColor *)navbarTopColor        { return [self _colorLight:kHexLightNavbarTop      dark:kHexDarkNavbarTop]; }
+ (UIColor *)navbarBottomColor     { return [self _colorLight:kHexLightNavbarBottom   dark:kHexDarkNavbarBottom]; }
+ (UIColor *)tabbarTopColor        { return [self _colorLight:kHexLightTabbarTop      dark:kHexDarkTabbarTop]; }
+ (UIColor *)tabbarBottomColor     { return [self _colorLight:kHexLightTabbarBottom   dark:kHexDarkTabbarBottom]; }
+ (UIColor *)pinstripeColor        { return [self _colorLight:kHexLightPinstripe      dark:kHexDarkPinstripe]; }
+ (UIColor *)pinstripeBackground    { return [self _colorLight:kHexLightPinstripeBG   dark:kHexDarkPinstripeBG]; }
+ (UIColor *)bubbleUserColor       { return [self _colorLight:kHexLightBubbleUser     dark:kHexDarkBubbleUser]; }
+ (UIColor *)bubbleUserBorderColor { return [self _colorLight:kHexLightBubbleUserB    dark:kHexDarkBubbleUserB]; }
+ (UIColor *)bubbleAssistantColor  { return [self _colorLight:kHexLightBubbleAI       dark:kHexDarkBubbleAI]; }
+ (UIColor *)bubbleAssistantBorderColor { return [self _colorLight:kHexLightBubbleAIB dark:kHexDarkBubbleAIB]; }
+ (UIColor *)textColor             { return [self _colorLight:kHexLightText           dark:kHexDarkText]; }
+ (UIColor *)secondaryTextColor    { return [self _colorLight:kHexLightTextSecondary   dark:kHexDarkTextSecondary]; }
+ (UIColor *)codeBackgroundColor   { return [self _colorLight:kHexLightCodeBG          dark:kHexDarkCodeBG]; }
+ (UIColor *)codeBorderColor       { return [self _colorLight:kHexLightCodeBorder     dark:kHexDarkCodeBorder]; }

#pragma mark - Hex / colour helpers

+ (UIColor *)colorWithHex:(NSString *)hex
{
    if (!hex || hex.length == 0) return [UIColor blackColor];
    NSString *s = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
    if (s.length != 6) return [UIColor blackColor];

    unsigned rgb = 0;
    NSScanner *sc = [NSScanner scannerWithString:s];
    [sc scanHexInt:&rgb];

    CGFloat r = ((rgb >> 16) & 0xFF) / 255.0f;
    CGFloat g = ((rgb >> 8)  & 0xFF) / 255.0f;
    CGFloat b = ( rgb        & 0xFF) / 255.0f;
    return [UIColor colorWithRed:r green:g blue:b alpha:1.0f];
}

+ (NSString *)hexFromColor:(UIColor *)color
{
    if (!color) return @"#000000";
    CGFloat r, g, b, a;
    [color getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"#%02X%02X%02X",
            (unsigned)(r * 255.0f + 0.5f),
            (unsigned)(g * 255.0f + 0.5f),
            (unsigned)(b * 255.0f + 0.5f)];
}

+ (UIColor *)darkerColor:(UIColor *)color by:(CGFloat)amount
{
    if (!color) return nil;
    CGFloat h, s, b, a;
    [color getHue:&h saturation:&s brightness:&b alpha:&a];
    b = MAX(0.0f, b - amount);
    return [UIColor colorWithHue:h saturation:s brightness:b alpha:a];
}

+ (UIColor *)_darker:(UIColor *)color by:(CGFloat)amount { return [self darkerColor:color by:amount]; }

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

    UIColor *top = tint;
    UIColor *bottom = [self darkerColor:tint by:0.25f];

    [self drawLinearGradientInRect:rect context:ctx
                          topColor:top bottomColor:bottom];
    [self drawGlossInRect:rect context:ctx];

    if (highlighted) {
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0f alpha:0.15f].CGColor);
        CGContextFillRect(ctx, rect);
    }
    CGContextRestoreGState(ctx);
    [self drawOuterHairlineInRect:rect context:ctx color:[self darkerColor:tint by:0.45f]];
}

#pragma mark - UIKit chrome styling

+ (void)styleNavigationController:(UINavigationController *)nav
                            title:(NSString *)title
                       systemIcon:(UITabBarSystemItem)systemIcon
{
    if (!nav) return;
    nav.navigationBar.barStyle = UIBarStyleDefault;
    nav.navigationBar.tintColor = [self tintColor];
    nav.tabBarItem = [[[UITabBarItem alloc] initWithTabBarSystemItem:systemIcon tag:0] autorelease];
    nav.tabBarItem.title = title;
    nav.navigationBar.translucent = NO;
    nav.topViewController.title = title;
}

+ (void)styleTabBarController:(UITabBarController *)tbc
{
    if (!tbc) return;
    if ([tbc.tabBar respondsToSelector:@selector(setBarStyle:)]) {
        [tbc.tabBar performSelector:@selector(setBarStyle:)
                         withObject:@(UIBarStyleDefault)];
    }
    tbc.tabBar.tintColor = [self tintColor];
}

@end

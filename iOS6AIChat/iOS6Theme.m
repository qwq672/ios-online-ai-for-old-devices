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

// Light palette — cool off-white + deep emerald accent.
// Deliberately NOT all-warm per user feedback ("不是只要是暖色就高级").
// The deep emerald accent on a cool grey background gives a more
// sophisticated "professional journal" look — distinct from the
// bronze-on-cream warmth of the previous iteration.
static NSString * const kHexLightTint           = @"#007AFF";  // iOS standard blue   // deep emerald (sophisticated, not bright)
static NSString * const kHexLightNavbarTop      = @"#FFFFFF";  // white panel   // emerald (slightly brighter on top)
static NSString * const kHexLightNavbarBottom   = @"#E8E8E8";  // light grey bottom   // dark emerald
static NSString * const kHexLightTabbarTop      = @"#FFFFFF";  // white   // cool cream
static NSString * const kHexLightTabbarBottom   = @"#D0D0D0";  // light grey   // cool grey
static NSString * const kHexLightPinstripe      = @"#F7F7F7";  // near-white  // muted   // very pale cool
static NSString * const kHexLightPinstripeBG    = @"#EFEFEF";  // light grey bg  // muted cool grey   // soft cool grey
static NSString * const kHexLightBubbleUser     = @"#DCF8C6";  // iMessage green   // pale emerald-tinted
static NSString * const kHexLightBubbleUserB    = @"#A8D8A0";  // green border   // emerald border
static NSString * const kHexLightBubbleAI       = @"#FFFFFF";  // white   // near-white
static NSString * const kHexLightBubbleAIB      = @"#D0D0D0";  // grey border   // soft cool grey border
static NSString * const kHexLightText           = @"#000000";  // black  // darker for contrast   // deep navy-charcoal
static NSString * const kHexLightTextSecondary  = @"#666666";  // grey  // darker secondary   // cool grey
static NSString * const kHexLightCodeBG         = @"#F5F5F5";  // light grey   // pale cool grey
static NSString * const kHexLightCodeBorder     = @"#D0D0D0";

// Dark palette — deep navy-charcoal + warm amber accent.
// The amber-on-charcoal contrast creates the "Rolex boutique" feel.
static NSString * const kHexDarkTint            = @"#0A84FF";  // iOS dark blue  // muted amber (less bright)   // warm amber gold
static NSString * const kHexDarkNavbarTop       = @"#1C1C1E";  // near-black   // dark navy-charcoal
static NSString * const kHexDarkNavbarBottom    = @"#000000";  // black   // near-black navy
static NSString * const kHexDarkTabbarTop        = @"#1C1C1E";  // near-black
static NSString * const kHexDarkTabbarBottom     = @"#000000";  // black
static NSString * const kHexDarkPinstripe        = @"#2C2C2E";  // dark grey
static NSString * const kHexDarkPinstripeBG     = @"#1C1C1E";  // near-black bg  // darker
static NSString * const kHexDarkBubbleUser      = @"#2C2C2E";  // dark grey  // darker   // deep emerald-tinted charcoal
static NSString * const kHexDarkBubbleUserB     = @"#48484A";  // grey border
static NSString * const kHexDarkBubbleAI        = @"#1C1C1E";  // near-black  // darker   // charcoal
static NSString * const kHexDarkBubbleAIB       = @"#48484A";  // grey border
static NSString * const kHexDarkText            = @"#FFFFFF";  // white  // less bright cream   // warm cream
static NSString * const kHexDarkTextSecondary   = @"#8E8E93";  // iOS grey
static NSString * const kHexDarkCodeBG          = @"#2C2C2E";  // dark grey
static NSString * const kHexDarkCodeBorder      = @"#48484A";

// Additional dark/light form-control colors for dark mode UI fix.
// Light: standard iOS form controls (white bg / light grey)
// Dark:  visible dark fill so text and controls aren't washed out.
static NSString * const kHexLightInputBG         = @"#FFFFFF";
static NSString * const kHexLightInputBorder     = @"#C8C8C8";
static NSString * const kHexLightInputText       = @"#000000";
static NSString * const kHexLightPlaceholder      = @"#999999";
static NSString * const kHexLightControlBG       = @"#EFEFEF";
static NSString * const kHexLightControlSel      = @"#FFFFFF";
static NSString * const kHexLightControlNorm     = @"#E0E0E0";
static NSString * const kHexLightHairline        = @"#D0D0D0";
static NSString * const kHexLightButtonBG        = @"#FFFFFF";
static NSString * const kHexLightButtonSel       = @"#D0D0D0";
static NSString * const kHexLightThinkingBG      = @"#F7F7F7";
static NSString * const kHexLightThinkingBorder  = @"#C8C8C8";

static NSString * const kHexDarkInputBG          = @"#2C2C2E";   // mid-dark fill — visible against #1C1C1E bg
static NSString * const kHexDarkInputBorder      = @"#48484A";
static NSString * const kHexDarkInputText        = @"#FFFFFF";
static NSString * const kHexDarkPlaceholder       = @"#8E8E93";
static NSString * const kHexDarkControlBG        = @"#1C1C1E";
static NSString * const kHexDarkControlSel        = @"#48484A";
static NSString * const kHexDarkControlNorm      = @"#2C2C2E";
static NSString * const kHexDarkHairline         = @"#48484A";
static NSString * const kHexDarkButtonBG         = @"#2C2C2E";
static NSString * const kHexDarkButtonSel        = @"#48484A";
static NSString * const kHexDarkThinkingBG       = @"#2C2C2E";
static NSString * const kHexDarkThinkingBorder   = @"#48484A";

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
    // Notify all subscribers (AppDelegate, all VCs) so they can re-style
    // navbar / tabbar / table views with the new palette.
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"iOS6ThemeDidChangeNotification"
                        object:nil];
}

+ (iOS6ThemeFontSize)fontSize
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    // On first launch (no stored value), default to Medium (1.0x).
    // Otherwise: clamp to valid range.
    if (![d objectForKey:kUDKeyFontSize]) return iOS6ThemeFontSizeMedium;
    NSInteger v = [d integerForKey:kUDKeyFontSize];
    if (v < 0 || v > 4) return iOS6ThemeFontSizeMedium;
    return (iOS6ThemeFontSize)v;
}

+ (void)setFontSize:(iOS6ThemeFontSize)size
{
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)size forKey:kUDKeyFontSize];
    [[NSUserDefaults standardUserDefaults] synchronize];
    // Same notification — fontSize change should refresh all visible views.
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"iOS6ThemeDidChangeNotification"
                        object:nil];
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

#pragma mark - Form control colors

+ (UIColor *)inputFieldBackgroundColor  { return [self _colorLight:kHexLightInputBG       dark:kHexDarkInputBG]; }
+ (UIColor *)inputFieldBorderColor      { return [self _colorLight:kHexLightInputBorder  dark:kHexDarkInputBorder]; }
+ (UIColor *)inputFieldTextColor        { return [self _colorLight:kHexLightInputText    dark:kHexDarkInputText]; }
+ (UIColor *)inputFieldPlaceholderColor { return [self _colorLight:kHexLightPlaceholder   dark:kHexDarkPlaceholder]; }
+ (UIColor *)controlBackgroundColor      { return [self _colorLight:kHexLightControlBG   dark:kHexDarkControlBG]; }
+ (UIColor *)controlSelectedBackgroundColor { return [self _colorLight:kHexLightControlSel dark:kHexDarkControlSel]; }
+ (UIColor *)controlNormalBackgroundColor  { return [self _colorLight:kHexLightControlNorm dark:kHexDarkControlNorm]; }
+ (UIColor *)hairlineColor              { return [self _colorLight:kHexLightHairline     dark:kHexDarkHairline]; }
+ (UIColor *)buttonBackgroundColor      { return [self _colorLight:kHexLightButtonBG     dark:kHexDarkButtonBG]; }
+ (UIColor *)buttonSelectedBackgroundColor { return [self _colorLight:kHexLightButtonSel dark:kHexDarkButtonSel]; }
+ (UIColor *)thinkingBackgroundColor    { return [self _colorLight:kHexLightThinkingBG   dark:kHexDarkThinkingBG]; }
+ (UIColor *)thinkingBorderColor        { return [self _colorLight:kHexLightThinkingBorder dark:kHexDarkThinkingBorder]; }

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
    // barStyle drives the navbar background colour:
    //   UIBarStyleDefault = light (iOS 6 stock)
    //   UIBarStyleBlack   = dark (matches our dark palette)
    nav.navigationBar.barStyle = [self isDarkMode] ? UIBarStyleBlack : UIBarStyleDefault;
    nav.navigationBar.tintColor = [self tintColor];
    nav.tabBarItem = [[[UITabBarItem alloc] initWithTabBarSystemItem:systemIcon tag:0] autorelease];
    nav.tabBarItem.title = title;
    nav.navigationBar.translucent = NO;
    nav.topViewController.title = title;
}

+ (void)styleTabBarController:(UITabBarController *)tbc
{
    if (!tbc) return;
    // tabbar.barStyle is iOS 7+, but tintColor (which controls the selected
    // item colour) is iOS 4+ and works on iOS 6.
    if ([tbc.tabBar respondsToSelector:@selector(setBarStyle:)]) {
        UIBarStyle style = [self isDarkMode] ? UIBarStyleBlack : UIBarStyleDefault;
        [tbc.tabBar performSelector:@selector(setBarStyle:)
                         withObject:@(style)];
    }
    tbc.tabBar.tintColor = [self tintColor];
    // On iOS 6, force a re-layout so the barStyle/tintColor changes
    // become visible immediately.
    [tbc.tabBar setNeedsDisplay];
    [tbc.tabBar setNeedsLayout];
}

@end

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

// Light palette — iOS standard blue accent on cool off-white.
// Reverted from v261018-10's monochrome (white tint) — user said
// "浅色配色仍用之前的蓝色" (light color scheme still uses previous blue).
static NSString * const kHexLightTint           = @"#007AFF";  // iOS standard blue (reverted from #FFFFFF)
static NSString * const kHexLightNavbarTop      = @"#FFFFFF";
static NSString * const kHexLightNavbarBottom   = @"#E8E8E8";
static NSString * const kHexLightTabbarTop      = @"#FFFFFF";
static NSString * const kHexLightTabbarBottom   = @"#D0D0D0";
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

// Dark palette — DEEP navy blue tint on near-BLACK grey background.
// v261018-12: reverted from #000000 (black) tint back to deep navy
// #1E3A8A (user said "醒目色仍为蓝色"). BUT the BACKGROUND is now
// much darker — near-black grey (#0A0A0A) instead of navy-black
// (#0F1A2E). This gives a true "dark mode" feel rather than the
// previous navy-tinted dark mode.
static NSString * const kHexDarkTint            = @"#1E3A8A";  // deep navy (reverted from #000000)
static NSString * const kHexDarkNavbarTop       = @"#0A0A0A";  // near-black grey (was #0F1A2E navy-black)
static NSString * const kHexDarkNavbarBottom    = @"#000000";  // pure black
static NSString * const kHexDarkTabbarTop        = @"#0A0A0A";  // near-black grey
static NSString * const kHexDarkTabbarBottom     = @"#000000";  // pure black
static NSString * const kHexDarkPinstripe        = @"#1A1A1A";  // dark grey (was #1A2540 navy-grey)
static NSString * const kHexDarkPinstripeBG     = @"#0A0A0A";  // near-black bg (was #0F1A2E navy-black)
static NSString * const kHexDarkBubbleUser      = @"#1A1A1A";  // dark grey (was #1E3A5F navy-tinted)
static NSString * const kHexDarkBubbleUserB     = @"#2A2A2A";  // grey border (was #2E4A7F navy)
static NSString * const kHexDarkBubbleAI        = @"#0F0F0F";  // near-black (was #0F1A2E navy-black)
static NSString * const kHexDarkBubbleAIB       = @"#2A2A2A";  // grey border (was #2E4A7F)
static NSString * const kHexDarkText            = @"#E8E8F0";  // off-white with slight cool tint
static NSString * const kHexDarkTextSecondary   = @"#8B95B0";  // muted blue-grey
static NSString * const kHexDarkCodeBG          = @"#1A1A1A";  // dark grey code bg
static NSString * const kHexDarkCodeBorder      = @"#2A2A2A";

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

static NSString * const kHexDarkInputBG          = @"#1A1A1A";   // dark grey fill (was navy)
static NSString * const kHexDarkInputBorder      = @"#2A2A2A";
static NSString * const kHexDarkInputText        = @"#E8E8F0";
static NSString * const kHexDarkPlaceholder       = @"#8B95B0";
static NSString * const kHexDarkControlBG        = @"#0A0A0A";
static NSString * const kHexDarkControlSel        = @"#1E3A8A";   // selected = deep navy tint
static NSString * const kHexDarkControlNorm      = @"#1A1A1A";
static NSString * const kHexDarkHairline         = @"#2A2A2A";
static NSString * const kHexDarkButtonBG         = @"#1A1A1A";
static NSString * const kHexDarkButtonSel        = @"#1E3A8A";   // active button = deep navy tint
static NSString * const kHexDarkThinkingBG       = @"#1A1A1A";
static NSString * const kHexDarkThinkingBorder   = @"#2A2A2A";

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
    // Rich grey bar background — 1px top highlight + 3-stop gradient +
    // 1px bottom shadow (App Store / Music style, NO blue system tint).
    UIImage *navBg = [self barBackgroundImageWithHeight:44];
    if (navBg) {
        [nav.navigationBar setBackgroundImage:navBg forBarMetrics:UIBarMetricsDefault];
    }
    nav.navigationBar.barStyle = [self isDarkMode] ? UIBarStyleBlack : UIBarStyleDefault;
    nav.navigationBar.tintColor = [self barItemTintColor];
    nav.tabBarItem = [[[UITabBarItem alloc] initWithTabBarSystemItem:systemIcon tag:0] autorelease];
    nav.tabBarItem.title = title;
    nav.navigationBar.translucent = NO;
    nav.topViewController.title = title;
}

+ (void)styleTabBarController:(UITabBarController *)tbc
{
    if (!tbc) return;
    // Rich bar background — matches the App Store tab bar pixel structure:
    //   content edge → 1px bright highlight → 1px near-black bevel line →
    //   3-stop gradient (#454545 → #2A2A2C → #131313 in dark mode).
    UIImage *bg = [self barBackgroundImageWithHeight:49];
    if (bg && [tbc.tabBar respondsToSelector:@selector(setBackgroundImage:)]) {
        [tbc.tabBar performSelector:@selector(setBackgroundImage:) withObject:bg];
    }

    // Kill the system's selected-item background highlight (the lighter
    // block behind the active tab). The App Store shows NO highlight —
    // selection is carried by the saturated blue icon + bright label only.
    // A fully transparent selectionIndicatorImage suppresses the default.
    if ([tbc.tabBar respondsToSelector:@selector(setSelectionIndicatorImage:)]) {
        UIImage *empty = [self _transparentImage1x1];
        if (empty) {
            [tbc.tabBar performSelector:@selector(setSelectionIndicatorImage:)
                              withObject:empty];
        }
    }

    // Also set barStyle via NSInvocation (pointer-arg safe on iOS 6).
    if ([tbc.tabBar respondsToSelector:@selector(setBarStyle:)]) {
        UIBarStyle style = [self isDarkMode] ? UIBarStyleBlack : UIBarStyleDefault;
        NSMethodSignature *sig = [tbc.tabBar methodSignatureForSelector:@selector(setBarStyle:)];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:tbc.tabBar];
            [inv setSelector:@selector(setBarStyle:)];
            [inv setArgument:&style atIndex:2];
            [inv invoke];
        }
    }

    // Selected tab tint — saturated iOS blue (App Store samples ~#3FA8E8).
    // This is what the washed-out pale-blue selected icon was missing.
    tbc.tabBar.tintColor = [self tabBarSelectedTintColor];

    // Label colors per item (normal state; selected handled below).
    for (UINavigationController *nav in tbc.viewControllers) {
        [self styleTabBarItem:((UINavigationController *)nav).tabBarItem];
    }

    [tbc.tabBar setNeedsDisplay];
    [tbc.tabBar setNeedsLayout];
}

// Style a single tab item's label. Normal state: bright readable grey
// (App Store samples ~#C8C8C8 on the black bar — much brighter than the
// murky default). Selected state: white (dark) / blue (light); if iOS 6
// ignores the selected-state dictionary the label simply follows the tab
// bar tint, which is still authentic.
+ (void)styleTabBarItem:(UITabBarItem *)item
{
    if (!item) return;
    @try {
        NSDictionary *normal = @{
            NSForegroundColorAttributeName: [self tabBarNormalTitleColor]
        };
        [item setTitleTextAttributes:normal forState:UIControlStateNormal];
        NSDictionary *sel = @{
            NSForegroundColorAttributeName: [self tabBarSelectedTitleColor]
        };
        [item setTitleTextAttributes:sel forState:UIControlStateSelected];
    } @catch (NSException *e) {
        // Unsupported on this OS — fall back to tint-colored labels.
    }
}

#pragma mark - iOS 6 bar drawing (App Store / Music reference)

// Rich bar background image, replicating the pixel structure of the iOS 6
// App Store tab bar (measured from reference screenshots):
//
//   row 0     1px top highlight   ~#C4C4C4 (white @ 0.65 over dark) 
//   row 1     1px bevel line      ~#0E0E0E (near-black)
//   rows 2..H 3-stop gradient     #454545 → #2A2A2C(45%) → #131313
//   last row  1px bottom shadow   pure black
//
// Light mode mirrors the Music app's silver bar:
//   #FAFAFB → #DEDEE0(50%) → #B4B4B9 + white top line + #8E8E93 shadow.
//
// The image is 1pt wide (stretched horizontally by UIKit); height is exact
// so the 1px lines stay crisp at any device scale.
+ (UIImage *)barBackgroundImageWithHeight:(CGFloat)height
{
    CGFloat scale = [UIScreen mainScreen].scale;
    if (scale < 1) scale = 1;

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, height), NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }

    BOOL dark = [self isDarkMode];
    NSString *topHex    = dark ? @"#454545" : @"#FAFAFB";
    NSString *midHex    = dark ? @"#2A2A2C" : @"#DEDEE0";
    NSString *botHex    = dark ? @"#131313" : @"#B4B4B9";
    CGFloat midLocation = dark ? 0.45f : 0.50f;

    // --- 3-stop vertical gradient over the full height ---
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = [NSArray arrayWithObjects:
                       (id)[self colorWithHex:topHex].CGColor,
                       (id)[self colorWithHex:midHex].CGColor,
                       (id)[self colorWithHex:botHex].CGColor, nil];
    CGFloat locations[] = { 0.0f, midLocation, 1.0f };
    CGGradientRef grad = CGGradientCreateWithColors(space,
                                                    (__bridge CFArrayRef)colors,
                                                    locations);
    CGContextDrawLinearGradient(ctx, grad,
                                CGPointMake(0, 0),
                                CGPointMake(0, height), 0);
    CGGradientRelease(grad);
    CGColorSpaceRelease(space);

    // --- 1px top highlight line ---
    CGFloat lineH = 1.0f / scale;
    CGContextSetFillColorWithColor(ctx,
        [UIColor colorWithWhite:1.0f alpha:(dark ? 0.65f : 0.9f)].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, 1, lineH));

    // --- 1px bevel line right below the highlight (App Store look) ---
    CGContextSetFillColorWithColor(ctx,
        [UIColor colorWithWhite:0.0f alpha:(dark ? 0.85f : 0.12f)].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, lineH, 1, lineH));

    // --- 1px bottom shadow line ---
    CGContextSetFillColorWithColor(ctx,
        [UIColor colorWithWhite:0.0f alpha:(dark ? 1.0f : 0.35f)].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, height - lineH, 1, lineH));

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;  // autoreleased
}

// Legacy alias — kept for call sites written before the rework.
+ (UIImage *)_barGradientImageWithHeight:(CGFloat)height
{
    return [self barBackgroundImageWithHeight:height];
}

// 1x1 fully transparent image — used to suppress the system's selected-tab
// background highlight without falling back to the default indicator.
+ (UIImage *)_transparentImage1x1
{
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, 1), NO, 1);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0f alpha:0.0f].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, 1, 1));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;  // autoreleased
}

// --- Composer (input toolbar) colors ------------------------------------
// Slightly darker/flatter than the tab bar so the two chrome bands read
// as distinct pieces (iOS 6 Messages-style input toolbar).
+ (UIColor *)composerBarTopColor    { return [self _colorLight:@"#E4E4E6" dark:@"#333335"]; }
+ (UIColor *)composerBarBottomColor { return [self _colorLight:@"#CDCDD1" dark:@"#202022"]; }

// Input field: "inset black glass" — clearly darker than its bar.
+ (UIColor *)composerFieldBackgroundColor { return [self _colorLight:@"#FCFCFD" dark:@"#0E0E10"]; }
+ (UIColor *)composerFieldBorderColor     { return [self _colorLight:@"#A8A8AD" dark:@"#454548"]; }

// --- Tab bar selection colors (App Store reference) --------------------
+ (UIColor *)tabBarSelectedTintColor { return [self _colorLight:@"#3E7FD0" dark:@"#3FA8E8"]; }
+ (UIColor *)tabBarNormalTitleColor   { return [self _colorLight:@"#77777C" dark:@"#C8C8CC"]; }
+ (UIColor *)tabBarSelectedTitleColor { return [self _colorLight:@"#3E7FD0" dark:@"#F1F1F1"]; }

// --- Glassy composer button images --------------------------------------
// Neutral: bar-colored bordered glass (inactive toggles, camera).
// Accent:  saturated blue glass (send button, active toggles).
// Drawn once at the button's exact size — no stretching needed.
+ (UIImage *)glassButtonImageOfSize:(CGSize)size accent:(BOOL)accent
{
    if (size.width < 2 || size.height < 2) return nil;
    CGFloat scale = [UIScreen mainScreen].scale;
    if (scale < 1) scale = 1;
    UIGraphicsBeginImageContextWithOptions(size, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }

    BOOL dark = [self isDarkMode];
    CGFloat radius = 5.0f;
    CGRect rect = CGRectMake(0.5f, 0.5f, size.width - 1.0f, size.height - 1.0f);

    // Clip to rounded rect.
    CGContextSaveGState(ctx);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect
                                                     cornerRadius:radius];
    CGContextAddPath(ctx, path.CGPath);
    CGContextClip(ctx);

    // Vertical gradient body.
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    NSString *topHex, *botHex;
    if (accent) {
        topHex = @"#5BB4F2"; botHex = @"#2E7FD6";   // saturated blue glass
    } else {
        topHex = dark ? @"#3A3A3E" : @"#FDFDFD";      // neutral bar glass
        botHex = dark ? @"#232326" : @"#D8D8DC";
    }
    NSArray *colors = [NSArray arrayWithObjects:
                       (id)[self colorWithHex:topHex].CGColor,
                       (id)[self colorWithHex:botHex].CGColor, nil];
    CGFloat locations[] = { 0.0f, 1.0f };
    CGGradientRef grad = CGGradientCreateWithColors(space,
                                                    (__bridge CFArrayRef)colors,
                                                    locations);
    CGContextDrawLinearGradient(ctx, grad,
                                CGPointMake(0, 0), CGPointMake(0, size.height), 0);
    CGGradientRelease(grad);

    // Glossy top half.
    [self drawGlossInRect:CGRectMake(0, 0, size.width, size.height * 0.5f)
                  context:ctx];

    // Inner top highlight line.
    CGContextSetFillColorWithColor(ctx,
        [UIColor colorWithWhite:1.0f alpha:(accent ? 0.75f : 0.45f)].CGColor);
    CGContextFillRect(ctx, CGRectMake(1, 1, size.width - 2, 1.0f));

    CGColorSpaceRelease(space);
    CGContextRestoreGState(ctx);

    // Outer hairline border.
    UIColor *border = accent ? [self colorWithHex:@"#1C5AA0"]
                             : (dark ? [self colorWithHex:@"#55555A"]
                                     : [self colorWithHex:@"#A0A0A6"]);
    CGContextSetStrokeColorWithColor(ctx, border.CGColor);
    CGContextSetLineWidth(ctx, 1.0f);
    CGContextAddPath(ctx, path.CGPath);
    CGContextStrokePath(ctx);

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;  // autoreleased
}

// Tint color for bar ITEMS (navbar buttons).
// Light mode (Music app): steel blue #49627F — softer than iOS blue.
// Dark mode (App Store/iTunes): light grey #C8C8CC — no blue buttons
// on dark bars (user said blue navbar buttons look jarring).
+ (UIColor *)barItemTintColor
{
    return [self isDarkMode] ? [self colorWithHex:@"#C8C8CC"]
                              : [self colorWithHex:@"#49627F"];
}

@end

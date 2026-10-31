//
//  iOS6Theme.h
//  iOS6AIChat
//
//  Centralised visual primitives that recreate the iOS 6 "skeuomorphic"
//  look using only Core Graphics — no image assets required.
//
//  The theme is now DYNAMIC:
//    - Dark Mode toggle (persisted to NSUserDefaults)
//    - Font Size scaling (0.85x small / 1.0x default / 1.15x large /
//      1.3x x-large / 1.5x xx-large) for accessibility
//    - Premium palette: warm parchment + aged-leather bronze on light;
//      deep charcoal + warm amber on dark.
//

#import <UIKit/UIKit.h>

// v261025-31: runtime OS version check for dual-theme support.
// iOS 6 → skeuomorphic (gradients, textures, gloss).
// iOS 7+ → flat (solid colors, system defaults, no custom textures).
// Uses systemVersion (more reliable than NSFoundationVersionNumber which
// varies across iOS 7.x minor versions and may not match 1047.25 exactly).
static BOOL _iOS7OrLaterCache = NO;
static BOOL _iOS7CacheInit = NO;
static inline BOOL IsIOS7OrLater(void) {
    if (!_iOS7CacheInit) {
        _iOS7OrLaterCache = ([[[UIDevice currentDevice] systemVersion] floatValue] >= 7.0f);
        _iOS7CacheInit = YES;
        NSLog(@"[Theme] iOS version: %@, IsIOS7OrLater=%d",
              [[UIDevice currentDevice] systemVersion], _iOS7OrLaterCache);
    }
    return _iOS7OrLaterCache;
}

typedef enum {
    iOS6ThemeFontSizeSmall  = 0,  // 0.85x
    iOS6ThemeFontSizeMedium = 1,  // 1.0x
    iOS6ThemeFontSizeLarge  = 2,  // 1.15x
    iOS6ThemeFontSizeXLarge = 3,  // 1.3x
    iOS6ThemeFontSizeXXLarge = 4 // 1.5x
} iOS6ThemeFontSize;

@interface iOS6Theme : NSObject

// === Mode toggles (persisted to NSUserDefaults) =========================

// Dark mode — YES uses the dark palette, NO uses the light palette.
+ (BOOL)isDarkMode;
+ (void)setDarkMode:(BOOL)enabled;

// Font size scale (0.85x .. 1.5x). Persisted to NSUserDefaults.
+ (iOS6ThemeFontSize)fontSize;
+ (void)setFontSize:(iOS6ThemeFontSize)size;

// Convenience — returns base * scale, rounded to nearest 0.5pt.
+ (CGFloat)fontPointSizeForBase:(CGFloat)base;

// === Colours (auto-switches with dark mode) =============================

+ (UIColor *)tintColor;              // accent / buttons / links
+ (UIColor *)navbarTopColor;
+ (UIColor *)navbarBottomColor;
+ (UIColor *)tabbarTopColor;
+ (UIColor *)tabbarBottomColor;
+ (UIColor *)pinstripeColor;
+ (UIColor *)pinstripeBackground;
+ (UIColor *)bubbleUserColor;
+ (UIColor *)bubbleUserBorderColor;
+ (UIColor *)bubbleAssistantColor;
+ (UIColor *)bubbleAssistantBorderColor;
+ (UIColor *)textColor;
+ (UIColor *)secondaryTextColor;
+ (UIColor *)codeBackgroundColor;
+ (UIColor *)codeBorderColor;

// === Form / control colors (dark mode-aware) ===========================
// These cover UISegmentedControl, UIStepper, UITextField, UIButton etc.
// Without explicit colors, iOS 6 system controls fall back to light grey
// even in dark mode — making them invisible against the dark background.

+ (UIColor *)inputFieldBackgroundColor;        // text field / text view fill
+ (UIColor *)inputFieldBorderColor;            // text field / text view border
+ (UIColor *)inputFieldTextColor;              // text in input fields
+ (UIColor *)inputFieldPlaceholderColor;       // placeholder grey
+ (UIColor *)controlBackgroundColor;           // segmented / stepper background
+ (UIColor *)controlSelectedBackgroundColor;   // selected segment fill
+ (UIColor *)controlNormalBackgroundColor;     // unselected segment fill
+ (UIColor *)hairlineColor;                    // thin separator line
+ (UIColor *)buttonBackgroundColor;            // custom rounded button bg
+ (UIColor *)buttonSelectedBackgroundColor;    // pressed/selected state
+ (UIColor *)thinkingBackgroundColor;          // reasoning block bg (subtle)
+ (UIColor *)thinkingBorderColor;              // reasoning block border

// === iOS 6 bar system (App Store / Music style) ========================

// Rich bar background image: 1px top highlight line + 1px bevel dark line
// + 3-stop vertical gradient + 1px bottom shadow line.
// Dark (App Store black metal): #454545 → #2A2A2C → #131313
// Light (Music silver):         #FAFAFB → #DEDEE0 → #B4B4B9
+ (UIImage *)barBackgroundImageWithHeight:(CGFloat)height;

// Composer (input toolbar) bar colors — slightly darker/flatter than the
// tab bar so the two bands read as distinct chrome pieces (iOS 6 Messages
// style). Dark: #333335 → #202022; light: #E4E4E6 → #CDCDD1.
+ (UIColor *)composerBarTopColor;
+ (UIColor *)composerBarBottomColor;

// Composer input field — "inset black glass" look (darker than the bar).
+ (UIColor *)composerFieldBackgroundColor;
+ (UIColor *)composerFieldBorderColor;

// Tab bar selection colors (App Store reference):
//   selected icon  = saturated iOS blue (#3FA8E8 dark / #3E7FD0 light)
//   selected label = white (dark) / blue (light)
//   normal  label  = bright readable grey (NOT the murky default)
+ (UIColor *)tabBarSelectedTintColor;
+ (UIColor *)tabBarNormalTitleColor;
+ (UIColor *)tabBarSelectedTitleColor;

// Style one tab item (label colors). Call after creating each UITabBarItem.
+ (void)styleTabBarItem:(UITabBarItem *)item;

// Glassy button images for the composer (drawn once, reused):
//   neutral = bar-colored bordered glass; accent = saturated blue glass.
+ (UIImage *)glassButtonImageOfSize:(CGSize)size accent:(BOOL)accent;

// === v261025-4 skeuomorphic texture factories ===========================
// All images below are DRAWN ONCE and cached statically (flushed on theme
// change via flushThemeImageCache). They are pre-rendered so no per-frame
// CoreGraphics work happens during scrolling — this is the iPhone 3GS
// performance strategy: pay the texture cost once, blit forever after.

// Flush every cached texture (called automatically on dark-mode toggle;
// also call manually if you change anything that affects baked colors).
+ (void)flushThemeImageCache;

// Messages-style chat backdrop — fine paper texture as a repeating
// pattern color (light: dove-blue paper; dark: charcoal grain).
+ (UIColor *)chatBackgroundPatternColor;

// Pre-rendered STRETCHABLE chat bubble (iOS 6 Messages reference):
// gradient body + fixed-height gloss band + 1px inner top highlight +
// 1px border + baked soft drop shadow + tail (user: bottom-right,
// assistant: bottom-left). Use drawInRect: with the full bubble frame.
+ (UIImage *)stretchableBubbleImageForUser:(BOOL)isUser;

// Stretchable white "card" background for menu rows (rounded corners,
// hairline border, inner top highlight — iOS 6 grouped-card look).
+ (UIImage *)stretchableCardBackgroundImage;

// Stretchable recessed slot (dark inner shadow top, light inner line
// bottom) — search field + bottom strip backdrop on the menu sheet.
+ (UIImage *)stretchableRecessedSlotImage;

// Stretchable glass chip for the horizontally scrolling recent-
// conversation strip (like the Reminders date strip).
+ (UIImage *)stretchableGlassChipImage;

// Full-width leather top bar for the menu sheet (status bar + 44pt bar),
// with vertical gradient + noise grain + stitched bottom hairline.
+ (UIImage *)menuLeatherBarImage;

// Messages-green glossy send button (drawn at exact size like the other
// glass buttons — green glass + gloss + darker green hairline).
+ (UIImage *)greenGlassButtonImageOfSize:(CGSize)size;

// Internal: create a grey gradient bar background image.
// Called by AppDelegate for navbar, iOS6Theme for tabbar.
+ (UIImage *)_barGradientImageWithHeight:(CGFloat)height;

// Tint for bar items (navbar buttons, selected tab icon).
// Light: steel blue (Music app). Dark: light grey (App Store/iTunes).
+ (UIColor *)barItemTintColor;

// === Drawing helpers ===================================================

+ (void)drawLinearGradientInRect:(CGRect)rect
                          context:(CGContextRef)ctx
                          topColor:(UIColor *)top
                       bottomColor:(UIColor *)bottom;

+ (void)drawGlossInRect:(CGRect)rect context:(CGContextRef)ctx;
+ (void)drawInnerHighlightInRect:(CGRect)rect context:(CGContextRef)ctx;
+ (void)drawOuterHairlineInRect:(CGRect)rect context:(CGContextRef)ctx color:(UIColor *)color;

+ (void)fillRoundedButtonBackgroundInRect:(CGRect)rect
                                   context:(CGContextRef)ctx
                                  tintColor:(UIColor *)tint
                                 highlighted:(BOOL)highlighted;

// v261025-7: custom TRANSPARENT section header / footer views for grouped
// tables. iOS 6's system-drawn grouped headers/footers have an opaque
// LIGHT background strip — in dark mode these show up as jarring white
// bars behind the section titles (user-reported "每个文字都有白色背景").
// Every grouped table in the app now uses these instead of the plain
// titleForHeader/Footer strings.
+ (UIView *)groupedSectionHeaderViewWithTitle:(NSString *)title
                                        width:(CGFloat)width;
+ (UIView *)groupedSectionFooterViewWithTitle:(NSString *)title
                                        width:(CGFloat)width;
+ (CGFloat)groupedSectionFooterHeightForTitle:(NSString *)title
                                        width:(CGFloat)width;

// === UIKit chrome styling ==============================================

+ (void)styleNavigationController:(UINavigationController *)nav
                            title:(NSString *)title
                       systemIcon:(UITabBarSystemItem)systemIcon;

+ (void)styleTabBarController:(UITabBarController *)tbc;

// === Colour helpers ====================================================

+ (UIColor *)darkerColor:(UIColor *)color by:(CGFloat)amount;
+ (UIColor *)colorWithHex:(NSString *)hex;       // "#RRGGBB" / "RRGGBB"
+ (NSString *)hexFromColor:(UIColor *)color;

@end

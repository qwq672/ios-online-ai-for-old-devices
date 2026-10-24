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

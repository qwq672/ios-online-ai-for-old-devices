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
+ (UIColor *)buttonContentColor;      // text/icon on tint-button bg (inverse of tint)
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

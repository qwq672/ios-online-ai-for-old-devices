//
//  iOS6Theme.h
//  iOS6AIChat
//
//  Centralised visual primitives that recreate the iOS 6 "skeuomorphic"
//  look using only Core Graphics — no image assets required.
//
//  Reproduced elements:
//    - Linear gradients for navbars / tab bars (gloss on top, deep tint below)
//    - Outer hairline + inner highlight stroke
//    - The blue "iOS 6 button" gradient (top half lighter, bottom darker, 1px sheen)
//    - The grey "back" chevron button
//    - Chat bubble tails and the soft drop-shadow behind bubbles
//    - Pinstripe background like the old Settings app
//

#import <UIKit/UIKit.h>

@interface iOS6Theme : NSObject

// Colours
+ (UIColor *)tintColor;              // vivid iOS 6 blue
+ (UIColor *)navbarTopColor;        // top half of the navbar gradient
+ (UIColor *)navbarBottomColor;     // bottom half of the navbar gradient
+ (UIColor *)tabbarTopColor;
+ (UIColor *)tabbarBottomColor;
+ (UIColor *)pinstripeColor;
+ (UIColor *)pinstripeBackground;
+ (UIColor *)bubbleUserColor;       // light blue user bubble
+ (UIColor *)bubbleUserBorderColor;
+ (UIColor *)bubbleAssistantColor;  // off-white AI bubble
+ (UIColor *)bubbleAssistantBorderColor;
+ (UIColor *)textColor;
+ (UIColor *)secondaryTextColor;
+ (UIColor *)codeBackgroundColor;
+ (UIColor *)codeBorderColor;

// Drawing helpers
+ (void)drawLinearGradientInRect:(CGRect)rect
                          context:(CGContextRef)ctx
                          topColor:(UIColor *)top
                       bottomColor:(UIColor *)bottom;

+ (void)drawGlossInRect:(CGRect)rect context:(CGContextRef)ctx;
+ (void)drawInnerHighlightInRect:(CGRect)rect context:(CGContextRef)ctx;
+ (void)drawOuterHairlineInRect:(CGRect)rect context:(CGContextRef)ctx color:(UIColor *)color;

// Convenience — paint a styled rounded button background into a UIView
+ (void)fillRoundedButtonBackgroundInRect:(CGRect)rect
                                   context:(CGContextRef)ctx
                                  tintColor:(UIColor *)tint
                                 highlighted:(BOOL)highlighted;

// Style the stock UIKit chrome so it looks like iOS 6
+ (void)styleNavigationController:(UINavigationController *)nav
                            title:(NSString *)title
                       systemIcon:(UITabBarSystemItem)systemIcon;

+ (void)styleTabBarController:(UITabBarController *)tbc;

// Darken a colour by an HSB brightness delta — used by other views
// (e.g. ChatBubbleView) to derive the gradient bottom colour.
+ (UIColor *)darkerColor:(UIColor *)color by:(CGFloat)amount;

@end

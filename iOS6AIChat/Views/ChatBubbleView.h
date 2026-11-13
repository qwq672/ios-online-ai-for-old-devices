//
//  ChatBubbleView.h
//  iOS6AIChat
//
//  Self-drawn bubble — rounded rect with:
//     - gradient fill (user: light blue / assistant: off-white)
//     - 1px hairline border (user: deeper blue / assistant: grey)
//     - subtle drop shadow
//     - a tail nub at the bottom-right (user) or bottom-left (assistant)
//

#import <UIKit/UIKit.h>

typedef enum {
    BubbleRoleUser      = 0,
    BubbleRoleAssistant = 1,
    BubbleRoleError     = 2  // v261025-32: red-tinted error bubble
} BubbleRole;

@interface ChatBubbleView : UIView

@property (nonatomic, assign) BubbleRole role;
// v261025-32: when NO, drawRect is skipped (no gradient/tail/border).
// Used for AI messages in the new layout (Option ②: user-only bubbles).
@property (nonatomic, assign) BOOL drawBackground;

// v261114: AI document panel — solid fill, no tail, no gradient/gloss/
// shadow/outline. iOS 6 adds a 1px top inner shadow; iOS 7+ uses a flat
// surface with an optional left rail. This is a separate drawing path,
// NOT a bubble with tailSize=(0,0).
@property (nonatomic, assign) BOOL documentPanel;

// Convex corner radius; default 14.
@property (nonatomic, assign) CGFloat cornerRadius;

// Tail base width and height; default 10x6.
@property (nonatomic, assign) CGSize tailSize;

@end

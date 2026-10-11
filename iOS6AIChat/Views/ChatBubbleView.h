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
    BubbleRoleAssistant = 1
} BubbleRole;

@interface ChatBubbleView : UIView

@property (nonatomic, assign) BubbleRole role;

// Convex corner radius; default 14.
@property (nonatomic, assign) CGFloat cornerRadius;

// Tail base width and height; default 10x6.
@property (nonatomic, assign) CGSize tailSize;

@end

//
//  IconDrawing.h
//  iOS6AIChat
//
//  Pure CoreGraphics icon renderer — used for:
//    - Composer toggle buttons (DT / Web / Upload)
//    - Composer Send button (arrow)
//    - Tab bar custom icons (gear for Settings)
//
//  All icons are drawn as silhouettes in a single colour, so the caller
//  can reuse the same drawing for any tint by passing in the colour.
//

#import <UIKit/UIKit.h>

typedef enum {
    IconTypeLightbulb = 0,   // Deep Thinking
    IconTypeGlobe,            // Web Search
    IconTypeCamera,           // Image Upload
    IconTypeSendArrow,        // Send (paper plane / arrow)
    IconTypeGear,             // Settings
    IconTypeChatBubble,       // Chat
    IconTypeClock,            // History
    IconTypeRefresh,          // Regenerate reply (circular arrow)
    IconTypeCopy,             // Copy (two overlapping rectangles)
    IconTypeHamburger,        // Drawer menu (three horizontal lines)
    IconTypeLayers,           // Model management (stacked layers)
    IconTypePerson,           // Character management (person silhouette)
    IconTypeDoc,              // Log viewer (document with lines)
    IconTypeExport,           // v261025-6: Export conversations (downward arrow into tray)
} IconType;

@interface IconDrawing : NSObject

// Render an icon at the given size, in the given colour. The icon is
// a flat silhouette; transparency outside the silhouette.
+ (UIImage *)imageForType:(IconType)type
                     size:(CGSize)size
                    color:(UIColor *)color;

@end

//
//  Message.h
//  iOS6AIChat
//
//  A single chat message — role (user/assistant/system) + content +
//  timestamp. Conforms to NSCoding so a whole conversation can be
//  archived to disk with NSKeyedArchiver in one call.
//

#import <Foundation/Foundation.h>

typedef enum {
    MessageRoleUser      = 0,
    MessageRoleAssistant = 1,
    MessageRoleSystem    = 2
} MessageRole;

@interface Message : NSObject <NSCoding, NSCopying>

@property (nonatomic, assign) MessageRole role;
@property (nonatomic, copy)   NSString     *content;     // raw text or markdown
@property (nonatomic, copy)   NSString     *contentHTML; // optional: rendered HTML cache
@property (nonatomic, copy)   NSString     *thinking;    // AI reasoning content (separate from answer)
@property (nonatomic, retain) NSArray      *images;    // array of base64 data URLs for vision API
@property (nonatomic, strong) NSDate       *createdAt;
@property (nonatomic, copy)   NSString     *messageID;   // UUID

// v261025-8: image-generation result. When the composer's 生图 toggle is
// ON, the send path calls the image-generation API instead of the chat
// stream; the returned PNG is written to Documents/genimg/<file> and this
// field holds the FILE NAME (not a full path — the sandbox container
// changes between app updates). The message renders as an image bubble.
// content (if non-empty) renders as a small caption under the image
// (typically the prompt the user typed).
@property (nonatomic, copy)   NSString     *generatedImagePath;

// v261025-6: variant pager — when the user taps "重新生成", the OLD AI
// response (content + thinking) is snapshot into a variant dict and pushed
// onto `variants`. The user can then navigate ‹ 1/N › to compare responses.
// Only meaningful for assistant messages; user messages ignore these fields.
//
// Variant dict shape: { @"content": NSString, @"thinking": NSString }
// `currentVariantIndex` = -1 means "show the LIVE content (the latest variant
// being streamed / just-finished)". 0..(N-1) means "show the Nth saved
// variant snapshot". A new regenerate pushes the current live state to
// `variants` and resets index to -1 (the new live response starts streaming).
@property (nonatomic, retain) NSArray *variants;          // snapshots of older responses
@property (nonatomic, assign) NSInteger currentVariantIndex;  // -1 = live; 0..N-1 = variant

+ (Message *)messageWithRole:(MessageRole)role content:(NSString *)content;
- (BOOL)isUser;
- (BOOL)isAssistant;

// v261025-8: is this an image-generation result message? (generatedImagePath
// non-empty). Convenience for cell rendering / height calc / export.
- (BOOL)isImageGenResult;

// v261025-8: absolute path for the generated image inside the current
// sandbox's Documents/genimg directory. Returns nil when the message has
// no image. The file may not exist (e.g. conversation moved between
// devices via export) — callers must handle a nil UIImage.
+ (NSString *)absolutePathForGeneratedImage:(NSString *)fileName;

// v261025-6: variant helpers.
// Push the current LIVE content+thinking onto variants array (used when
// the user taps regenerate). Returns the new variants array (autoreleased).
+ (NSArray *)pushCurrentLiveSnapshotIntoVariants:(NSArray *)existingVariants
                                         content:(NSString *)content
                                        thinking:(NSString *)thinking;
// Read the "displayed" content — if currentVariantIndex == -1, return the
// live content; otherwise return the variant snapshot's content. Same for
// thinking. These do NOT mutate state; the caller is responsible for
// applying the returned values to the message's content/thinking if needed.
+ (NSString *)displayedContentForMessage:(Message *)message;
+ (NSString *)displayedThinkingForMessage:(Message *)message;

@end

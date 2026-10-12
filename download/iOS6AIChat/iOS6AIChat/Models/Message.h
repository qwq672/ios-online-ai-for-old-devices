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

+ (Message *)messageWithRole:(MessageRole)role content:(NSString *)content;
- (BOOL)isUser;
- (BOOL)isAssistant;

@end

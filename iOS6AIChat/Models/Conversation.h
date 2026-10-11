//
//  Conversation.h
//  iOS6AIChat
//
//  A single conversation thread = ordered list of Message objects +
//  a title (derived from the first user message) + an identifier.
//  NSCoding archivable as a unit so ConversationStore can dump the
//  whole conversation to one .conv file.
//

#import <Foundation/Foundation.h>
#import "Message.h"

@interface Conversation : NSObject <NSCoding, NSCopying>

@property (nonatomic, copy)   NSString   *conversationID;
@property (nonatomic, copy)   NSString   *title;
@property (nonatomic, strong) NSMutableArray *messages; // [Message]
@property (nonatomic, strong) NSDate     *createdAt;
@property (nonatomic, strong) NSDate     *updatedAt;

+ (Conversation *)newConversation;
- (void)appendMessage:(Message *)message;
- (void)updateLastAssistantMessageContent:(NSString *)content; // for streaming
- (Message *)lastMessage;
- (NSArray *)openAIMessages; // serialise to OpenAI format: [{role, content}]
- (NSString *)displayTitle;

@end

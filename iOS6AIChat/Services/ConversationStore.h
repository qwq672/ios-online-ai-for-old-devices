//
//  ConversationStore.h
//  iOS6AIChat
//
//  Tiny disk store: every Conversation is archived to a single
//  .conv file in <Documents>/Conversations/. We keep an index of
//  conversation IDs sorted by updatedAt desc and reload on demand
//  so we don't have to keep everything in RAM.
//

#import <Foundation/Foundation.h>
#import "Conversation.h"

@interface ConversationStore : NSObject

+ (instancetype)sharedStore;

@property (nonatomic, readonly) NSArray *conversations;       // sorted by updatedAt desc
@property (nonatomic, retain) dispatch_queue_t saveQueue;     // v261116-3: serial async 落盘 queue

- (Conversation *)conversationWithID:(NSString *)conversationID;
- (void)saveConversation:(Conversation *)conversation;
- (void)deleteConversationWithID:(NSString *)conversationID;
- (Conversation *)createNewConversation;
- (NSInteger)numberOfConversations;

@end

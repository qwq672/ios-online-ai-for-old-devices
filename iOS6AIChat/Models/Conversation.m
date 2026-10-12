//
//  Conversation.m
//  iOS6AIChat
//

#import "Conversation.h"

@implementation Conversation

@synthesize conversationID=_conversationID, title=_title, messages=_messages,
            createdAt=_createdAt, updatedAt=_updatedAt;

+ (Conversation *)newConversation
{
    Conversation *c = [[[Conversation alloc] init] autorelease];
    c.conversationID = [[NSUUID UUID] UUIDString];
    c.title = NSLocalizedString(@"New Chat", nil);
    c.messages = [NSMutableArray array];
    c.createdAt = [NSDate date];
    c.updatedAt = [NSDate date];
    return c;
}

- (void)appendMessage:(Message *)message
{
    if (!message) return;
    [self.messages addObject:message];
    self.updatedAt = [NSDate date];

    // Derive title from the first user message (first ~20 chars).
    if (message.isUser && (_title == nil || [_title isEqualToString:NSLocalizedString(@"New Chat", nil)])) {
        NSString *raw = message.content;
        if ([raw length] > 20) raw = [[raw substringToIndex:20] stringByAppendingString:@"…"];
        self.title = raw;
    }
}

- (void)updateLastAssistantMessageContent:(NSString *)content
{
    // For streaming — find the last assistant message and replace its content.
    for (NSInteger i = (NSInteger)[_messages count] - 1; i >= 0; i--) {
        Message *m = [_messages objectAtIndex:i];
        if (m.isAssistant) {
            m.content = content;
            self.updatedAt = [NSDate date];
            return;
        }
    }
}

- (Message *)lastMessage
{
    if ([_messages count] == 0) return nil;
    return [_messages lastObject];
}

- (NSArray *)openAIMessages
{
    // OpenAI wants plain text content per message, drop HTML cache.
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:[_messages count]];
    for (Message *m in _messages) {
        NSString *role = m.isUser      ? @"user" :
                         m.isAssistant ? @"assistant" : @"system";
        NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:
                              role,           @"role",
                              m.content ?: @"", @"content",
                              nil];
        [arr addObject:dict];
    }
    return arr;
}

- (NSString *)displayTitle
{
    return (_title.length > 0) ? _title : NSLocalizedString(@"New Chat", nil);
}

#pragma mark - NSCoding

- (id)initWithCoder:(NSCoder *)coder
{
    if (self = [super init]) {
        // decodeObjectForKey: returns autoreleased objects. For copy/retain
        // properties (NSString / NSDate) the synthesized setter handles
        // retention; but _messages is assigned directly to the ivar so we
        // must explicitly retain, else it becomes a dangling pointer after
        // the runloop drains (causes second-launch crash).
        _conversationID = [[coder decodeObjectForKey:@"conversationID"] copy];
        _title           = [[coder decodeObjectForKey:@"title"] copy];
        NSArray *decoded = [coder decodeObjectForKey:@"messages"];
        _messages        = [[NSMutableArray alloc] initWithArray:decoded ?: @[]];
        _createdAt       = [[coder decodeObjectForKey:@"createdAt"] copy];
        _updatedAt       = [[coder decodeObjectForKey:@"updatedAt"] copy];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_conversationID forKey:@"conversationID"];
    [coder encodeObject:_title           forKey:@"title"];
    [coder encodeObject:_messages        forKey:@"messages"];
    [coder encodeObject:_createdAt       forKey:@"createdAt"];
    [coder encodeObject:_updatedAt       forKey:@"updatedAt"];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone
{
    Conversation *c = [[[self class] allocWithZone:zone] init];
    c.conversationID = [_conversationID copy];
    c.title           = [_title copy];
    c.messages        = [NSMutableArray arrayWithArray:_messages];
    c.createdAt       = [_createdAt copy];
    c.updatedAt       = [_updatedAt copy];
    return c;
}

#pragma mark - NSObject

- (void)dealloc
{
    [_conversationID release];
    [_title release];
    [_messages release];
    [_createdAt release];
    [_updatedAt release];
    [super dealloc];
}

@end

//
//  Message.m
//  iOS6AIChat
//

#import "Message.h"

@implementation Message

@synthesize role=_role, content=_content, contentHTML=_contentHTML,
            createdAt=_createdAt, messageID=_messageID;

+ (Message *)messageWithRole:(MessageRole)role content:(NSString *)content
{
    Message *m = [[[Message alloc] init] autorelease];
    m.role = role;
    m.content = content;
    m.createdAt = [NSDate date];
    m.messageID = [[NSUUID UUID] UUIDString];
    return m;
}

- (BOOL)isUser      { return _role == MessageRoleUser; }
- (BOOL)isAssistant { return _role == MessageRoleAssistant; }

#pragma mark - NSCoding

- (id)initWithCoder:(NSCoder *)coder
{
    if (self = [super init]) {
        _role        = (MessageRole)[[coder decodeObjectForKey:@"role"] integerValue];
        _content     = [coder decodeObjectForKey:@"content"];
        _contentHTML = [coder decodeObjectForKey:@"contentHTML"];
        _createdAt   = [coder decodeObjectForKey:@"createdAt"];
        _messageID   = [coder decodeObjectForKey:@"messageID"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInteger:(NSInteger)_role           forKey:@"role"];
    [coder encodeObject:_content                     forKey:@"content"];
    [coder encodeObject:_contentHTML                 forKey:@"contentHTML"];
    [coder encodeObject:_createdAt                   forKey:@"createdAt"];
    [coder encodeObject:_messageID                   forKey:@"messageID"];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone
{
    Message *copy = [[[self class] allocWithZone:zone] init];
    copy.role        = _role;
    copy.content     = [_content copy];
    copy.contentHTML = [_contentHTML copy];
    copy.createdAt   = [_createdAt copy];
    copy.messageID   = [_messageID copy];
    return copy;
}

#pragma mark - NSObject

- (void)dealloc
{
    [_content     release];
    [_contentHTML release];
    [_createdAt   release];
    [_messageID   release];
    [super dealloc];
}

@end

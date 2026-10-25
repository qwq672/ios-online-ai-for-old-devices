//
//  Message.m
//  iOS6AIChat
//

#import "Message.h"

@implementation Message

@synthesize role=_role, content=_content, contentHTML=_contentHTML,
            createdAt=_createdAt, messageID=_messageID,
            variants=_variants, currentVariantIndex=_currentVariantIndex;

+ (Message *)messageWithRole:(MessageRole)role content:(NSString *)content
{
    Message *m = [[[Message alloc] init] autorelease];
    m.role = role;
    m.content = content;
    m.createdAt = [NSDate date];
    m.messageID = [[NSUUID UUID] UUIDString];
    // v261025-6: default — no variants, live (currentVariantIndex = -1).
    m.variants = @[];
    m.currentVariantIndex = -1;
    return m;
}

- (BOOL)isUser      { return _role == MessageRoleUser; }
- (BOOL)isAssistant { return _role == MessageRoleAssistant; }

#pragma mark - NSCoding

- (id)initWithCoder:(NSCoder *)coder
{
    if (self = [super init]) {
        // decodeObjectForKey: returns autoreleased; assign-through-copy
        // for NSString/NSDate (the property is declared `copy`).
        _role        = (MessageRole)[coder decodeIntegerForKey:@"role"];
        _content     = [[coder decodeObjectForKey:@"content"] copy];
        _contentHTML = [[coder decodeObjectForKey:@"contentHTML"] copy];
        _createdAt   = [[coder decodeObjectForKey:@"createdAt"] copy];
        _messageID   = [[coder decodeObjectForKey:@"messageID"] copy];
        _thinking    = [[coder decodeObjectForKey:@"thinking"] copy];
        _images      = [[coder decodeObjectForKey:@"images"] retain];
        // v261025-6: variants + currentVariantIndex. Back-compat: if the
        // keys are missing (old conv file), default to empty + -1.
        NSArray *decodedVariants = [coder decodeObjectForKey:@"variants"];
        // v261025-6: ternary — if the decoded value is a real NSArray, retain
        // it; otherwise fall back to an empty immutable array. NOTE: only
        // ONE `[` at the start of the condition (the cond is itself a single
        // message-send `[decodedVariants isKindOfClass:...]`). The double-
        // bracket `[[cond]` was a v261025-6 typo that broke compilation.
        _variants = [decodedVariants isKindOfClass:[NSArray class]]
                    ? [decodedVariants retain]
                    : [@[] retain];
        if ([coder containsValueForKey:@"currentVariantIndex"]) {
            _currentVariantIndex = [coder decodeIntegerForKey:@"currentVariantIndex"];
        } else {
            _currentVariantIndex = -1;
        }
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
    [coder encodeObject:_thinking                    forKey:@"thinking"];
    [coder encodeObject:_images                     forKey:@"images"];
    // v261025-6: variants + currentVariantIndex.
    [coder encodeObject:_variants                    forKey:@"variants"];
    [coder encodeInteger:(NSInteger)_currentVariantIndex
                                                  forKey:@"currentVariantIndex"];
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
    // v261025-6: copy variants + index too.
    copy.variants = [_variants copy];
    copy.currentVariantIndex = _currentVariantIndex;
    return copy;
}

#pragma mark - NSObject

- (void)dealloc
{
    [_content     release];
    [_contentHTML release];
    [_createdAt   release];
    [_messageID   release];
    [_thinking    release];
    [_images      release];
    [_variants    release];
    [super dealloc];
}

#pragma mark - v261025-6 Variant helpers

// Snapshot the current LIVE content+thinking into a variant dict, append to
// the existing variants array. Returns the new array (autoreleased).
+ (NSArray *)pushCurrentLiveSnapshotIntoVariants:(NSArray *)existingVariants
                                         content:(NSString *)content
                                        thinking:(NSString *)thinking
{
    NSDictionary *snapshot = @{
        @"content":  content  ?: @"",
        @"thinking": thinking ?: @""
    };
    NSMutableArray *out = [NSMutableArray arrayWithArray:existingVariants ?: @[]];
    [out addObject:snapshot];
    return out;
}

// Read the displayed content — if currentVariantIndex == -1 (LIVE), return
// the message's content property; otherwise return the indexed variant's
// content. This is a pure read, no mutation.
+ (NSString *)displayedContentForMessage:(Message *)message
{
    if (!message) return nil;
    if (message.currentVariantIndex < 0 ||
        ![message.variants isKindOfClass:[NSArray class]] ||
        message.currentVariantIndex >= (NSInteger)[message.variants count]) {
        return message.content ?: @"";
    }
    NSDictionary *v = [message.variants objectAtIndex:message.currentVariantIndex];
    NSString *c = [v objectForKey:@"content"];
    return [c isKindOfClass:[NSString class]] ? c : @"";
}

+ (NSString *)displayedThinkingForMessage:(Message *)message
{
    if (!message) return nil;
    if (message.currentVariantIndex < 0 ||
        ![message.variants isKindOfClass:[NSArray class]] ||
        message.currentVariantIndex >= (NSInteger)[message.variants count]) {
        return message.thinking ?: @"";
    }
    NSDictionary *v = [message.variants objectAtIndex:message.currentVariantIndex];
    NSString *t = [v objectForKey:@"thinking"];
    return [t isKindOfClass:[NSString class]] ? t : @"";
}

@end

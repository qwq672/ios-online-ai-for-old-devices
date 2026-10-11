//
//  ConversationStore.m
//  iOS6AIChat
//

#import "ConversationStore.h"

static NSString * const kConversationsDirName = @"Conversations";
static NSString * const kConvFileExtension     = @"conv";

@interface ConversationStore ()
@property (nonatomic, retain) NSMutableArray *mutableConversations;
@property (nonatomic, retain) NSString *conversationsDir;
@end

@implementation ConversationStore

@synthesize mutableConversations=_mutableConversations, conversationsDir=_conversationsDir;

+ (instancetype)sharedStore
{
    static ConversationStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[ConversationStore alloc] init];
    });
    return store;
}

- (id)init
{
    if (self = [super init]) {
        _mutableConversations = [NSMutableArray array];
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                NSUserDomainMask,
                                                                YES) lastObject];
        _conversationsDir = [[docs stringByAppendingPathComponent:kConversationsDirName] retain];
        [[NSFileManager defaultManager] createDirectoryAtPath:_conversationsDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        [self _loadAll];
    }
    return self;
}

- (NSArray *)conversations
{
    return [NSArray arrayWithArray:_mutableConversations];
}

- (Conversation *)conversationWithID:(NSString *)conversationID
{
    if (!conversationID) return nil;
    for (Conversation *c in _mutableConversations) {
        if ([c.conversationID isEqualToString:conversationID]) return c;
    }
    // Lazy-load from disk if missing.
    NSString *path = [_conversationsDir stringByAppendingPathComponent:
                      [conversationID stringByAppendingPathExtension:kConvFileExtension]];
    Conversation *loaded = [NSKeyedUnarchiver unarchiveObjectWithFile:path];
    if (loaded) {
        [_mutableConversations addObject:loaded];
        [self _sortByUpdated];
    }
    return loaded;
}

- (void)saveConversation:(Conversation *)conversation
{
    if (!conversation) return;
    NSString *path = [_conversationsDir stringByAppendingPathComponent:
                      [conversation.conversationID stringByAppendingPathExtension:kConvFileExtension]];
    [NSKeyedArchiver archiveRootObject:conversation toFile:path];

    // Refresh in-memory copy.
    NSUInteger idx = NSNotFound;
    for (NSUInteger i = 0; i < [_mutableConversations count]; i++) {
        if ([[[_mutableConversations objectAtIndex:i] conversationID]
                isEqualToString:conversation.conversationID]) {
            idx = i; break;
        }
    }
    if (idx != NSNotFound) {
        [_mutableConversations replaceObjectAtIndex:idx withObject:conversation];
    } else {
        [_mutableConversations addObject:conversation];
    }
    [self _sortByUpdated];
}

- (void)deleteConversationWithID:(NSString *)conversationID
{
    if (!conversationID) return;
    NSString *path = [_conversationsDir stringByAppendingPathComponent:
                      [conversationID stringByAppendingPathExtension:kConvFileExtension]];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    NSUInteger idx = NSNotFound;
    for (NSUInteger i = 0; i < [_mutableConversations count]; i++) {
        if ([[[_mutableConversations objectAtIndex:i] conversationID]
                isEqualToString:conversationID]) {
            idx = i; break;
        }
    }
    if (idx != NSNotFound) [_mutableConversations removeObjectAtIndex:idx];
}

- (Conversation *)createNewConversation
{
    Conversation *c = [Conversation newConversation];
    [self saveConversation:c];
    return c;
}

- (NSInteger)numberOfConversations
{
    return (NSInteger)[_mutableConversations count];
}

#pragma mark - Private

- (void)_loadAll
{
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_conversationsDir
                                                                          error:NULL];
    NSMutableArray *loaded = [NSMutableArray array];
    for (NSString *fname in files) {
        if (![fname hasSuffix:kConvFileExtension]) continue;
        NSString *path = [_conversationsDir stringByAppendingPathComponent:fname];
        Conversation *c = [NSKeyedUnarchiver unarchiveObjectWithFile:path];
        if (c) [loaded addObject:c];
    }
    _mutableConversations = loaded;
    [self _sortByUpdated];
}

- (void)_sortByUpdated
{
    [_mutableConversations sortUsingComparator:^NSComparisonResult(Conversation *a, Conversation *b) {
        return [b.updatedAt compare:a.updatedAt];
    }];
}

- (void)dealloc
{
    [_mutableConversations release];
    [_conversationsDir release];
    [super dealloc];
}

@end

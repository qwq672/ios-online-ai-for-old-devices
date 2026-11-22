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
        // CRITICAL: MRC retain — [NSMutableArray array] is autoreleased.
        // Assigning directly to the ivar without retain means the array
        // gets deallocated at the next runloop drain, and any subsequent
        // access (e.g. saveConversation:) hits a dangling pointer → crash.
        _mutableConversations = [[NSMutableArray array] retain];
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                NSUserDomainMask,
                                                                YES) lastObject];
        _conversationsDir = [[docs stringByAppendingPathComponent:kConversationsDirName] retain];
        [[NSFileManager defaultManager] createDirectoryAtPath:_conversationsDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        // v261116-3: serial queue 异步落盘，保序避免并发写同一文件竞态
        self.saveQueue = dispatch_queue_create("com.aianywhere.convsave", DISPATCH_QUEUE_SERIAL);
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

    // v261116-3: 异步落盘 — 旧实现 [NSKeyedArchiver archiveRootObject:toFile:] 同步
    // 在主线程执行，长对话（>200 条消息）落盘 200-500ms 卡 UI
    // 用 serial queue 保序，避免并发写同一文件产生竞态
    // v261122-2: 深拷贝快照（Conversation copyWithZone 会逐条 copy Message），
    // 彻底隔离主线程流式写入与后台归档，避免竞态崩溃。
    Conversation *convCopy = [conversation copy];
    dispatch_async(self.saveQueue, ^{
        @try {
            [NSKeyedArchiver archiveRootObject:convCopy toFile:path];
        } @catch (NSException *e) {
            NSLog(@"ConversationStore save failed: %@", e);
        }
    });

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
    // CRITICAL: MRC retain — `loaded` is autoreleased. Without retain,
    // the next runloop drain frees it and _mutableConversations becomes
    // a dangling pointer. (This was the second-launch crash cause.)
    [_mutableConversations release];
    _mutableConversations = [loaded retain];
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
    // v261116-3: 释放 saveQueue（MRC retain property）
    [_saveQueue release];
    [super dealloc];
}

@end

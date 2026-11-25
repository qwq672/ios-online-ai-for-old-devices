//
//  ConversationStore.m
//  iOS6AIChat
//

#import "ConversationStore.h"
#include <stdio.h>   // v261125-3: rename() for atomic archive write

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
    // v261125-3 (bug2 fix): 用临时文件 + rename() 原子替换，杜绝"写一半被
    // 强杀/jetsam → .conv 文件被截断 → 下次启动 unarchive 崩溃 → 黑屏闪退"。
    // rename() 在同一文件系统内是原子的：要么旧文件完整保留，要么被完整替换，
    // 绝不会留下半截文件。这正是"卡死后重进黑屏闪退"的根因修复。
    Conversation *convCopy = [conversation copy];
    dispatch_async(self.saveQueue, ^{
        NSString *tmpPath = [path stringByAppendingString:@".tmp"];
        BOOL wrote = NO;
        @try {
            wrote = [NSKeyedArchiver archiveRootObject:convCopy toFile:tmpPath];
        } @catch (NSException *e) {
            NSLog(@"ConversationStore save failed: %@", e);
        }
        if (wrote) {
            if (rename([tmpPath fileSystemRepresentation],
                       [path fileSystemRepresentation]) != 0) {
                NSLog(@"ConversationStore rename failed, keeping old file");
                [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:NULL];
            }
        }
        [convCopy release];  // 配平上面的 copy —— 修掉每次保存泄漏一份会话
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
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *fname in files) {
        if (![fname hasSuffix:kConvFileExtension]) continue;
        NSString *path = [_conversationsDir stringByAppendingPathComponent:fname];

        // v261125-4 (bug2 fix): 加载前的轻量完整性护卫。
        // 虽然归档已改为原子写，仍要防历史遗留的截断文件（老版本写坏的）。
        // 用纯数据检查（不用 @try —— 该 Theos 工具链在 armv7 上 @try 会
        // SIGSEGV，见 AppDelegate 头部注释）：文件必须非空、>=32 字节，
        // 且头部必须是 NSKeyedArchiver 的二进制 plist magic "bplist00"。
        // 不满足就把该文件改名隔离（.bad）后跳过，避免它每次启动都触发
        // unarchive 崩溃（黑屏 → 闪退）。原子写 + 这个护卫 = 双保险。
        NSData *blob = [NSData dataWithContentsOfFile:path];
        BOOL looksValid = (blob != nil && [blob length] >= 32);
        if (looksValid) {
            const unsigned char *bytes = [blob bytes];
            static const char plistMagic[] = "bplist00";
            for (NSUInteger i = 0; i < 8; i++) {
                if (bytes[i] != (unsigned char)plistMagic[i]) { looksValid = NO; break; }
            }
        }
        if (!looksValid) {
            NSLog(@"ConversationStore: quarantining corrupt file %@", fname);
            NSString *badPath = [path stringByAppendingString:@".bad"];
            [fm removeItemAtPath:badPath error:NULL];
            [fm moveItemAtPath:path toPath:badPath error:NULL];
            continue;
        }
        Conversation *c = [NSKeyedUnarchiver unarchiveObjectWithFile:path];
        if (c) [loaded addObject:c];
        else {
            // 头合法但解档仍失败（更深的损坏）——同样隔离，不让坏文件反复崩溃。
            NSString *badPath = [path stringByAppendingString:@".bad"];
            [fm removeItemAtPath:badPath error:NULL];
            [fm moveItemAtPath:path toPath:badPath error:NULL];
        }
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

//
//  Logger.m
//  iOS6AIChat
//
//  v261024-19: STRIPPED ALL @try/@catch.
//    Root-cause analysis of the persistent crashes (history 75% / activate
//    90% / delete-model 90%) with NO log lines captured pointed at the
//    v17 wave of @try blocks: the Theos + cctools-port + iPhoneOS6.0.sdk
//    toolchain does NOT emit correct .ARM.exidx / .ARM.extab unwind
//    tables for armv7/armv7s on every function we wrap. The personality
//    function lookup at function-entry crashes with SIGSEGV (which is NOT
//    an NSException, so NSSetUncaughtExceptionHandler never fires → no
//    log entry — matching the user's observation).
//    The fix is to remove ALL ObjC exception handling and rely on
//    plain nil-guards + early-returns instead. The compiler flag
//    -fobjc-exceptions has also been removed from the Makefile so no
//    exception tables are generated at all.
//

#import "Logger.h"

NSString *const iOS6LoggerDidWriteNotification = @"iOS6LoggerDidWrite";
NSString *const SettingsKeyLoggingEnabled = @"loggingEnabled";

// 1 MB hard cap — past this the file is rotated (renamed to .old, fresh
// file starts). Keeps the log readable on device without eating all
// of the (small, on iOS 6 devices) flash storage.
static const NSUInteger kLogMaxBytes = 1 * 1024 * 1024;

@interface Logger ()
// `queue` MUST be `assign`, NOT `retain`. On iOS 6 the dispatch_queue_t
// is NOT an NSObject (it's `struct dispatch_queue_s *`); the synthesised
// (retain) accessor would call `objc_msgSend(queue, @selector(retain))`
// which crashes with "unrecognized selector sent to instance" if
// anything (KVO, runtime introspection, _setFont:, etc.) ever routes
// through self.queue = X. `assign` makes the setter a plain pointer
// copy with no retain/release message — iOS-6-safe.
@property (nonatomic, assign) dispatch_queue_t queue;
@property (nonatomic, retain) NSString *logPath;
@end

// C function pointer (not a block!) — NSSetUncaughtExceptionHandler
// takes a plain C function pointer of type
//   void (*)(NSException *exception)
// (NOT an Obj-C block). This function calls the singleton Logger so
// the crash info lands in the log file.
//
// v261024-19: NO @try here. With -fobjc-exceptions removed from the
// build, no @try can compile anyway. NSException caught here is
// already an "uncaught" one — there's no recovery path; just write
// the line directly.
static void iOS6AIChatUncaughtExceptionHandler(NSException *exception)
{
    // Best-effort: format the crash line and write it. If anything here
    // fails, we lose the crash info but the app is already dying.
    NSString *name = [exception.name isKindOfClass:[NSString class]] ? exception.name : @"(no name)";
    if (!name || name.length == 0) name = @"(no name)";
    NSString *reason = [exception.reason isKindOfClass:[NSString class]] ? exception.reason : @"(no reason)";
    if (!reason || reason.length == 0) reason = @"(no reason)";
    NSArray *symbols = [exception callStackSymbols];
    NSString *stack = [symbols isKindOfClass:[NSArray class]] ? [symbols componentsJoinedByString:@"\n"] : @"(no stack)";
    NSString *msg = [NSString stringWithFormat:
        @"\n=== UNCAUGHT EXCEPTION ===\nname: %@\nreason: %@\ncallStack:\n%@\n==========================\n",
        name, reason, stack];
    [[Logger sharedLogger] logWithLevel:kLogLevelError message:msg];
}

@implementation Logger

@synthesize queue=_queue, logPath=_logPath;

+ (Logger *)sharedLogger
{
    static Logger *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[Logger alloc] init];
    });
    return instance;
}

- (id)init
{
    if (self = [super init]) {
        // Serial queue — guarantees ordered writes from multiple threads.
        // dispatch_queue_create returns a queue with retain count 1
        // (caller owns the reference); we store it directly into the
        // ivar. The `assign` property declared above means no setter
        // is invoked here — we own the queue and release it in dealloc
        // via dispatch_release.
        _queue = dispatch_queue_create("awa.qwq672.iosonlineai.logger", NULL);
        // <Documents>/iOS6AIChat.log. iOS 6: NSDocumentDirectory is
        // available (NSFileManager URLsForDirectory:... is iOS 4+).
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = [dirs count] > 0 ? [dirs objectAtIndex:0] : NSTemporaryDirectory();
        _logPath = [[docs stringByAppendingPathComponent:@"iOS6AIChat.log"] retain];

        // Hook uncaught exceptions — these are what cause "the app just
        // vanished" without a stack trace visible to the user. Writing
        // the exception + call stack to the log file is the closest iOS 6
        // gets to a crash reporter (no PLCrashReporter on iOS 6 without
        // extra deps, and we don't want to add a dep).
        NSSetUncaughtExceptionHandler(iOS6AIChatUncaughtExceptionHandler);
    }
    return self;
}

- (BOOL)isEnabled
{
    // Default ON unless explicitly disabled.
    NSNumber *v = [[NSUserDefaults standardUserDefaults] objectForKey:SettingsKeyLoggingEnabled];
    if (!v) return YES;
    return [v boolValue];
}

- (void)setEnabled:(BOOL)enabled
{
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:SettingsKeyLoggingEnabled];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)debug:(NSString *)msg { [self logWithLevel:kLogLevelDebug message:msg]; }
- (void)info:(NSString *)msg  { [self logWithLevel:kLogLevelInfo message:msg]; }
- (void)warn:(NSString *)msg  { [self logWithLevel:kLogLevelWarn message:msg]; }
- (void)error:(NSString *)msg  { [self logWithLevel:kLogLevelError message:msg]; }

- (void)logWithLevel:(LogLevel)level message:(NSString *)msg
{
    // v261024-19: NO @try. nil-guards + early returns instead.
    if (![self isEnabled]) return;
    if (!msg || msg.length == 0) return;
    // If init failed (_queue==nil), no-op — don't crash dispatch_async
    // on a NULL queue.
    if (!_queue) return;
    if (!_logPath || _logPath.length == 0) return;

    // Compose the line: timestamp [LEVEL] msg
    static NSArray *levelTags = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        levelTags = [NSArray arrayWithObjects:@"D", @"I", @"W", @"E", nil];
        // Retain so the static survives across autorelease pool pops.
        [levelTags retain];
    });
    NSDate *now = [NSDate date];
    NSDateFormatter *fmt = [[[NSDateFormatter alloc] init] autorelease];
    [fmt setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    NSString *ts = [fmt stringFromDate:now];
    NSString *tag = (NSUInteger)level < [levelTags count]
        ? [levelTags objectAtIndex:(NSUInteger)level] : @"?";
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n", ts, tag, msg];

    // Capture path & line into the block. Both are retain'd by the block
    // (MRC: stack-block → heap-block copy retains captured object pointers).
    NSString *path = _logPath;
    dispatch_async(_queue, ^{
        @autoreleasepool {
            // Append. atomic:NO because we're on a serial queue, so no
            // concurrent writer.
            if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
                // Create the file with this line as its first content.
                [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
            } else {
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
                if (fh) {
                    [fh seekToEndOfFile];
                    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                    [fh closeFile];
                    [fh release];   // fileHandleForWritingAtPath: returns +1 on iOS 6
                }
            }

            // Rotate if too big.
            NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
            NSNumber *sz = [attrs objectForKey:NSFileSize];
            if (sz && [sz unsignedLongLongValue] > kLogMaxBytes) {
                NSString *oldPath = [path stringByAppendingPathExtension:@"old"];
                [NSFileManager.defaultManager removeItemAtPath:oldPath error:NULL];
                [NSFileManager.defaultManager moveItemAtPath:path toPath:oldPath error:NULL];
            }

            // Live-notify the LogViewController. (NSNotificationCenter
            // posts synchronously on the posting thread — the LogVC's
            // _logDidWrite observes via -performSelector:afterDelay: which
            // reschedules onto the main runloop, so the bg-thread post
            // here is safe.)
            [[NSNotificationCenter defaultCenter]
                postNotificationName:iOS6LoggerDidWriteNotification object:nil];
        }  // @autoreleasepool — GCD worker thread has no pool of its own;
           //  the autoreleased NSDateFormatter / NSFileHandle above
           //  would otherwise leak per-call.
    });  // dispatch_async
}

- (NSString *)readAllLog
{
    NSString *current = [NSString stringWithContentsOfFile:self.logPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    NSString *oldPath = [self.logPath stringByAppendingPathExtension:@"old"];
    NSString *old = [NSString stringWithContentsOfFile:oldPath
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    if (old.length > 0 && current.length > 0) {
        return [NSString stringWithFormat:@"%@\n---- (rotated) ----\n%@", old, current];
    }
    return old.length > 0 ? old : (current ?: @"(no log yet)");
}

- (BOOL)clearLog
{
    if (!_queue) return NO;
    __block BOOL ok = NO;
    dispatch_sync(_queue, ^{
        [NSFileManager.defaultManager removeItemAtPath:_logPath error:NULL];
        NSString *oldPath = [_logPath stringByAppendingPathExtension:@"old"];
        [NSFileManager.defaultManager removeItemAtPath:oldPath error:NULL];
        ok = YES;
    });
    return ok;
}

- (NSString *)logFilePath { return _logPath; }

- (void)dealloc
{
    if (_queue) {
        // Wait for pending writes to finish before tearing down.
        dispatch_sync(_queue, ^{});
        #if !__has_feature(objc_arc)
        dispatch_release(_queue);
        #endif
    }
    [_logPath release];
    [super dealloc];
}

@end

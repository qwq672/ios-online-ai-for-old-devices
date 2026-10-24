//
//  Logger.m
//  iOS6AIChat
//

#import "Logger.h"

NSString *const iOS6LoggerDidWriteNotification = @"iOS6LoggerDidWrite";
NSString *const SettingsKeyLoggingEnabled = @"loggingEnabled";

// 1 MB hard cap — past this the file is rotated (renamed to .old, fresh
// file starts). Keeps the log readable on device without eating all
// of the (small, on iOS 6 devices) flash storage.
static const NSUInteger kLogMaxBytes = 1 * 1024 * 1024;

@interface Logger ()
// v261024-17 fix: `queue` MUST be `assign`, NOT `retain`. On iOS 6 the
// dispatch_queue_t is NOT an NSObject (it's `struct dispatch_queue_s *`);
// the synthesised `(retain)` accessor would call `objc_msgSend(queue,
// @selector(retain))` which crashes with "unrecognized selector sent to
// instance" if anything (KVO, runtime introspection, _setFont:,
// _setObservationInfo:, etc.) ever routes through self.queue = X. Even
// though our own code never does the assignment via the property
// (we use direct ivar assignment in init), the synthesised setter still
// gets added to the class's method table, so ANY external code or
// runtime mechanism could trip it. `assign` makes the setter a plain
// pointer copy with no retain/release message — iOS-6-safe.
@property (nonatomic, assign) dispatch_queue_t queue;
@property (nonatomic, retain) NSString *logPath;
@end

// C function pointer (not a block!) — NSSetUncaughtExceptionHandler
// takes a plain C function pointer of type
//   void (*)(NSException *exception)
// (NOT an Obj-C block). This function calls the singleton Logger so
// the crash info lands in the log file.
static void iOS6AIChatUncaughtExceptionHandler(NSException *exception)
{
    @try {
        NSString *msg = [NSString stringWithFormat:
            @"\n=== UNCAUGHT EXCEPTION ===\nname: %@\nreason: %@\ncallStack:\n%@\n==========================\n",
            exception.name ?: @"(no name)",
            exception.reason ?: @"(no reason)",
            [[exception callStackSymbols] componentsJoinedByString:@"\n"]];
        [[Logger sharedLogger] logWithLevel:kLogLevelError message:msg];
    } @catch (NSException *secondary) {
        // Do nothing — we're already in an uncaught-exception handler.
    }
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
        // v261024-17: wrap init in @try — if dispatch_queue_create or
        // NSSetUncaughtExceptionHandler ever throws, dispatch_once's
        // sharedLogger would be left half-initialised AND the uncaught-
        // exception handler would re-enter sharedLogger → deadlock. With
        // @try here, an init failure just leaves the Logger with
        // _queue=nil; every log call no-ops (the `if (!_queue) return;`
        // guard below). The app still runs.
        @try {
            // Serial queue — guarantees ordered writes from multiple
            // threads. dispatch_queue_create returns a queue with retain
            // count 1 (caller owns the reference); we store it directly
            // into the ivar. The `assign` property declared above means
            // no setter is invoked here — we own the queue and release
            // it in dealloc via dispatch_release.
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
        } @catch (NSException *e) {
            // Best-effort: log to NSLog so the failure is at least
            // visible in Console.app on a debugger-attached device.
            NSLog(@"[Logger] init failed: %@ — %@", e.name, e.reason);
            // Defensive: if _queue was created but a later step threw,
            // release it so we don't leak a queue that nothing references.
            if (_queue) {
                dispatch_release(_queue);
                _queue = NULL;
            }
        }
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
    if (![self isEnabled]) return;
    if (!msg || msg.length == 0) return;
    // v261024-17: if init failed (_queue==nil), no-op — don't crash
    // dispatch_async on a NULL queue.
    if (!_queue) return;

    // Compose the line: timestamp [LEVEL] msg
    static NSArray *levelTags = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        levelTags = [NSArray arrayWithObjects:@"D", @"I", @"W", @"E", nil];
    });
    NSDate *now = [NSDate date];
    NSDateFormatter *fmt = [[[NSDateFormatter alloc] init] autorelease];
    [fmt setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    NSString *ts = [fmt stringFromDate:now];
    NSString *tag = (NSUInteger)level < [levelTags count]
        ? [levelTags objectAtIndex:(NSUInteger)level] : @"?";
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n", ts, tag, msg];

    NSString *path = self.logPath;
    if (!path) {
        // Defensive: shouldn't happen but if init failed _logPath is nil.
        return;
    }
    dispatch_async(_queue, ^{
        @autoreleasepool {
            @try {
                // Append. atomic:NO because we're on a serial queue, so no
                // concurrent writer; NSDataWritingFileAppendWithoutTruncating
                // (which is what dataWithContentsOfFile uses implicitly when
                // writing back) is the iOS-safe flag.
                if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
                    // Create the file with this line as its first content.
                    [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
                } else {
                    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
                    [fh seekToEndOfFile];
                    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                    [fh closeFile];
                }

                // Rotate if too big.
                NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
                NSNumber *sz = [attrs objectForKey:NSFileSize];
                if (sz && [sz unsignedLongLongValue] > kLogMaxBytes) {
                    NSString *oldPath = [path stringByAppendingPathExtension:@"old"];
                    // Remove any pre-existing .old, then rename current → .old.
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
            } @catch (NSException *e) {
                // Logging the logger's failure would be ironic — just no-op.
            }
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

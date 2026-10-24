//
//  Logger.m
//  iOS6AIChat
//
//  v261025-1 CRASH-LOGGER REWRITE.
//
//  Root causes found in v261024-17..19 crash saga (both are now fixed):
//
//  BUG A (v15..v18): `static NSArray *levelTags` was assigned an
//    AUTORELEASED array inside dispatch_once. After the first runloop
//    drain the static pointed at freed memory; every later log call
//    was a use-after-free lottery → random SIGSEGV, no NSException →
//    NSSetUncaughtExceptionHandler never fired → empty crash logs.
//    (This caused the 75%/90%/90% crashes on history / activate-char /
//    delete-model — every hotspot logged right before dying.)
//
//  BUG B (v261024-19): I added `[fh release]` after
//    +[NSFileHandle fileHandleForWritingAtPath:] — a CONVENIENCE
//    constructor that returns an AUTORELEASED (+0) object. The release
//    was an over-release: every log write deallocated the file handle,
//    then the autorelease pool popped and released the zombie again →
//    every action that logged ANY line crashed ~1ms later on the logger
//    thread. That's why v19 crashes on send / activate / delete-model /
//    history-menu / new-chat / EVERY tap on the character page — all of
//    those log.
//
//  New in this rewrite:
//    1. Normal writes stay async on a serial queue (ordered, off-main),
//       with an explicit [levelTags retain] (BUG A fix) and NO release
//       of convenience-constructor objects (BUG B fix).
//    2. CRASH path writes SYNCHRONOUSLY with C-level open()/write() —
//       dispatch_async would never complete before the process dies
//       (that's why crash info was never recorded!).
//    3. POSIX signal handlers (SIGSEGV/SIGBUS/SIGABRT/SIGILL/SIGFPE)
//       + the NSException uncaught handler both dump into the log via
//       the C-level writer, with backtrace() frames when available.
//       → The user's requirement "闪退报错也记录" (crashes logged too).
//    4. The iOS6LoggerDidWriteNotification is now posted ON THE MAIN
//       QUEUE so LogViewController's live refresh actually works (the
//       old code posted from the logger thread; performSelector:
//       afterDelay: on a GCD thread never fires → page never updated).
//

#import "Logger.h"
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <errno.h>
#import <execinfo.h>
#import <signal.h>

NSString *const iOS6LoggerDidWriteNotification = @"iOS6LoggerDidWrite";
NSString *const SettingsKeyLoggingEnabled = @"loggingEnabled";

// 1 MB hard cap — past this the file is rotated (renamed to .old, fresh
// file starts). Keeps the log readable on device without eating all
// of the (small, on iOS 6 devices) flash storage.
static const NSUInteger kLogMaxBytes = 1 * 1024 * 1024;

// ---------------------------------------------------------------------------
// C-level crash writer state. Kept in plain C so BOTH the signal handler
// and the exception handler can use it without any ObjC messaging once
// the process is dying.
// ---------------------------------------------------------------------------
static char gCrashLogPath[1024] = {0};   // filled once at Logger init
static volatile sig_atomic_t gInCrashHandler = 0;

// Raw C append — the ONLY writer allowed on the crash path.
// O_APPEND keeps concurrent appends from the async queue and the crash
// writer from clobbering each other (each write is atomic-enough for a
// log file on iOS 6; the serial queue's writes are small too).
static void iOS6LoggerWriteRaw(const char *utf8, size_t len)
{
    if (!utf8 || len == 0) return;
    if (gCrashLogPath[0] == '\0') return;
    int fd = open(gCrashLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    ssize_t w1 = write(fd, utf8, (size_t)len);
    ssize_t w2 = write(fd, "\n", 1);
    (void)w1; (void)w2;   // best-effort; can't do anything on failure
    close(fd);
}

// ---------------------------------------------------------------------------
// POSIX signal handler — catches the SIGSEGV/SIGABRT-class deaths (the
// ones that NEVER appear in the log because they aren't NSExceptions).
// Writes a header + backtrace frames with C calls only, then re-raises
// with the default disposition so the system crash reporter still runs.
// ---------------------------------------------------------------------------
static const char *iOS6LoggerSignalName(int sig)
{
    switch (sig) {
        case SIGSEGV: return "SIGSEGV (segmentation fault — bad memory access)";
        case SIGBUS:  return "SIGBUS (bus error — misaligned/bad address)";
        case SIGABRT: return "SIGABRT (abort — uncaught exception or assert)";
        case SIGILL:  return "SIGILL (illegal instruction)";
        case SIGFPE:  return "SIGFPE (arithmetic error)";
        default:      return "UNKNOWN SIGNAL";
    }
}

static void iOS6AIChatSignalHandler(int sig)
{
    if (gInCrashHandler == 0) {
        gInCrashHandler = 1;

        char header[512];
        int n = snprintf(header, sizeof(header),
            "\n=== FATAL SIGNAL %d: %s ===", sig, iOS6LoggerSignalName(sig));
        if (n > 0) iOS6LoggerWriteRaw(header, (size_t)n);

        // Best-effort backtrace. backtrace_symbols_fd writes straight to
        // the fd without the malloc that backtrace_symbols would do.
        if (gCrashLogPath[0] != '\0') {
            void *frames[24];
            int nFrames = backtrace(frames, 24);
            if (nFrames > 0) {
                int fd = open(gCrashLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
                if (fd >= 0) {
                    const char *bt = "callStack (raw frames):\n";
                    write(fd, bt, strlen(bt));
                    backtrace_symbols_fd(frames, nFrames, fd);
                    const char *end = "\n==========================\n";
                    write(fd, end, strlen(end));
                    close(fd);
                }
            } else {
                const char *nobt = "(no backtrace available)\n==========================\n";
                iOS6LoggerWriteRaw(nobt, strlen(nobt));
            }
        }
    }
    // Restore default handling and re-raise so the crash is delivered
    // exactly as it would have been without us.
    signal(sig, SIG_DFL);
    raise(sig);
}

// ---------------------------------------------------------------------------
// NSException uncaught handler — ObjC exceptions land here. Format the
// message FIRST (while the runtime is still healthy), then write via the
// C-level writer SYNCHRONOUSLY. The old async dispatch meant the process
// died before the write ever ran — which is why the user never saw
// exception info in the log either.
// ---------------------------------------------------------------------------
static void iOS6AIChatUncaughtExceptionHandler(NSException *exception)
{
    if (gInCrashHandler != 0) return;   // already dying — don't recurse
    gInCrashHandler = 1;

    NSString *name = [exception.name isKindOfClass:[NSString class]] ? exception.name : nil;
    if (name.length == 0) name = @"(no name)";
    NSString *reason = [exception.reason isKindOfClass:[NSString class]] ? exception.reason : nil;
    if (reason.length == 0) reason = @"(no reason)";
    NSString *stack = @"";
    NSArray *symbols = [exception callStackSymbols];
    if ([symbols isKindOfClass:[NSArray class]]) {
        stack = [symbols componentsJoinedByString:@"\n"];
    }
    NSString *msg = [NSString stringWithFormat:
        @"\n=== UNCAUGHT EXCEPTION ===\nname: %@\nreason: %@\ncallStack:\n%@\n==========================",
        name, reason, stack];
    const char *utf8 = [msg UTF8String];
    if (utf8) iOS6LoggerWriteRaw(utf8, strlen(utf8));

    // Leave the flag set — the runtime will call abort() right after
    // this handler returns; the SIGABRT handler will see the flag and
    // skip double-logging, then re-raise.
}

@interface Logger ()
// `queue` MUST be `assign`, NOT `retain`. On iOS 6 dispatch_queue_t is
// NOT an NSObject; a synthesised (retain) accessor would objc_msgSend a
// struct pointer. `assign` keeps it a plain pointer copy.
@property (nonatomic, assign) dispatch_queue_t queue;
@property (nonatomic, retain) NSString *logPath;
@end

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
        // dispatch_queue_create returns a queue we own (+1); we store it
        // directly in the ivar and dispatch_release it in dealloc.
        _queue = dispatch_queue_create("awa.qwq672.iosonlineai.logger", NULL);

        NSArray *dirs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = [dirs count] > 0 ? [dirs objectAtIndex:0] : NSTemporaryDirectory();
        _logPath = [[docs stringByAppendingPathComponent:@"iOS6AIChat.log"] retain];

        // Cache the path as C string for the signal-handler writer.
        const char *cpath = [_logPath UTF8String];
        if (cpath && strlen(cpath) < sizeof(gCrashLogPath)) {
            strlcpy(gCrashLogPath, cpath, sizeof(gCrashLogPath));
        }

        // Crash hooks. NSExceptions → handler above; hard signals →
        // handler above. Together these cover both crash classes the
        // user has been hitting (memory faults AND ObjC exceptions).
        NSSetUncaughtExceptionHandler(iOS6AIChatUncaughtExceptionHandler);
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = iOS6AIChatSignalHandler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_RESETHAND;   // auto-reset so re-raise works
        sigaction(SIGSEGV, &sa, NULL);
        sigaction(SIGBUS,  &sa, NULL);
        sigaction(SIGABRT, &sa, NULL);
        sigaction(SIGILL,  &sa, NULL);
        sigaction(SIGFPE,  &sa, NULL);
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
- (void)error:(NSString *)msg { [self logWithLevel:kLogLevelError message:msg]; }

- (void)logWithLevel:(LogLevel)level message:(NSString *)msg
{
    if (![self isEnabled]) return;
    if (!msg || msg.length == 0) return;
    if (!_queue) return;
    if (!_logPath || _logPath.length == 0) return;

    // Level tags — static storage. BUG A fix: the array MUST be
    // explicitly retained; under MRC a bare assignment of an
    // autoreleased object dangles after the first pool drain.
    static NSArray *levelTags = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        levelTags = [NSArray arrayWithObjects:@"D", @"I", @"W", @"E", nil];
        [levelTags retain];
    });

    NSDateFormatter *fmt = [[[NSDateFormatter alloc] init] autorelease];
    [fmt setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    NSString *ts = [fmt stringFromDate:[NSDate date]];
    NSString *tag = ((NSUInteger)level < [levelTags count])
        ? [levelTags objectAtIndex:(NSUInteger)level] : @"?";
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n", ts, tag, msg];

    // Capture into the block — under MRC the block copy retains both.
    NSString *path = _logPath;
    dispatch_async(_queue, ^{
        @autoreleasepool {
            // NOTE: fileHandleForWritingAtPath: returns an AUTORELEASED
            // (+0) object. Do NOT release it (that was BUG B). It lives
            // until this pool pops, which is exactly as long as we need.
            if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
                [line writeToFile:path atomically:NO
                          encoding:NSUTF8StringEncoding error:NULL];
            } else {
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
                if (fh) {
                    [fh seekToEndOfFile];
                    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                    [fh closeFile];
                }
            }

            // Rotate when over the cap.
            NSDictionary *attrs = [NSFileManager.defaultManager
                attributesOfItemAtPath:path error:NULL];
            NSNumber *sz = [attrs objectForKey:NSFileSize];
            if (sz && [sz unsignedLongLongValue] > kLogMaxBytes) {
                NSString *oldPath = [path stringByAppendingPathExtension:@"old"];
                [NSFileManager.defaultManager removeItemAtPath:oldPath error:NULL];
                [NSFileManager.defaultManager moveItemAtPath:path
                                                      toPath:oldPath error:NULL];
            }

            // Notify the LogViewController — ON THE MAIN QUEUE now.
            // Posting from this GCD thread meant the LogVC observer ran
            // here and performSelector:afterDelay: never fired (GCD
            // threads don't run runloops) → the log page never refreshed.
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:iOS6LoggerDidWriteNotification object:nil];
            });
        }
    });
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
        dispatch_sync(_queue, ^{});
        #if !__has_feature(objc_arc)
        dispatch_release(_queue);
        #endif
    }
    [_logPath release];
    [super dealloc];
}

@end

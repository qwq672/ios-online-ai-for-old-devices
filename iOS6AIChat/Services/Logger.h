//
//  Logger.h
//  iOS6AIChat
//
//  v261024-15: lightweight file logger for crash/error diagnosis.
//    - Singleton: +sharedLogger
//    - Levels: debug/info/warn/error
//    - Writes to <Documents>/iOS6AIChat.log (auto-rotates > 1MB)
//    - Toggle: -[Logger setEnabled:] (persisted)
//    - Posts iOS6LoggerDidWriteNotification after each line so
//      LogViewController can live-refresh.
//    - Hooks NSSetUncaughtExceptionHandler on +sharedLogger first call
//      so uncaught Objective-C exceptions land in the log file too.
//

#import <Foundation/Foundation.h>

typedef enum {
    kLogLevelDebug = 0,
    kLogLevelInfo,
    kLogLevelWarn,
    kLogLevelError
} LogLevel;

extern NSString *const iOS6LoggerDidWriteNotification;
extern NSString *const SettingsKeyLoggingEnabled;

@interface Logger : NSObject

+ (Logger *)sharedLogger;

// On/off switch (persisted to NSUserDefaults under SettingsKeyLoggingEnabled).
// Default = ON (the user-reported "短对话闪退" bug is intermittent, so we
// need to capture by default rather than wait for the user to enable).
- (BOOL)isEnabled;
- (void)setEnabled:(BOOL)enabled;

// Convenience methods for each level. Thread-safe (uses dispatch_queue
// + a serial async write).
- (void)debug:(NSString *)msg;
- (void)info:(NSString *)msg;
- (void)warn:(NSString *)msg;
- (void)error:(NSString *)msg;

- (void)logWithLevel:(LogLevel)level message:(NSString *)msg;

// Read the entire log file as a string (best-effort — if the file
// can't be read, returns @"(empty)"). The LogViewController calls this
// to populate its scroll view.
- (NSString *)readAllLog;

// Wipe the log file clean. Returns YES on success.
- (BOOL)clearLog;

// Path to the log file (so a future desktop tool / ssh user can pull it).
- (NSString *)logFilePath;

@end

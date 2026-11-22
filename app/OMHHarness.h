//
//  OMHHarness.h
//  OMH
//
//  Supervises the `opencode-serve` process inside the Linux guest: chooses the
//  loopback port, launches the server, waits until it answers HTTP, restarts
//  it with back-off when it dies, and publishes state for the UI.
//

#import <Foundation/Foundation.h>
#import "OMHLogBuffer.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OMHHarnessState) {
    OMHHarnessStateIdle = 0,   // never started
    OMHHarnessStateStarting,   // process launched, waiting for HTTP
    OMHHarnessStateReady,      // HTTP answered; UI may load
    OMHHarnessStateRestarting, // process exited, relaunch scheduled
    OMHHarnessStateFailed,     // gave up (too many crashes / launch error)
    OMHHarnessStateStopped,    // stopped on request
};

NSString *OMHHarnessStateName(OMHHarnessState state);

extern NSNotificationName const OMHHarnessStateDidChangeNotification;

/// Everything OMHHarness needs from the emulator, so tests can fake it.
@protocol OMHGuestProcessLauncher <NSObject>
/// Launches `executable` with `arguments` and `environment` as a child of
/// init. `line` receives every stdout/stderr line; `exit` fires once with the
/// exit code (negative on launch failure). Returns the guest pid, or a
/// negative error code if the process could not be created.
- (int)launchExecutable:(NSString *)executable
              arguments:(NSArray<NSString *> *)arguments
            environment:(NSDictionary<NSString *, NSString *> *)environment
                   line:(void (^)(NSString *line, BOOL isStdErr))line
                   exit:(void (^)(int exitCode))exit;
- (BOOL)killProcess:(int)pid signal:(int)signal;
@end

@interface OMHHarness : NSObject

+ (instancetype)shared;
+ (instancetype)dashboard;

- (instancetype)initWithLauncher:(id<OMHGuestProcessLauncher>)launcher;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) OMHHarnessState state;
@property (nonatomic, readonly) uint16_t port;
/// http://127.0.0.1:<port>/ once a port is chosen (may be nil before start).
@property (nonatomic, readonly, nullable) NSURL *baseURL;
@property (nonatomic, readonly) OMHLogBuffer *log;
@property (nonatomic, readonly) NSUInteger restartCount;
@property (nonatomic, readonly, nullable) NSString *lastError;
@property (nonatomic, readonly) int guestPid;
@property (nonatomic, readonly) NSTimeInterval lastStartupDuration;
/// Expected time from launch to first HTTP answer, from previous runs on this
/// device (25 s until measured once). Used for the startup progress estimate.
@property (nonatomic, readonly) NSTimeInterval expectedStartupDuration;
/// When the current launch started (nil when not starting).
@property (nonatomic, readonly, nullable) NSDate *launchStartedAt;

/// Guest command that serves the web UI. Default /usr/local/bin/opencode-serve.
@property (nonatomic, copy) NSString *serverExecutable;
/// Extra environment passed to the server (OMH_PORT is always set).
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *extraEnvironment;
/// First port tried; default 3080. Up to 20 consecutive ports are probed.
@property (nonatomic) uint16_t preferredPort;
/// Seconds to wait for the first HTTP answer before declaring failure. Default 240.
@property (nonatomic) NSTimeInterval startupTimeout;
/// Consecutive crashes tolerated before giving up. Default 4.
@property (nonatomic) NSUInteger maxConsecutiveCrashes;
/// Failures retained across app launches inside the ten-minute crash-loop
/// window. Test harness instances do not write this production state.
@property (nonatomic, readonly) NSUInteger recentPersistentFailureCount;

- (void)start;
- (void)stop;
- (void)restart;

/// Runs a health check; if the server stopped answering while the process is
/// still up (should not happen) it is restarted. Safe to call on foreground.
- (void)verifyAliveWithCompletion:(nullable void (^)(BOOL alive))completion;

@end

NS_ASSUME_NONNULL_END

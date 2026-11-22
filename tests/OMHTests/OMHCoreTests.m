//
//  OMHCoreTests.m
//  OMHTests
//
//  Unit tests for the app-side logic that does not need the Linux guest:
//  port allocation, the log ring, the readiness probe and the harness
//  supervisor's state machine (driven through a fake process launcher).
//

#import <XCTest/XCTest.h>
#import "OMHPortAllocator.h"
#import "OMHLogBuffer.h"
#import "OMHReadinessProbe.h"
#import "OMHStartupMetrics.h"
#import "OMHHarness.h"
#import "OMHBootCoordinator.h"
#import "OMHTestHTTPServer.h"

#pragma mark - Fake launcher

@interface OMHFakeLauncher : NSObject <OMHGuestProcessLauncher>
@property (nonatomic) NSMutableArray<NSDictionary *> *launches;
@property (nonatomic, copy) void (^onLaunch)(NSDictionary *env, void (^line)(NSString *, BOOL), void (^exit)(int));
@property (nonatomic) int nextPid;
@property (nonatomic) NSMutableArray<NSNumber *> *killed;
@property (nonatomic, copy, nullable) void (^lastExit)(int);
@end

@implementation OMHFakeLauncher
- (instancetype)init {
    if (self = [super init]) { _launches = [NSMutableArray array]; _killed = [NSMutableArray array]; _nextPid = 100; }
    return self;
}
- (int)launchExecutable:(NSString *)executable arguments:(NSArray<NSString *> *)arguments environment:(NSDictionary<NSString *,NSString *> *)environment line:(void (^)(NSString *, BOOL))line exit:(void (^)(int))exit {
    [self.launches addObject:@{@"exe": executable, @"env": environment}];
    self.lastExit = exit;
    if (self.onLaunch) self.onLaunch(environment, line, exit);
    return self.nextPid++;
}
- (BOOL)killProcess:(int)pid signal:(int)signal {
    [self.killed addObject:@(pid)];
    return YES;
}
@end

#pragma mark - Tests

@interface OMHCoreTests : XCTestCase
@end

@implementation OMHCoreTests

- (void)testStartupMetricsRecordsNamedStagesWithoutUserContent {
    OMHStartupMetrics *metrics = OMHStartupMetrics.shared;
    [metrics beginLaunch];
    [metrics mark:@"image_ready"];
    [metrics mark:@"kernel_ready"];
    NSDictionary *latest = metrics.recentLaunches.firstObject;
    XCTAssertNotNil(latest[@"stages"][@"image_ready"]);
    XCTAssertNotNil(latest[@"stages"][@"kernel_ready"]);
    XCTAssertTrue([metrics.summary containsString:@"image="]);
}

- (void)testPortAllocatorSkipsBusyPort {
    OMHTestHTTPServer *server = [[OMHTestHTTPServer alloc] initWithPort:0];
    XCTAssertNotNil(server);
    XCTAssertFalse([OMHPortAllocator isLoopbackPortFree:server.port], @"a listening port is not free");
    uint16_t picked = [OMHPortAllocator freeLoopbackPortStartingAt:server.port span:5];
    XCTAssertNotEqual(picked, 0);
    XCTAssertNotEqual(picked, server.port);
    XCTAssertTrue(picked > server.port && picked < server.port + 5);
    [server stop];
}

- (void)testPortAllocatorReturnsZeroWhenSpanExhausted {
    OMHTestHTTPServer *server = [[OMHTestHTTPServer alloc] initWithPort:0];
    XCTAssertEqual([OMHPortAllocator freeLoopbackPortStartingAt:server.port span:1], 0);
    [server stop];
}

- (void)testLogBufferRingAndNoiseFilter {
    OMHLogBuffer *log = [[OMHLogBuffer alloc] initWithCapacity:3];
    [log append:@"one\n"];
    [log append:@"Warning: disabling flag --expose_wasm due to conflicting flags"];
    [log append:@""];
    [log append:@"two"];
    [log append:@"three"];
    XCTAssertEqualObjects(log.lines, (@[@"one", @"two", @"three"]));
    [log append:@"four"];
    XCTAssertEqualObjects(log.lines, (@[@"two", @"three", @"four"]), @"oldest line is evicted");
    XCTAssertEqualObjects([log tail:2], @"three\nfour");
    XCTAssertEqual(log.count, 3u);
    [log clear];
    XCTAssertEqual(log.count, 0u);
}

- (void)testLogBufferPostsCoalescedNotification {
    OMHLogBuffer *log = [[OMHLogBuffer alloc] initWithCapacity:10];
    XCTestExpectation *e = [self expectationForNotification:OMHLogBufferDidChangeNotification object:log handler:nil];
    e.assertForOverFulfill = NO;
    for (int i = 0; i < 20; i++) [log append:[NSString stringWithFormat:@"l%d", i]];
    [self waitForExpectations:@[e] timeout:2];
    XCTAssertEqual(log.count, 10u);
}

- (void)testLogBufferRedactsCredentialsBeforeRetainingThem {
    OMHLogBuffer *log = [[OMHLogBuffer alloc] initWithCapacity:10];
    [log append:@"DEEPSEEK_API_KEY=secret-value request failed"];
    [log append:@"Authorization: Bearer another-secret"];
    NSString *text = [log.lines componentsJoinedByString:@"\n"];
    XCTAssertFalse([text containsString:@"secret-value"]);
    XCTAssertFalse([text containsString:@"another-secret"]);
    XCTAssertTrue([text containsString:@"<redacted>"]);
}

- (void)testReadinessProbeSucceedsWhenServerAnswers {
    OMHTestHTTPServer *server = [[OMHTestHTTPServer alloc] initWithPort:0];
    OMHReadinessProbe *probe = [[OMHReadinessProbe alloc] initWithURL:server.baseURL interval:0.1 timeout:5];
    XCTestExpectation *e = [self expectationWithDescription:@"ready"];
    [probe startWithHandler:^(BOOL ready, NSTimeInterval elapsed) {
        XCTAssertTrue(ready);
        XCTAssertLessThan(elapsed, 5);
        [e fulfill];
    }];
    [self waitForExpectations:@[e] timeout:6];
    XCTAssertFalse(probe.running);
    XCTAssertGreaterThan(server.requestCount, 0u);
    [server stop];
}

- (void)testReadinessProbeRejectsMethodNotAllowedUntilTimeout {
    OMHTestHTTPServer *server = [[OMHTestHTTPServer alloc] initWithPort:0];
    server.statusCode = 405;
    OMHReadinessProbe *probe = [[OMHReadinessProbe alloc] initWithURL:server.baseURL interval:0.1 timeout:1];
    XCTestExpectation *done = [self expectationWithDescription:@"HTTP 405 is not readiness"];
    [probe startWithHandler:^(BOOL ready, NSTimeInterval elapsed) {
        XCTAssertFalse(ready, @"HTTP 405 must not mark the guest server ready");
        XCTAssertGreaterThanOrEqual(elapsed, 1.0);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:4];
    XCTAssertGreaterThan(server.requestCount, 0u);
    [server stop];
}

- (void)testReadinessProbeTimesOutOnClosedPort {
    uint16_t port = [OMHPortAllocator freeLoopbackPortStartingAt:39000 span:100];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/", port]];
    OMHReadinessProbe *probe = [[OMHReadinessProbe alloc] initWithURL:url interval:0.1 timeout:1];
    XCTestExpectation *e = [self expectationWithDescription:@"timeout"];
    [probe startWithHandler:^(BOOL ready, NSTimeInterval elapsed) {
        XCTAssertFalse(ready);
        XCTAssertGreaterThanOrEqual(elapsed, 1.0);
        [e fulfill];
    }];
    [self waitForExpectations:@[e] timeout:5];
}

- (void)testReadinessProbeCancelFiresHandlerOnce {
    uint16_t port = [OMHPortAllocator freeLoopbackPortStartingAt:39200 span:100];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/", port]];
    OMHReadinessProbe *probe = [[OMHReadinessProbe alloc] initWithURL:url interval:0.1 timeout:30];
    __block int calls = 0;
    [probe startWithHandler:^(BOOL ready, NSTimeInterval elapsed) { calls++; XCTAssertFalse(ready); }];
    [probe cancel];
    [probe cancel];
    XCTAssertEqual(calls, 1);
    XCTAssertFalse(probe.running);
}

- (void)testHarnessReachesReadyAndPassesPortToGuest {
    // The fake "guest" is a host HTTP server on whatever port the harness picks.
    OMHFakeLauncher *launcher = [OMHFakeLauncher new];
    __block OMHTestHTTPServer *server = nil;
    launcher.onLaunch = ^(NSDictionary *env, void (^line)(NSString *, BOOL), void (^exit)(int)) {
        uint16_t port = (uint16_t) [env[@"OMH_PORT"] intValue];
        server = [[OMHTestHTTPServer alloc] initWithPort:port];
        line([NSString stringWithFormat:@"omh web: http://127.0.0.1:%u", port], NO);
        line(@"Warning: disabling flag --expose_wasm due to conflicting flags", YES);
    };
    OMHHarness *h = [[OMHHarness alloc] initWithLauncher:launcher];
    h.preferredPort = 38080;
    h.startupTimeout = 10;
    XCTAssertEqual(h.state, OMHHarnessStateIdle);
    XCTAssertNil(h.baseURL);

    XCTestExpectation *ready = [self expectationForNotification:OMHHarnessStateDidChangeNotification object:h handler:^BOOL(NSNotification *n) {
        return h.state == OMHHarnessStateReady;
    }];
    [h start];
    XCTAssertEqual(h.state, OMHHarnessStateStarting);
    XCTAssertEqual(launcher.launches.count, 1u);
    NSDictionary *first = launcher.launches.firstObject;
    NSString *exe = first[@"exe"];
    NSString *envPort = first[@"env"][@"OMH_PORT"];
    NSString *expectedPort = [NSString stringWithFormat:@"%u", h.port];
    XCTAssertEqualObjects(exe, @"/usr/local/bin/opencode-serve");
    XCTAssertEqualObjects(envPort, expectedPort);
    XCTAssertTrue(h.port >= 38080 && h.port < 38100);
    [self waitForExpectations:@[ready] timeout:10];

    XCTAssertEqualObjects(h.baseURL.absoluteString, ([NSString stringWithFormat:@"http://127.0.0.1:%u/", h.port]));
    XCTAssertTrue([[h.log tail:50] containsString:@"omh web: http://127.0.0.1:"]);
    XCTAssertFalse([[h.log tail:50] containsString:@"expose_wasm"], @"noise is filtered");
    XCTAssertTrue([[h.log tail:50] containsString:@"server answered"]);
    XCTAssertGreaterThan(h.guestPid, 0);

    // stop kills the guest and reports stopped
    [h stop];
    XCTAssertEqual(h.state, OMHHarnessStateStopped);
    XCTAssertEqualObjects(launcher.killed.lastObject, @(100));
    [server stop];
}

- (void)testHarnessRelaunchesAfterCrashThenGivesUp {
    OMHFakeLauncher *launcher = [OMHFakeLauncher new];
    launcher.onLaunch = ^(NSDictionary *env, void (^line)(NSString *, BOOL), void (^exit)(int)) {
        // crash right away, asynchronously like the real executor
        dispatch_async(dispatch_get_main_queue(), ^{ exit(7); });
    };
    OMHHarness *h = [[OMHHarness alloc] initWithLauncher:launcher];
    h.preferredPort = 38200;
    h.maxConsecutiveCrashes = 2;   // back-off 1s, 2s -> then failed
    XCTestExpectation *failed = [self expectationForNotification:OMHHarnessStateDidChangeNotification object:h handler:^BOOL(NSNotification *n) {
        return h.state == OMHHarnessStateFailed;
    }];
    [h start];
    [self waitForExpectations:@[failed] timeout:15];
    XCTAssertEqual(launcher.launches.count, 3u, @"initial launch + 2 retries");
    XCTAssertTrue([h.lastError containsString:@"exited with code 7"]);
    XCTAssertGreaterThanOrEqual(h.restartCount, 2u);
}

- (void)testHarnessRestartRelaunchesOnSamePort {
    OMHFakeLauncher *launcher = [OMHFakeLauncher new];
    NSMutableArray<OMHTestHTTPServer *> *servers = [NSMutableArray array];
    launcher.onLaunch = ^(NSDictionary *env, void (^line)(NSString *, BOOL), void (^exit)(int)) {
        [servers addObject:[[OMHTestHTTPServer alloc] initWithPort:(uint16_t) [env[@"OMH_PORT"] intValue]]];
    };
    OMHHarness *h = [[OMHHarness alloc] initWithLauncher:launcher];
    h.preferredPort = 38300;
    XCTestExpectation *ready1 = [self expectationForNotification:OMHHarnessStateDidChangeNotification object:h handler:^BOOL(NSNotification *n) { return h.state == OMHHarnessStateReady; }];
    [h start];
    [self waitForExpectations:@[ready1] timeout:10];
    uint16_t port = h.port;
    [servers.lastObject stop];   // the "old" server goes away with the kill

    XCTestExpectation *ready2 = [self expectationForNotification:OMHHarnessStateDidChangeNotification object:h handler:^BOOL(NSNotification *n) { return h.state == OMHHarnessStateReady; }];
    [h restart];
    XCTAssertEqual(h.state, OMHHarnessStateStopped, @"restart first stops");
    [self waitForExpectations:@[ready2] timeout:10];
    XCTAssertEqual(h.port, port, @"same port reused when free");
    XCTAssertEqual(launcher.launches.count, 2u);
    XCTAssertEqual(h.restartCount, 1u);
    for (OMHTestHTTPServer *s in servers) [s stop];
}

- (void)testStateNames {
    XCTAssertEqualObjects(OMHHarnessStateName(OMHHarnessStateReady), @"ready");
    XCTAssertEqualObjects(OMHHarnessStateName(OMHHarnessStateFailed), @"failed");
    XCTAssertEqualObjects(OMHHarnessStateName(OMHHarnessStateIdle), @"idle");
}

@end

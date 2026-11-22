//
//  OMHCallConfirmationTests.m
//  OMHTests
//
//  The gate every write capability sits behind. These assert the three rules
//  that make blocking a bridge handler on a dialog safe: never wait on a
//  dialog nobody can see, never stack them, and always answer.
//
//  Two of them put a real alert on screen on purpose — that is the only way to
//  prove an unanswered prompt times out rather than hanging. Their titles say
//  "OMH self-test" so that anyone watching a device during a test run can see
//  what it is instead of meeting an unexplained "Allow".
//

#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import "OMHCallConfirmation.h"
#import "OMHHostBridge.h"
#import "OMHActivityLog.h"

@interface OMHCallConfirmationTests : XCTestCase
@end

@implementation OMHCallConfirmationTests

- (void)tearDown {
    OMHCallConfirmation.automaticallyApproveForTesting = NO;
    OMHCallConfirmation.automaticallyDeclineForTesting = NO;
    [super tearDown];
}

/// Even a decision made without a dialog is a decision, and the record is the
/// only place a user can see that one was made.
- (void)testEveryOutcomeReachesTheActivityRecord {
    [OMHActivityLog.shared resetForTesting];
    OMHCallConfirmation.automaticallyDeclineForTesting = YES;
    [OMHCallConfirmation confirmTitle:@"OMH self-test" detail:@"Not a real request."];
    OMHCallConfirmation.automaticallyDeclineForTesting = NO;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    OMHActivityEntry *entry = nil;
    while (entry == nil && [deadline timeIntervalSinceNow] > 0) {
        entry = OMHActivityLog.shared.entries.firstObject;
        if (entry == nil)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    XCTAssertNotNil(entry, @"a decision that skipped the dialog still has to be recorded");
    XCTAssertEqual(entry.outcome, OMHActivityOutcomeDeclined);
    [OMHActivityLog.shared resetForTesting];
}

- (void)testTestHooksShortCircuitWithoutShowingAnything {
    NSUInteger before = OMHCallConfirmation.presentedCount;
    OMHCallConfirmation.automaticallyApproveForTesting = YES;
    XCTAssertEqual([OMHCallConfirmation confirmTitle:@"OMH self-test" detail:@"Not a real request."], OMHConfirmationGranted);
    OMHCallConfirmation.automaticallyApproveForTesting = NO;
    OMHCallConfirmation.automaticallyDeclineForTesting = YES;
    XCTAssertEqual([OMHCallConfirmation confirmTitle:@"OMH self-test" detail:@"Not a real request."], OMHConfirmationDeclined);
    XCTAssertEqual(OMHCallConfirmation.presentedCount, before,
                   @"the test hooks must not put a real alert on screen");
}

/// The bridge handler runs on a background queue. Confirming from there must
/// not deadlock against the main queue that shows the alert — a real risk,
/// since the alert is presented with a dispatch to main while this waits.
- (void)testConfirmingFromABackgroundQueueDoesNotDeadlock {
    XCTestExpectation *done = [self expectationWithDescription:@"answered"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // No foreground UI in a unit-test host, so this must come back
        // Unavailable rather than hang.
        OMHConfirmationOutcome outcome = [OMHCallConfirmation confirmTitle:@"OMH self-test (background)" detail:@"Not a real request — this dismisses itself." timeout:3];
        XCTAssertNotEqual(outcome, OMHConfirmationGranted);
        [done fulfill];
    });
    [self waitForExpectations:@[done] timeout:15];
}

/// Every outcome has to produce a response the model can act on — and the two
/// that mean "try later" have to be marked recoverable, while a decline must
/// not be, or the agent will simply ask again.
- (void)testEveryOutcomeMapsToAnActionableResponse {
    XCTAssertNil([OMHCallConfirmation refusalFor:OMHConfirmationGranted action:@"x"]);

    OMHHostBridgeResponse *declined = [OMHCallConfirmation refusalFor:OMHConfirmationDeclined action:@"copying text"];
    XCTAssertEqual(declined.status, 403);
    XCTAssertEqualObjects(declined.body[@"error"][@"recoverable"], @NO,
                          @"a decline must not invite a retry");
    XCTAssertTrue([declined.body[@"error"][@"message"] containsString:@"copying text"],
                  @"the message should name the action: %@", declined.body[@"error"][@"message"]);

    OMHHostBridgeResponse *timedOut = [OMHCallConfirmation refusalFor:OMHConfirmationTimedOut action:@"copying text"];
    XCTAssertEqual(timedOut.status, 408);
    XCTAssertEqualObjects(timedOut.body[@"error"][@"recoverable"], @YES);

    OMHHostBridgeResponse *unavailable = [OMHCallConfirmation refusalFor:OMHConfirmationUnavailable action:@"copying text"];
    XCTAssertEqual(unavailable.status, 409);
    XCTAssertEqualObjects(unavailable.body[@"error"][@"code"], @"unavailable");
    XCTAssertEqualObjects(unavailable.body[@"error"][@"recoverable"], @YES);
}

/// A loop in the agent must not become a wall of dialogs: while one prompt is
/// up, the rest are refused rather than queued.
- (void)testConcurrentConfirmationsDoNotStack {
    NSUInteger before = OMHCallConfirmation.presentedCount;
    dispatch_group_t group = dispatch_group_create();
    NSLock *lock = [NSLock new];
    NSMutableArray<NSNumber *> *outcomes = [NSMutableArray array];
    for (int i = 0; i < 5; i++) {
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            OMHConfirmationOutcome outcome = [OMHCallConfirmation confirmTitle:@"OMH self-test (burst)" detail:@"Not a real request — this dismisses itself." timeout:2];
            [lock lock];
            [outcomes addObject:@(outcome)];
            [lock unlock];
        });
    }
    XCTAssertEqual(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t) (30 * NSEC_PER_SEC))), 0,
                   @"a burst of confirmations must not hang");
    XCTAssertEqual(outcomes.count, 5u);
    for (NSNumber *outcome in outcomes)
        XCTAssertNotEqual(outcome.integerValue, OMHConfirmationGranted,
                          @"nothing may be granted without a human");
    XCTAssertLessThanOrEqual(OMHCallConfirmation.presentedCount - before, 1u,
                             @"at most one alert may be presented at a time");
}

@end

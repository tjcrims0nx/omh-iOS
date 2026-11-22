//
//  OMHPermissionPromptTests.m
//  OMHTests
//
//  Turning a capability on asks iOS for the matching permission right away, from
//  the switch's own handler — that is, on the main thread. Anything that blocks
//  there deadlocks the app: no crash report, just a frozen main thread and a
//  watchdog kill a few seconds later, which reads to the user as a crash.
//

#import <XCTest/XCTest.h>
#import "OMHCapability.h"
#import "OMHHostBridge.h"
#import "OMHLocationCapability.h"
#import "OMHHealthCapability.h"
#import "OMHNotificationCapability.h"
#import "OMHEventKitCapability.h"
#import "OMHContactsCapability.h"

@interface OMHPermissionPromptTests : XCTestCase
@end

@implementation OMHPermissionPromptTests {
    OMHHostBridge *_bridge;
}

- (void)setUp {
    [super setUp];
    _bridge = [[OMHHostBridge alloc] init];
    [OMHLocationCapability installOn:_bridge];
    [OMHHealthCapability installOn:_bridge];
    [OMHNotificationCapability installOn:_bridge];
    [OMHEventKitCapability installOn:_bridge];
    [OMHContactsCapability installOn:_bridge];
}

/// Every permission block must return promptly when called the way the switch
/// calls it. The dialog itself is asynchronous; asking for it must not block.
- (void)testRequestingPermissionFromTheMainThreadDoesNotBlock {
    for (OMHCapability *capability in OMHCapabilityRegistry.shared.capabilities) {
        if (!capability.requestSystemPermission || !capability.available) continue;

        XCTestExpectation *returned =
            [self expectationWithDescription:capability.identifier];
        dispatch_async(dispatch_get_main_queue(), ^{
            capability.requestSystemPermission();
            [returned fulfill];
        });
        // Generous: the point is to catch a block that never returns at all.
        XCTWaiterResult result = [XCTWaiter waitForExpectations:@[returned] timeout:5];
        XCTAssertEqual(result, XCTWaiterResultCompleted,
                       @"%@ blocked the main thread when asked for permission",
                       capability.identifier);
        if (result != XCTWaiterResultCompleted) return;  // the main thread is wedged
    }
}

/// App Store Connect statically checks the CoreLocation API surface and requires
/// both strings even though OMH only requests when-in-use authorization.
- (void)testLocationUsageDescriptionsArePresent {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    for (NSString *key in @[@"NSLocationWhenInUseUsageDescription",
                             @"NSLocationAlwaysAndWhenInUseUsageDescription"]) {
        NSString *purpose = info[key];
        XCTAssertGreaterThan(purpose.length, 0,
                             @"%@ is missing; App Store validation will reject the archive", key);
    }
}

@end

//
//  OMHLaunchUITests.m
//  OMHUITests
//
//  End-to-end checks on a real device/simulator: the app boots the Linux
//  guest, opencode-serve comes up, the WKWebView shows the OpenMind Harness
//  web UI, and the native controls (terminal, log, menu) work.
//

#import <XCTest/XCTest.h>

static const NSTimeInterval kBootTimeout = 300;   // first launch imports the rootfs

@interface OMHLaunchUITests : XCTestCase
@property (nonatomic) XCUIApplication *app;
@end

@implementation OMHLaunchUITests

- (void)setUp {
    self.continueAfterFailure = NO;
    self.app = [[XCUIApplication alloc] init];
    [self.app launch];
}

- (void)attachScreenshot:(NSString *)name {
    XCTAttachment *att = [XCTAttachment attachmentWithScreenshot:[XCUIScreen.mainScreen screenshot]];
    att.name = name;
    att.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:att];
}

/// Waits until the harness overlay is gone (server answered and page loaded).
- (void)waitForHarnessReady {
    XCUIElement *open = self.app.buttons[@"omh.open-editor"];
    if (open.exists) {
        NSPredicate *enabled = [NSPredicate predicateWithFormat:@"enabled == YES"];
        [self waitForExpectations:@[[self expectationForPredicate:enabled evaluatedWithObject:open handler:nil]] timeout:kBootTimeout];
        [open tap];
    }
    XCUIElement *overlay = self.app.staticTexts[@"omh.overlay.message"];
    XCUIElement *dot = self.app.otherElements[@"omh.statusdot"];
    NSPredicate *gone = [NSPredicate predicateWithFormat:@"exists == NO OR hittable == NO"];
    XCTestExpectation *e = [self expectationForPredicate:gone evaluatedWithObject:overlay handler:nil];
    [self waitForExpectations:@[e] timeout:kBootTimeout];
    if (dot.exists)
        XCTAssertEqualObjects(dot.value, @"ready", @"status dot should report ready");
}

/// iPhone-specific native shell smoke: the same OMH landing screen must
/// remain touch-usable in portrait and landscape, not only on an iPad.
- (void)testIOSPhoneNativeDashboardAndEditor {
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    XCUIElement *refresh = self.app.buttons[@"omh.native.refresh"];
    XCUIElement *editor = self.app.buttons[@"omh.open-editor"];
    XCTAssertTrue([refresh waitForExistenceWithTimeout:15], @"iPhone must open the native OMH dashboard shell");
    XCTAssertTrue([editor waitForExistenceWithTimeout:15], @"OpenCode must be reachable on iPhone");
    XCTAssertTrue([self.app.images[@"omh.native.brand.logo"] waitForExistenceWithTimeout:10]);
    XCTAssertGreaterThanOrEqual(CGRectGetHeight(refresh.frame), 40);
    // The dashboard web view stays hidden until the guest boots and the
    // page finishes loading, so wait for it like the iPad test waits for
    // the dashboard's own controls instead of asserting it immediately.
    XCTAssertTrue([self.app.webViews.firstMatch waitForExistenceWithTimeout:kBootTimeout], @"iOS includes the embedded dashboard");
    [self attachScreenshot:@"ios-phone-portrait-native-dashboard"];

    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    XCTAssertTrue([refresh waitForExistenceWithTimeout:10], @"Native actions survive iPhone rotation");
    XCTAssertTrue([editor waitForExistenceWithTimeout:10]);
    [self attachScreenshot:@"ios-phone-landscape-native-dashboard"];

    NSPredicate *ready = [NSPredicate predicateWithFormat:@"enabled == YES"];
    [self waitForExpectations:@[[self expectationForPredicate:ready evaluatedWithObject:editor handler:nil]]
                     timeout:kBootTimeout];
    [editor tap];
    XCTAssertTrue([self.app.otherElements[@"omh.controlbar"] waitForExistenceWithTimeout:30],
                  @"iOS editor must open inside native OMH navigation");
    [self attachScreenshot:@"ios-phone-open-code-editor"];
}

- (void)testHarnessBootsAndShowsWebUI {
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    XCUIElement *startup = self.app.staticTexts[@"omh.startup.status"];
    if ([startup waitForExistenceWithTimeout:8]) {
        XCTAssertTrue(self.app.progressIndicators[@"omh.startup.progress"].exists,
                      @"Native iPad startup reports boot progress");
        XCTAssertTrue(self.app.buttons[@"omh.startup.toggle-logs"].exists,
                      @"Boot logs must remain available before entering chat");
        [self attachScreenshot:@"00-ipad-startup-native"];
    }
    // The app must not enter its chat screen until BOTH local services answer.
    XCUIElement *web = self.app.webViews[@"omh.webview"];
    XCTAssertTrue([web waitForExistenceWithTimeout:kBootTimeout],
                  @"A ready Linux guest must open the iPad conversation web view");
    XCTAssertFalse(startup.exists, @"The pre-chat boot gate must have finished");
    XCUIElement *dot = self.app.otherElements[@"omh.statusdot"];
    NSPredicate *ready = [NSPredicate predicateWithFormat:@"value == 'ready'"];
    [self waitForExpectations:@[[self expectationForPredicate:ready evaluatedWithObject:dot handler:nil]]
                     timeout:kBootTimeout];
    XCTAssertTrue([self.app.otherElements[@"omh.controlbar"] waitForExistenceWithTimeout:10],
                  @"The compact native iPad control bar is required");
    XCTAssertFalse(self.app.navigationBars.buttons.firstMatch.exists,
                   @"The redundant blank iPad navigation/back button must be removed");
    [self attachScreenshot:@"01-ipad-chat-landscape"];

    // Real loaded OpenCode UI, not the read-only OMH search dashboard.
    XCUIElementQuery *inputs = [web descendantsMatchingType:XCUIElementTypeTextView];
    XCUIElementQuery *fields = [web descendantsMatchingType:XCUIElementTypeTextField];
    BOOL hasComposer = [inputs.firstMatch waitForExistenceWithTimeout:60] ||
                       [fields.firstMatch waitForExistenceWithTimeout:10];
    XCTAssertTrue(hasComposer, @"OpenCode must expose a conversation text composer");
    XCTAssertTrue([self.app.buttons[@"omh.sidebar.workspace"] waitForExistenceWithTimeout:10],
                  @"iPad landscape must show the compact tool rail");
    XCUIElement *log = self.app.buttons[@"omh.sidebar.log"];
    [log tap];
    XCUIElement *logView = self.app.textViews[@"omh.logview"];
    XCTAssertTrue([logView waitForExistenceWithTimeout:10]);
    NSString *startupLog = logView.value;
    XCTAssertTrue([startupLog containsString:@"server answered"],
                  @"Server must really answer before the chat screen appears");
    XCTAssertFalse([startupLog containsString:@"ESPIPE: invalid seek"]);
    [self attachScreenshot:@"02-ipad-chat-log"];
    [self.app.buttons[@"Done"] tap];
    XCTAssertTrue(web.hittable, @"Closing diagnostics restores live chat");

    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    XCTAssertTrue([self.app.buttons[@"omh.menu"] waitForExistenceWithTimeout:10],
                  @"More menu must survive orientation change");
    XCTAssertTrue(web.hittable, @"Chat remains usable in iPad portrait");
    [self attachScreenshot:@"03-ipad-chat-portrait"];
}

- (void)testServerLogIsReachableFromMenu {
    [self waitForHarnessReady];
    XCUIElement *menu = self.app.buttons[@"omh.menu"];
    XCTAssertTrue([menu waitForExistenceWithTimeout:10]);
    [menu tap];
    XCUIElement *logItem = self.app.buttons[@"Server Log"];
    XCTAssertTrue([logItem waitForExistenceWithTimeout:5], @"menu should list Server Log");
    [logItem tap];
    XCUIElement *logView = self.app.textViews[@"omh.logview"];
    XCTAssertTrue([logView waitForExistenceWithTimeout:10]);
    NSString *text = (NSString *) logView.value;
    XCTAssertTrue([text containsString:@"server answered"], @"log should record readiness, got: %@", text);
    XCTAssertTrue([text containsString:@"opencode server listening on http://127.0.0.1:"], @"log should contain the OpenCode listener address, got: %@", text);
    [self attachScreenshot:@"04-log"];
    [self.app.buttons[@"Done"] tap];
}

/// The capabilities screen is the only way a user can turn a bridge capability
/// on, so the switch has to be reachable, ask before granting, and stick.
///
/// This drives `device.info`, the one capability with no system permission
/// behind it. Capabilities that do have one (Health, Calendar, Reminders) put
/// up a sheet owned by another process, which XCUITest cannot reliably dismiss
/// from here; that they can ask at all is asserted in
/// OMHHealthCapabilityTests.testCapabilityCanAskForItsSystemPermission.
- (void)testCapabilitiesScreenTogglesACapability {
    [self waitForHarnessReady];
    XCUIElement *menu = self.app.buttons[@"omh.menu"];
    XCTAssertTrue([menu waitForExistenceWithTimeout:10]);
    [menu tap];
    XCUIElement *item = self.app.buttons[@"Capabilities"];
    XCTAssertTrue([item waitForExistenceWithTimeout:5], @"menu should list Capabilities");
    [item tap];

    XCUIElement *table = self.app.tables[@"omh.capabilities"];
    XCTAssertTrue([table waitForExistenceWithTimeout:10]);
    // The sensitive capabilities must at least be listed, or there is no way
    // for a user to reach them — reads in one section, writes in the other.
    XCTAssertTrue([self.app.switches[@"omh.capability.switch.health.read"] waitForExistenceWithTimeout:10],
                  @"Apple Health should be listed");
    XCTAssertTrue(self.app.switches[@"omh.capability.switch.calendar.read"].exists,
                  @"Calendar should be listed");
    XCTAssertTrue(self.app.staticTexts[@"What the agent can read"].exists,
                  @"reads and writes should be separated");
    XCTAssertTrue(self.app.staticTexts[@"What the agent can change"].exists);
    [self attachScreenshot:@"05-capabilities"];

    XCUIElement *device = self.app.switches[@"omh.capability.switch.device.info"];
    XCTAssertTrue([device waitForExistenceWithTimeout:10]);
    NSPredicate *isOn = [NSPredicate predicateWithFormat:@"value == '1'"];
    NSPredicate *isOff = [NSPredicate predicateWithFormat:@"value == '0'"];

    // Switches persist across launches and this app is not reinstalled between
    // runs, so start by normalising rather than assuming a fresh install.
    // Turning something off is immediate — only turning it on asks.
    if ([device.value isEqual:@"1"]) {
        [device tap];
        [self waitForExpectations:@[[self expectationForPredicate:isOff evaluatedWithObject:device handler:nil]] timeout:10];
    }

    [device tap];
    XCUIElement *allow = self.app.alerts.buttons[@"Allow"];
    XCTAssertTrue([allow waitForExistenceWithTimeout:5], @"enabling should ask first, naming what is granted");
    [allow tap];
    [self waitForExpectations:@[[self expectationForPredicate:isOn evaluatedWithObject:device handler:nil]] timeout:10];

    // Cancelling must leave it as it was.
    [device tap];
    [self waitForExpectations:@[[self expectationForPredicate:isOff evaluatedWithObject:device handler:nil]] timeout:10];
    [device tap];
    XCUIElement *cancel = self.app.alerts.buttons[@"Cancel"];
    XCTAssertTrue([cancel waitForExistenceWithTimeout:5]);
    [cancel tap];
    [self waitForExpectations:@[[self expectationForPredicate:isOff evaluatedWithObject:device handler:nil]] timeout:10];

    // device.info ships on; leave it that way.
    [device tap];
    [self.app.alerts.buttons[@"Allow"] tap];
    [self waitForExpectations:@[[self expectationForPredicate:isOn evaluatedWithObject:device handler:nil]] timeout:10];
    [self.app.buttons[@"Done"] tap];
}

/// The Activity screen is where a user checks what the agent has been doing,
/// so it has to be reachable and readable — including on a phone, where its
/// monospaced rows and multi-line details have the least room.
- (void)testActivityScreenIsReachableAndReadable {
    [self waitForHarnessReady];
    XCUIElement *menu = self.app.buttons[@"omh.menu"];
    XCTAssertTrue([menu waitForExistenceWithTimeout:10]);
    [menu tap];
    XCUIElement *item = self.app.buttons[@"Activity"];
    XCTAssertTrue([item waitForExistenceWithTimeout:5], @"menu should list Activity");
    [item tap];

    XCUIElement *table = self.app.tables[@"omh.activity"];
    XCTAssertTrue([table waitForExistenceWithTimeout:10]);
    [self attachScreenshot:@"06-activity"];

    // Either there are rows or the empty state explains itself; a blank screen
    // with neither is the failure worth catching.
    BOOL hasRows = table.cells.count > 0;
    XCTAssertTrue(hasRows, @"the table should show rows or an empty-state row");

    // The filters are the point of the screen for anyone looking for trouble.
    XCTAssertTrue(self.app.buttons[@"Problems"].exists, @"filters should be reachable");
    [self.app.buttons[@"Problems"] tap];
    XCTAssertTrue([table waitForExistenceWithTimeout:5]);
    [self attachScreenshot:@"07-activity-problems"];

    [self.app.buttons[@"Done"] tap];
}

- (void)testLandscapeKeepsWebViewAndBar {
    [self waitForHarnessReady];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    sleep(2);
    XCUIElement *web = self.app.webViews.firstMatch;
    XCTAssertTrue([web waitForExistenceWithTimeout:10]);
    CGRect frame = web.frame;
    XCTAssertGreaterThan(frame.size.width, frame.size.height, @"web view should be wider than tall in landscape (%@)", NSStringFromCGRect(frame));
    XCTAssertTrue(self.app.buttons[@"omh.menu"].isHittable, @"control bar stays reachable in landscape");
    [self attachScreenshot:@"06-landscape"];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    sleep(1);
    XCTAssertTrue(self.app.webViews.firstMatch.exists);
}

- (void)testTerminalOpensAndDismisses {
    [self waitForHarnessReady];
    XCUIElement *terminal = self.app.buttons[@"omh.terminal"];
    XCTAssertTrue([terminal waitForExistenceWithTimeout:10]);
    [terminal tap];
    // The iSH terminal is an hterm web view inside a sheet.
    XCUIElement *termWeb = [self.app.webViews elementBoundByIndex:1];
    XCTAssertTrue([termWeb waitForExistenceWithTimeout:20], @"terminal sheet should present a second web view");
    sleep(3);
    [self attachScreenshot:@"05-terminal"];
    // Swipe the sheet down to dismiss; the main web view is still there.
    [termWeb swipeDown];
    sleep(1);
    XCTAssertTrue(self.app.webViews.firstMatch.exists);
}

@end

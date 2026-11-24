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
@property (nonatomic) BOOL needsCleanup;
@end

@implementation OMHLaunchUITests

- (void)setUp {
    self.continueAfterFailure = NO;
    self.needsCleanup = NO;
    self.app = [[XCUIApplication alloc] init];
    [self.app launch];
    [self waitForDashboardLaunch];
}

- (void)waitForDashboardLaunch {
    XCUIElement *gate = self.app.staticTexts[@"omh.launch.status"];
    XCUIElement *dashboard = self.app.buttons[@"omh.native.settings"];
    // A first-run install must show setup before any dashboard controls.
    if (gate.exists) {
        XCTAssertFalse(dashboard.exists, @"Dashboard chrome must remain hidden during boot");
        XCTAssertFalse(self.app.buttons[@"omh.launch.configure-provider"].exists,
                       @"The first-run startup must remain provider-neutral");
        [self attachScreenshot:@"00-native-boot-gate"];
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kBootTimeout];
    while (!dashboard.exists && [deadline timeIntervalSinceNow] > 0) {
        XCUIElement *proceed = self.app.buttons[@"omh.launch.continue"];
        if (proceed.exists && proceed.hittable) [proceed tap];
        if (dashboard.exists) break;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
    }
    XCTAssertTrue([dashboard waitForExistenceWithTimeout:10],
                  @"Dashboard must replace the full-screen gate after verified runtime readiness");
    XCTAssertFalse(gate.exists, @"Startup gate must be removed, not overlaid over the dashboard");
    // The Settings gear is the dashboard settings entry point; provider
    // setup lives in its menu, not in first-run startup. The menu items
    // themselves are verified by openSettingsMenu in the tests that use them.
    XCTAssertTrue([self.app.buttons[@"omh.native.settings"] waitForExistenceWithTimeout:10],
                  @"Provider setup belongs in the dashboard settings, not first-run startup");
}

/// Opens the dashboard Settings gear menu and asserts its three actions
/// are present: Providers, OpenCode and Refresh. Dismisses the menu by
/// tapping the gear again when called only to verify the menu contents.
- (void)openSettingsMenu {
    // If a previous menu is still open, the gear is unhittable while its
    // popover is up (XCTest computes hit point {-1,-1}), so a fresh tap
    // lands nowhere. Close any stale menu first, then open a fresh one.
    [self ensureSettingsMenuClosed];
    XCUIElement *settings = self.app.buttons[@"omh.native.settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:15], @"Dashboard must provide a Settings gear");
    [settings tap];
    XCTAssertTrue([self.app.buttons[@"Providers"] waitForExistenceWithTimeout:5], @"Settings must list Providers");
    XCTAssertTrue([self.app.buttons[@"OpenCode"] waitForExistenceWithTimeout:5], @"Settings must list OpenCode");
    XCTAssertTrue([self.app.buttons[@"Refresh dashboard"] waitForExistenceWithTimeout:5], @"Settings must list Refresh");
}

/// Dismisses the dashboard Settings menu by tapping the brand logo in the
/// header, outside the popover. Tapping the gear again does NOT dismiss it
/// on iPad: while the menu popover is open the gear is unhittable (XCTest
/// computes hit point {-1,-1}), so the tap lands nowhere and the menu stays
/// open (CI run 45478763878, iPad).
- (void)dismissSettingsMenu {
    [self ensureSettingsMenuClosed];
}

/// Opens the OpenCode editor from the dashboard Settings menu, waiting
/// until the runtime is ready and the menu action is enabled.
- (void)openEditorFromSettings {
    [self openSettingsMenu];
    XCUIElement *open = self.app.buttons[@"OpenCode"];
    NSPredicate *enabled = [NSPredicate predicateWithFormat:@"enabled == YES"];
    [self waitForExpectations:@[[self expectationForPredicate:enabled evaluatedWithObject:open handler:nil]] timeout:kBootTimeout];
    [open tap];
}

- (void)tearDown {
    if (self.needsCleanup) {
        // Best-effort cleanup so a failed run does not leave the throwaway
        // key in the Keychain and poison the next run's pre-state.
        @try {
            [self removeTestCredential];
        } @catch (NSException *exception) {
            // Cleanup is best-effort in tearDown; the original failure stands.
        }
        self.needsCleanup = NO;
    }
    [super tearDown];
}

- (void)attachScreenshot:(NSString *)name {
    XCTAttachment *att = [XCTAttachment attachmentWithScreenshot:[XCUIScreen.mainScreen screenshot]];
    att.name = name;
    att.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:att];
}

/// Waits until the harness overlay is gone (server answered and page loaded).
/// Closes the dashboard Settings menu if it is open, by tapping the brand
/// logo in the header, outside the popover. A no-op when the menu is already
/// closed. Needed before any fresh gear tap: while the menu popover is open
/// the gear is unhittable (XCTest computes hit point {-1,-1}), so tapping
/// it again lands nowhere (CI run 45478763878, iPad).
- (void)ensureSettingsMenuClosed {
    if (self.app.buttons[@"Providers"].exists) {
        [self.app.images[@"omh.native.brand.logo"] tap];
        NSPredicate *gone = [NSPredicate predicateWithFormat:@"exists == NO"];
        [self waitForExpectations:@[[self expectationForPredicate:gone evaluatedWithObject:self.app.buttons[@"Providers"] handler:nil]] timeout:5];
    }
}

- (void)waitForHarnessReady {
    // Waits for readiness AND navigates to the editor. The navigation is
    // load-bearing, not a gratuitous side effect: omh.menu and
    // omh.sidebar.* live in OMHRootViewController (the editor), so tests
    // that call this helper expect to be in the editor afterwards.
    // Removing it broke testServerLogIsReachableFromMenu and the iPad
    // sidebar checks (CI run 45483214834). openSettingsMenu closes any
    // stale menu before tapping the gear, so a previous popover cannot
    // leave the gear unhittable (CI run 45478763878, iPad).
    XCUIElement *settings = self.app.buttons[@"omh.native.settings"];
    if (settings.exists) {
        [self openEditorFromSettings];
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
    XCUIElement *settings = self.app.buttons[@"omh.native.settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:15], @"iPhone must open the native OMH dashboard shell");
    // The brand logo lives in a dedicated responsive header, not in the
    // navigation bar, so it must appear on a compact iPhone without
    // competing with toolbar actions for width.
    XCTAssertTrue([self.app.images[@"omh.native.brand.logo"] waitForExistenceWithTimeout:10], @"Brand logo must appear in the dashboard header on iPhone");
    XCTAssertGreaterThanOrEqual(CGRectGetHeight(settings.frame), 40);
    // The dashboard web view stays hidden until the guest boots and the
    // page finishes loading, so wait for it like the iPad test waits for
    // the dashboard's own controls instead of asserting it immediately.
    XCTAssertTrue([self.app.webViews.firstMatch waitForExistenceWithTimeout:kBootTimeout], @"iOS includes the embedded dashboard");
    [self attachScreenshot:@"ios-phone-portrait-native-dashboard"];

    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    XCTAssertTrue([settings waitForExistenceWithTimeout:10], @"Native actions survive iPhone rotation");
    XCTAssertTrue([self.app.images[@"omh.native.brand.logo"] waitForExistenceWithTimeout:10], @"Brand logo must survive iPhone rotation");
    [self attachScreenshot:@"ios-phone-landscape-native-dashboard"];

    // OpenCode, Providers and Refresh live under the Settings gear.
    [self openEditorFromSettings];
    XCTAssertTrue([self.app.otherElements[@"omh.controlbar"] waitForExistenceWithTimeout:30],
                  @"iOS editor must open inside native OMH navigation");
    [self attachScreenshot:@"ios-phone-open-code-editor"];
}

/// The secondary dashboard controls (Providers, OpenCode, Refresh) live
/// under the Settings gear, not as separate navigation-bar buttons, so the
/// header brand never competes with them for width on a compact iPhone.
- (void)testDashboardSettingsMenuListsSecondaryControls {
    [self openSettingsMenu];
    [self attachScreenshot:@"ios-settings-menu"];
    // Dismiss the menu without navigating away.
    [self dismissSettingsMenu];
}

- (void)testHarnessBootsAndShowsWebUI {
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    // Native UIKit shell must remain visible while the guest WebKit app loads.
    // This is deliberately separate from the embedded dashboard DOM.
    XCUIElement *nativeSettings = self.app.buttons[@"omh.native.settings"];
    XCTAssertTrue([nativeSettings waitForExistenceWithTimeout:15], @"Native dashboard settings belong in the iPad toolbar");
    XCTAssertTrue(self.app.images[@"omh.native.brand.logo"].exists, @"Use the official OMH brand in UIKit");
    XCTAssertGreaterThanOrEqual(CGRectGetHeight(nativeSettings.frame), 40.0, @"Settings gear must have an accessible tap target");
    XCUIElement *home = self.app.webViews.firstMatch;
    XCUIElement *refresh = home.buttons[@"Refresh runtime state"];
    XCTAssertTrue([refresh waitForExistenceWithTimeout:kBootTimeout], @"iPad must open the shared OMH dashboard");
    XCUIElement *connected = [[home descendantsMatchingType:XCUIElementTypeAny]
        matchingPredicate:[NSPredicate predicateWithFormat:@"label == 'Connected'"]].firstMatch;
    XCTAssertTrue([connected waitForExistenceWithTimeout:30], @"Dashboard must read guest runtime state");
    [refresh tap];
    [self attachScreenshot:@"01-ipad-harness-dashboard"];
    // WebKit exposes buttons with aria-pressed as switches to iPad accessibility.
    XCUIElement *rail = home.otherElements[@"Workspace navigation, navigation"];
    NSArray<NSString *> *views = @[@"Agent teams", @"Workflows", @"Tasks", @"Skills",
        @"Plugins", @"Trace", @"Sandbox", @"Schedules", @"Workspaces", @"Memory"];
    for (NSString *name in views) {
        XCUIElement *item = rail.switches[name];
        [item tap];
        XCTAssertEqualObjects(item.value, @"1", @"%@ should be selected", name);
    }
    XCUIElement *empty = [[home descendantsMatchingType:XCUIElementTypeAny]
        matchingPredicate:[NSPredicate predicateWithFormat:@"label == 'No records match this view.'"]].firstMatch;
    XCTAssertTrue([empty waitForExistenceWithTimeout:8]);
    [rail.switches[@"Workspace"] tap];
    XCUIElement *tiles = home.otherElements[@"Explore harness features, navigation"];
    NSArray<XCUIElement *> *cards = tiles.switches.allElementsBoundByIndex;
    XCTAssertEqual(cards.count, 8u);
    for (XCUIElement *card in cards) {
        [card tap];
        XCTAssertFalse(tiles.exists);
        [rail.switches[@"Workspace"] tap];
        XCTAssertTrue(tiles.exists);
    }
    XCUIElement *quick = home.otherElements[@"Quick views, navigation"];
    for (NSString *name in @[@"Agent team", @"Queue", @"Overview"]) {
        [quick.switches[name] tap];
        XCTAssertEqualObjects(quick.switches[name].value, @"1");
    }
    for (NSString *name in @[@"Workspaces", @"Schedules", @"Logs", @"Console"]) {
        [home.buttons[name] tap];
        XCTAssertTrue(home.otherElements[[name stringByAppendingString:@", tab panel"]].exists);
    }
    [home.buttons[@"Run search"] tap];
    XCTAssertTrue(home.buttons[@"Clear"].exists);
    [home.buttons[@"Clear"] tap];
    XCTAssertFalse(home.buttons[@"Clear"].exists);
    // Tapping Run search focuses the search input and opens the software
    // keyboard, which scrolls the web view and pushes the topbar (with the
    // Refresh button) out of the visible viewport. Dismiss the keyboard so
    // the topbar is back in view before rotating and checking it.
    XCUIElement *hideKeyboard = self.app.keyboards.buttons[@"Hide keyboard"];
    if (hideKeyboard.exists) [hideKeyboard tap];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    XCTAssertTrue([nativeSettings waitForExistenceWithTimeout:8], @"Native toolbar should survive rotation");
    // OpenCode lives under the Settings gear; verify it is still reachable after rotation.
    [self openSettingsMenu];
    XCTAssertTrue(self.app.buttons[@"OpenCode"].hittable, @"OpenCode native control should survive rotation");
    [self dismissSettingsMenu];
    // The web refresh button is disabled while a state load is in flight
    // (dashboard.js sets disabled=true during /api/state, up to 10s), and
    // a disabled button is not hittable. Wait for it instead of asserting
    // immediately after rotation, when a load may still be running.
    NSPredicate *webRefreshHittable = [NSPredicate predicateWithFormat:@"hittable == YES"];
    [self waitForExpectations:@[[self expectationForPredicate:webRefreshHittable evaluatedWithObject:refresh handler:nil]] timeout:15];
    [self attachScreenshot:@"02-ipad-dashboard-portrait"];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    [self waitForHarnessReady];
    [self attachScreenshot:@"02-ready"];

    XCUIElement *web = self.app.webViews.firstMatch;
    XCTAssertTrue([web waitForExistenceWithTimeout:30], @"web view should exist");

    // Wait for the local web client to render an interactive control.
    NSPredicate *uiUp = [NSPredicate predicateWithFormat:@"exists == YES"];
    XCUIElementQuery *markers = [[web descendantsMatchingType:XCUIElementTypeAny]
        matchingPredicate:[NSPredicate predicateWithFormat:@"elementType == %d OR elementType == %d OR elementType == %d", XCUIElementTypeButton, XCUIElementTypeLink, XCUIElementTypeTextField]];
    XCTestExpectation *e = [self expectationForPredicate:uiUp evaluatedWithObject:markers.firstMatch handler:nil];
    [self waitForExpectations:@[e] timeout:90];
    [self attachScreenshot:@"03-web-ui"];

    XCUIElement *workspace = self.app.buttons[@"omh.sidebar.workspace"];
    XCTAssertTrue([workspace waitForExistenceWithTimeout:8], @"iPad landscape should show desktop navigation");
    XCUIElement *log = self.app.buttons[@"omh.sidebar.log"];
    [log tap];
    XCUIElement *logView = self.app.textViews[@"omh.logview"];
    XCTAssertTrue([logView waitForExistenceWithTimeout:8]);
    NSString *startupLog = logView.value;
    XCTAssertTrue([startupLog containsString:@"server answered"]);
    XCTAssertFalse([startupLog containsString:@"ESPIPE: invalid seek"], @"The guest must recognize the output pipes");
    if (CGRectGetWidth(self.app.frame) >= 1040) {
        XCTAssertLessThanOrEqual(CGRectGetMaxX(web.frame), CGRectGetMinX(logView.frame) + 1);
    }
    [self attachScreenshot:@"04-ipad-workspace-and-log"];
    [self.app.buttons[@"Done"] tap];
    XCTAssertFalse(logView.exists);
    [self.app.buttons[@"omh.sidebar.activity"] tap];
    XCTAssertTrue([self.app.tables[@"omh.activity"] waitForExistenceWithTimeout:8]);
    [workspace tap];
    [self.app.buttons[@"omh.sidebar.capabilities"] tap];
    XCTAssertTrue([self.app.tables[@"omh.capabilities"] waitForExistenceWithTimeout:8]);
    [workspace tap];
    XCTAssertTrue(web.hittable);
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    XCTAssertTrue([self.app.buttons[@"omh.menu"] waitForExistenceWithTimeout:8]);
    [self attachScreenshot:@"05-ipad-portrait"];

    // Title shows the port the server listens on.
    XCUIElement *title = self.app.staticTexts[@"omh.title"];
    XCTAssertTrue(title.exists);
    XCTAssertTrue([title.label containsString:@":30"], @"title should show the port, got %@", title.label);
    [self.app.navigationBars.buttons.firstMatch tap];
    XCTAssertTrue([refresh waitForExistenceWithTimeout:10], @"Back must return to the running dashboard");
    XCTAssertTrue(connected.exists);

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

/// The dashboard is the app's home. Provider Connections lives in the
/// OpenCode editor's native menu, not in the dashboard navigation bar.
- (void)openEditorProviderMenu {
    XCUIElement *menu = self.app.buttons[@"omh.menu"];
    if (!menu.exists) {
        [self openEditorFromSettings];
    }
    XCTAssertTrue([menu waitForExistenceWithTimeout:30],
                  @"Provider menu belongs to the native OpenCode editor");
    [menu tap];
}

/// A saved provider credential must survive a harness restart: the key
/// lives in the iOS Keychain, is injected into the guest environment at
/// launch, and the dashboard must report the provider as configured
/// (not disconnected) after the restart. Uses a throwaway test key for
/// DeepSeek; no real credential is involved and the key is removed after.
- (void)testProviderCredentialSurvivesHarnessRestart {
    XCUIElement *home = self.app.webViews.firstMatch;
    XCTAssertTrue([home waitForExistenceWithTimeout:kBootTimeout], @"Dashboard must load before credential test");
    XCUIElement *connected = [[home descendantsMatchingType:XCUIElementTypeAny]
        matchingPredicate:[NSPredicate predicateWithFormat:@"label == 'Connected'"]].firstMatch;
    XCTAssertTrue([connected waitForExistenceWithTimeout:60], @"Dashboard must report Connected before credential test");

    // Pre-state: no provider may be configured. If a previous failed run
    // left a key in the simulator Keychain, fail here instead of passing
    // vacuously later.
    NSArray<XCUIElement *> *preConfigured = [[home descendantsMatchingType:XCUIElementTypeStaticText]
        matchingPredicate:[NSPredicate predicateWithFormat:@"label == 'configured'"]].allElementsBoundByIndex;
    XCTAssertEqual(preConfigured.count, 0, @"No provider should be configured before the test saves a key; a previous run may have left a key in the Keychain");

    [self openEditorProviderMenu];
    XCUIElement *connectors = self.app.buttons[@"Provider Connections"];
    XCTAssertTrue([connectors waitForExistenceWithTimeout:10], @"Provider Connections menu item must exist");
    [connectors tap];
    XCUIElement *deepseek = self.app.buttons[@"DeepSeek"];
    XCTAssertTrue([deepseek waitForExistenceWithTimeout:10], @"DeepSeek must be listed");
    [deepseek tap];
    XCUIElement *keyField = self.app.secureTextFields[@"Provider API key"];
    XCTAssertTrue([keyField waitForExistenceWithTimeout:10], @"API key field must exist");
    [keyField tap];
    [keyField typeText:@"omh-test-persistence-key"];
    XCUIElement *save = self.app.buttons[@"Save Key"];
    XCTAssertTrue([save waitForExistenceWithTimeout:10], @"Save Key must exist");
    [save tap];
    self.needsCleanup = YES;

    // Saving updates the Keychain and restarts both guest services.
    // Fully relaunching the app is a stronger persistence check: the
    // dashboard/editor processes are recreated and must read the key again.
    // This also avoids inspecting a hidden, stale dashboard while the
    // provider action is performed in the pushed OpenCode editor.
    [self.app terminate];
    [self.app launch];
    [self waitForDashboardLaunch];
    XCTAssertTrue([home waitForExistenceWithTimeout:kBootTimeout],
                  @"Dashboard must return after a cold app relaunch");
    XCTAssertTrue([connected waitForExistenceWithTimeout:kBootTimeout],
                  @"Dashboard must reconnect after guest services restart");

    // Only DeepSeek has a saved key, so exactly one provider must read configured.
    XCUIElement *configured = [[home descendantsMatchingType:XCUIElementTypeStaticText]
        matchingPredicate:[NSPredicate predicateWithFormat:@"label == 'configured'"]].firstMatch;
    XCTAssertTrue([configured waitForExistenceWithTimeout:60], @"Saved provider credential must survive a harness restart");
    NSArray<XCUIElement *> *allConfigured = [[home descendantsMatchingType:XCUIElementTypeStaticText]
        matchingPredicate:[NSPredicate predicateWithFormat:@"label == 'configured'"]].allElementsBoundByIndex;
    XCTAssertEqual(allConfigured.count, 1, @"Exactly one provider (DeepSeek) must read configured after the restart");
    [self attachScreenshot:@"07-credential-survives-restart"];

    // Clean up: remove the throwaway key so later runs start clean.
    [self removeTestCredential];
    self.needsCleanup = NO;
}

/// Removes the throwaway DeepSeek key via the provider UI and verifies the
/// dashboard reports no provider configured afterwards. Used by the
/// persistence test and by tearDown (best-effort) if the test fails.
- (void)removeTestCredential {
    XCUIElement *home = self.app.webViews.firstMatch;
    [self openEditorProviderMenu];
    XCUIElement *connectors = self.app.buttons[@"Provider Connections"];
    XCTAssertTrue([connectors waitForExistenceWithTimeout:10], @"Provider Connections must exist for cleanup");
    [connectors tap];
    XCUIElement *deepseek = self.app.buttons[@"DeepSeek"];
    XCTAssertTrue([deepseek waitForExistenceWithTimeout:10], @"DeepSeek must be listed for cleanup");
    [deepseek tap];
    XCUIElement *remove = self.app.buttons[@"Remove Key"];
    XCTAssertTrue([remove waitForExistenceWithTimeout:10], @"Remove Key must exist");
    [remove tap];
    // Verify removal against a new guest session, not a cached/hidden page.
    [self.app terminate];
    [self.app launch];
    [self waitForDashboardLaunch];
    XCTAssertTrue([home waitForExistenceWithTimeout:kBootTimeout],
                  @"Dashboard must return after cleanup relaunch");
    XCUIElement *connected = [[home descendantsMatchingType:XCUIElementTypeAny]
        matchingPredicate:[NSPredicate predicateWithFormat:@"label == 'Connected'"]].firstMatch;
    XCTAssertTrue([connected waitForExistenceWithTimeout:kBootTimeout],
                  @"Dashboard must reconnect after cleanup restart");
    NSArray<XCUIElement *> *remaining = [[home descendantsMatchingType:XCUIElementTypeStaticText]
        matchingPredicate:[NSPredicate predicateWithFormat:@"label == 'configured'"]].allElementsBoundByIndex;
    XCTAssertEqual(remaining.count, 0, @"No provider should remain configured after cleanup");
}

@end

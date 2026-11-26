//
//  OMHLaunchUITests.m
//  OMHUITests
//
//  End-to-end checks on a real device/simulator: the app boots the Linux
//  guest, opencode-serve comes up, the native Chat and Runtime views show
//  the harness state, and the native controls (terminal, log, menu) work.
//  There is no dashboard web view any more: the dashboard is native
//  UIKit driven by OMHApiClient. Only the OpenCode editor
//  (OMHRootViewController) still embeds a web view, and the tests that
//  touch it say so explicitly.
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
/// are present: Providers, Workspace and Refresh. Dismisses the menu by
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
    XCTAssertTrue([self.app.buttons[@"Workspace"] waitForExistenceWithTimeout:5], @"Settings must list Workspace");
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

/// Opens the Workspace editor (the OpenCode editor, renamed in the menu)
/// from the dashboard Settings menu, waiting until the runtime is ready
/// and the menu action is enabled.
- (void)openEditorFromSettings {
    [self openSettingsMenu];
    XCUIElement *open = self.app.buttons[@"Workspace"];
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
    // The dashboard is native now: the Chat tab is the home view, with a
    // provider selector and a composer — there is no dashboard web view.
    XCUIElement *chat = self.app.otherElements[@"omh.native.chat"];
    XCTAssertTrue([chat waitForExistenceWithTimeout:kBootTimeout], @"iPhone must show the native Chat view");
    XCTAssertTrue([self.app.buttons[@"omh.native.chat.provider"] waitForExistenceWithTimeout:10], @"Chat must offer a provider selector");
    XCTAssertTrue(self.app.textFields[@"omh.native.chat.composer"].exists, @"Chat must offer a composer");
    [self attachScreenshot:@"ios-phone-portrait-native-dashboard"];

    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    XCTAssertTrue([settings waitForExistenceWithTimeout:10], @"Native actions survive iPhone rotation");
    XCTAssertTrue([self.app.images[@"omh.native.brand.logo"] waitForExistenceWithTimeout:10], @"Brand logo must survive iPhone rotation");
    XCTAssertTrue([chat waitForExistenceWithTimeout:10], @"Native Chat view must survive iPhone rotation");
    [self attachScreenshot:@"ios-phone-landscape-native-dashboard"];

    // Workspace, Providers and Refresh live under the Settings gear.
    [self openEditorFromSettings];
    XCTAssertTrue([self.app.otherElements[@"omh.controlbar"] waitForExistenceWithTimeout:30],
                  @"iOS editor must open inside native OMH navigation");
    [self attachScreenshot:@"ios-phone-open-code-editor"];
}

/// The secondary dashboard controls (Providers, Workspace, Refresh) live
/// under the Settings gear, not as separate navigation-bar buttons, so the
/// header brand never competes with them for width on a compact iPhone.
- (void)testDashboardSettingsMenuListsSecondaryControls {
    [self openSettingsMenu];
    [self attachScreenshot:@"ios-settings-menu"];
    // Dismiss the menu without navigating away.
    [self dismissSettingsMenu];
}

- (void)testHarnessBootsAndShowsNativeUI {
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    // Native UIKit shell must remain visible while the guest boots.
    XCUIElement *nativeSettings = self.app.buttons[@"omh.native.settings"];
    XCTAssertTrue([nativeSettings waitForExistenceWithTimeout:15], @"Native dashboard settings belong in the iPad toolbar");
    XCTAssertTrue(self.app.images[@"omh.native.brand.logo"].exists, @"Use the official OMH brand in UIKit");
    XCTAssertGreaterThanOrEqual(CGRectGetHeight(nativeSettings.frame), 40.0, @"Settings gear must have an accessible tap target");
    // The native Chat view is the dashboard home; it appears once the
    // guest is ready.
    XCUIElement *chat = self.app.otherElements[@"omh.native.chat"];
    XCTAssertTrue([chat waitForExistenceWithTimeout:kBootTimeout], @"iPad must open the native Chat view");
    [self attachScreenshot:@"01-ipad-harness-dashboard"];
    // The Runtime view must load live state from GET /api/state: the
    // Status section's task counts only render once the fetch succeeds.
    [self openRuntimeView];
    [self waitForRuntimeState];
    XCUIElement *list = self.app.tables[@"omh.native.runtime.list"];
    XCUIElement *counts = [[list.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS 'Queued'"]] firstMatch];
    XCTAssertTrue([counts waitForExistenceWithTimeout:30], @"Runtime must read guest runtime state");
    // The Runtime view's own Refresh re-fetches state.
    XCUIElement *refresh = self.app.buttons[@"omh.native.runtime.refresh"];
    XCTAssertTrue([refresh waitForExistenceWithTimeout:10], @"Runtime must offer Refresh");
    [refresh tap];
    [self waitForRuntimeState];
    XCTAssertTrue([counts waitForExistenceWithTimeout:30], @"Runtime must still show state after Refresh");
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    XCTAssertTrue([nativeSettings waitForExistenceWithTimeout:8], @"Native toolbar should survive rotation");
    XCTAssertTrue([list waitForExistenceWithTimeout:8], @"Native Runtime view should survive rotation");
    // Workspace lives under the Settings gear; verify it is still reachable after rotation.
    [self openSettingsMenu];
    XCTAssertTrue(self.app.buttons[@"Workspace"].hittable, @"Workspace native control should survive rotation");
    [self dismissSettingsMenu];
    [self attachScreenshot:@"02-ipad-dashboard-portrait"];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    [self waitForHarnessReady];
    [self attachScreenshot:@"02-ready"];

    // The editor now opens on the native Workspace home (5ac5a29); the
    // web view stays hidden until the legacy editor is opened explicitly.
    XCUIElement *nativeWorkspace = self.app.otherElements[@"omh.workspace.native"];
    XCTAssertTrue([nativeWorkspace waitForExistenceWithTimeout:30], @"editor must open on the native Workspace home");
    XCUIElement *legacyEditor = self.app.buttons[@"omh.workspace.legacy-editor"];
    XCTAssertTrue([legacyEditor waitForExistenceWithTimeout:10], @"legacy session editor must be offered");
    [legacyEditor tap];

    // From here the test is in the OpenCode editor, which still embeds
    // its own web view (OMHRootViewController) — `web` below is that
    // editor web view, not a dashboard web view (there is none any more).
    XCUIElement *web = self.app.webViews.firstMatch;
    XCTAssertTrue([web waitForExistenceWithTimeout:30], @"editor web view should exist");

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
    // Tapping the sidebar Workspace button returns to the native Workspace
    // home and hides the legacy editor, so the editor geometry check only
    // applies while the web view is present.
    if (web.exists && CGRectGetWidth(self.app.frame) >= 1040) {
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
    // Back returns to the native dashboard, showing the Runtime view
    // this test left active — not a web page.
    XCTAssertTrue([self.app.tables[@"omh.native.runtime.list"] waitForExistenceWithTimeout:10], @"Back must return to the running dashboard");

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

- (void)testLandscapeKeepsNativeDashboardAndBar {
    // setUp already waited for the native dashboard; check the layout
    // itself, not the editor: the dashboard container must be wider than
    // tall in landscape and the Settings gear must stay reachable.
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    sleep(2);
    XCUIElement *dashboard = self.app.otherElements[@"omh.native.dashboard"];
    XCTAssertTrue([dashboard waitForExistenceWithTimeout:10]);
    CGRect frame = dashboard.frame;
    XCTAssertGreaterThan(frame.size.width, frame.size.height, @"native dashboard should be wider than tall in landscape (%@)", NSStringFromCGRect(frame));
    XCTAssertTrue(self.app.buttons[@"omh.native.settings"].isHittable, @"settings gear stays reachable in landscape");
    [self attachScreenshot:@"06-landscape"];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    sleep(1);
    XCTAssertTrue(self.app.otherElements[@"omh.native.dashboard"].exists);
    // The editor stays reachable after rotation too.
    [self openEditorFromSettings];
    XCTAssertTrue([self.app.buttons[@"omh.menu"] waitForExistenceWithTimeout:10], @"editor menu stays reachable after rotation");
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
    // Swipe the sheet down to dismiss; the editor web view is still there.
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

/// Shows the native Runtime view: the iPad sidebar row on iPad, the tab
/// bar button on iPhone. Waits until the runtime list exists.
- (void)openRuntimeView {
    XCUIElement *sidebarRuntime = self.app.tables[@"omh.native.sidebar"].cells[@"omh.native.sidebar.runtime"];
    if (sidebarRuntime.exists) {
        [sidebarRuntime tap];
    } else {
        XCUIElement *tabRuntime = self.app.tabBars.buttons[@"Runtime"];
        XCTAssertTrue([tabRuntime waitForExistenceWithTimeout:10], @"Runtime must be reachable from the tab bar");
        [tabRuntime tap];
    }
    XCUIElement *list = self.app.tables[@"omh.native.runtime.list"];
    XCTAssertTrue([list waitForExistenceWithTimeout:kBootTimeout], @"Runtime list must load");
}

/// Waits until the Runtime view has loaded live state (GET /api/state
/// answered): the "No data yet" placeholder row only renders while the
/// state is still nil.
- (void)waitForRuntimeState {
    XCUIElement *list = self.app.tables[@"omh.native.runtime.list"];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:60];
    while ([deadline timeIntervalSinceNow] > 0) {
        if (!list.staticTexts[@"No data yet"].exists) {
            return;
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    }
    XCTFail(@"Runtime state did not load");
}

/// Counts providers the native Runtime view reports as configured: the
/// provider rows carry "configured" in their detail text, and no other
/// Runtime row contains that word.
- (NSUInteger)configuredProviderCount {
    XCUIElement *list = self.app.tables[@"omh.native.runtime.list"];
    NSArray<XCUIElement *> *matches = [[list.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS 'configured'"]] allElementsBoundByIndex];
    return matches.count;
}

/// A saved provider credential must survive a harness restart: the key
/// lives in the iOS Keychain, is injected into the guest environment at
/// launch, and the native Runtime view must report the provider as
/// configured (not disconnected) after the restart. Uses a throwaway
/// test key for DeepSeek; no real credential is involved and the key is
/// removed after.
- (void)testProviderCredentialSurvivesHarnessRestart {
    [self openRuntimeView];
    [self waitForRuntimeState];

    // Pre-state: no provider may be configured. If a previous failed run
    // left a key in the simulator Keychain, fail here instead of passing
    // vacuously later.
    XCTAssertEqual([self configuredProviderCount], 0u, @"No provider should be configured before the test saves a key; a previous run may have left a key in the Keychain");

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
    [self openRuntimeView];
    [self waitForRuntimeState];

    // Only DeepSeek has a saved key, so exactly one provider must read configured.
    XCTAssertEqual([self configuredProviderCount], 1u, @"Exactly one provider (DeepSeek) must read configured after the restart");
    [self attachScreenshot:@"07-credential-survives-restart"];

    // Clean up: remove the throwaway key so later runs start clean.
    [self removeTestCredential];
    self.needsCleanup = NO;
}

/// Removes the throwaway DeepSeek key via the provider UI and verifies the
/// Runtime view reports no provider configured afterwards. Used by the
/// persistence test and by tearDown (best-effort) if the test fails.
- (void)removeTestCredential {
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
    [self openRuntimeView];
    [self waitForRuntimeState];
    XCTAssertEqual([self configuredProviderCount], 0u, @"No provider should remain configured after cleanup");
}

@end

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
        [self.app.buttons[@"Cancel"] tap];
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
    XCUIElement *chat = self.app.buttons[@"omh.native.chat.provider"];
    XCTAssertTrue([chat waitForExistenceWithTimeout:kBootTimeout], @"iPhone must show the native Chat view");
    XCTAssertTrue([self.app.buttons[@"omh.native.chat.provider"] waitForExistenceWithTimeout:10], @"Chat must offer a provider selector");
    XCTAssertTrue([[self.app descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:@"omh.native.chat.composer"].firstMatch.exists, @"Chat must offer a composer");
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
    for (NSNumber *orientation in @[@(UIDeviceOrientationLandscapeLeft), @(UIDeviceOrientationPortrait)]) {
        XCUIDevice.sharedDevice.orientation = orientation.integerValue;
        XCUIElement *settings = self.app.buttons[@"omh.native.settings"];
        XCTAssertTrue([settings waitForExistenceWithTimeout:15]);
        XCTAssertTrue([self.app.buttons[@"omh.native.chat.provider"] waitForExistenceWithTimeout:10]);
        XCUIElement *composer = [[self.app descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:@"omh.native.chat.composer"].firstMatch;
        XCTAssertTrue([composer waitForExistenceWithTimeout:10]);
        XCTAssertFalse(self.app.webViews.firstMatch.exists, @"SwiftUI dashboard must not use a WebView");
        [self attachScreenshot:[NSString stringWithFormat:@"swiftui-dashboard-%@", orientation]];
        XCUIElement *collapse = self.app.buttons[@"omh.sidebar.collapse"];
        if (collapse.exists) {
            [collapse tap];
            [self attachScreenshot:[NSString stringWithFormat:@"swiftui-sidebar-collapsed-%@", orientation]];
            XCUIElement *expand = self.app.buttons[@"omh.sidebar.expand"];
            XCTAssertTrue([expand waitForExistenceWithTimeout:10]);
            [expand tap];
            [self.app.buttons[@"Expand sidebar"] tap];
            XCTAssertTrue([collapse waitForExistenceWithTimeout:10]);
        }
        [composer tap];
        [composer typeText:@"Simulator composer check"];
        XCTAssertTrue([((NSString *)composer.value) containsString:@"Simulator composer check"]);
        [self attachScreenshot:[NSString stringWithFormat:@"swiftui-composer-%@", orientation]];
        [self.app terminate];
        [self.app launch];
        [self waitForDashboardLaunch];
    }
    [self openSettingsMenu];
    [self attachScreenshot:@"swiftui-settings"];
    [self.app.buttons[@"Providers"] tap];
    XCTAssertTrue([self.app.buttons[@"DeepSeek"] waitForExistenceWithTimeout:10]);
    [self attachScreenshot:@"swiftui-providers"];
    [self.app.buttons[@"Not now"] tap];
    [self openRuntimeView];
    [self waitForRuntimeState];
    XCUIElement *list = self.app.tables[@"omh.native.runtime.list"];
    XCTAssertTrue([[list.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS 'Queued'"]].firstMatch waitForExistenceWithTimeout:30]);
    [self attachScreenshot:@"swiftui-runtime"];
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
        if (self.app.tables[@"omh.native.runtime.list"].exists) [self.app.navigationBars.buttons.firstMatch tap];
        [self openEditorFromSettings];
    }
    XCTAssertTrue([menu waitForExistenceWithTimeout:30],
                  @"Provider menu belongs to the native OpenCode editor");
    [menu tap];
}

/// Shows the native Runtime view: the iPad sidebar row on iPad, the tab
/// bar button on iPhone. Waits until the runtime list exists.
- (void)openRuntimeView {
    XCUIElement *sidebarRuntime = self.app.buttons[@"omh.native.sidebar.runtime"];
    if (sidebarRuntime.exists) {
        [sidebarRuntime tap];
    } else {
        [self openSettingsMenu];
        [self.app.buttons[@"Runtime"] tap];
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

- (void)testCustomProviderConfigurationAppearsInSelector {
    // Open the provider menu and the custom provider config sheet.
    XCUIElement *providerMenu = self.app.buttons[@"omh.native.chat.provider"];
    XCTAssertTrue([providerMenu waitForExistenceWithTimeout:10], @"Provider menu must exist");
    [providerMenu tap];
    XCUIElement *configure = self.app.buttons[@"omh.custom.configure"];
    XCTAssertTrue([configure waitForExistenceWithTimeout:10], @"Configure custom providers must exist in the provider menu");
    [configure tap];
    XCUIElement *sheet = [[self.app descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:@"omh.custom.providers"].firstMatch;
    XCTAssertTrue([sheet waitForExistenceWithTimeout:10], @"Custom provider config sheet must open");

    // Fill in Custom OpenAI config and save. The URL is a non-routable
    // test endpoint; the test verifies configuration and selection, not a
    // live provider round-trip.
    XCUIElement *urlField = self.app.textFields[@"omh.custom.openai.url"];
    XCTAssertTrue([urlField waitForExistenceWithTimeout:10], @"Custom OpenAI URL field must exist");
    [urlField tap];
    [urlField typeText:@"https://example.com/v1"];
    XCUIElement *keyField = self.app.secureTextFields[@"omh.custom.openai.key"];
    XCTAssertTrue([keyField waitForExistenceWithTimeout:10], @"Custom OpenAI key field must exist");
    [keyField tap];
    [keyField typeText:@"omh-test-custom-key"];
    XCUIElement *modelField = self.app.textFields[@"omh.custom.openai.model"];
    XCTAssertTrue([modelField waitForExistenceWithTimeout:10], @"Custom OpenAI model field must exist");
    [modelField tap];
    [modelField typeText:@"omh-test-model"];
    XCUIElement *save = self.app.buttons[@"omh.custom.openai.save"];
    XCTAssertTrue([save waitForExistenceWithTimeout:10], @"Save Custom OpenAI must exist");
    [save tap];
    XCTAssertTrue([self.app.staticTexts[@"Saved."] waitForExistenceWithTimeout:10], @"Save must report Saved.");
    [self attachScreenshot:@"custom-provider-configured"];

    // Dismiss the sheet, reopen the provider menu, and confirm the custom
    // provider is listed and selectable.
    XCUIElement *done = self.app.buttons[@"omh.custom.done"];
    XCTAssertTrue([done waitForExistenceWithTimeout:10], @"Done must exist to dismiss the config sheet");
    [done tap];
    [providerMenu tap];
    XCUIElement *customOpenAI = [self.app.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS 'Custom OpenAI'"]].firstMatch;
    XCTAssertTrue([customOpenAI waitForExistenceWithTimeout:10], @"Custom OpenAI must appear in the provider menu after configuration");
    [customOpenAI tap];

    // Selecting a configured custom provider enables the composer send
    // button once there is draft text, proving the provider is selected
    // and available. Do not send: the test endpoint is not a real provider.
    XCUIElement *composer = [[self.app descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:@"omh.native.chat.composer"].firstMatch;
    XCTAssertTrue([composer waitForExistenceWithTimeout:10], @"Composer must exist");
    [composer tap];
    [composer typeText:@"test"];
    XCUIElement *send = self.app.buttons[@"omh.native.chat.send"];
    XCTAssertTrue(send.enabled, @"Send must be enabled once a configured custom provider is selected and there is draft text");

    // Clean up: remove the throwaway custom provider so later runs start clean.
    [providerMenu tap];
    XCUIElement *configureAgain = self.app.buttons[@"omh.custom.configure"];
    XCTAssertTrue([configureAgain waitForExistenceWithTimeout:10], @"Configure custom providers must exist for cleanup");
    [configureAgain tap];
    XCTAssertTrue([sheet waitForExistenceWithTimeout:10], @"Custom provider config sheet must open for cleanup");
    XCUIElement *remove = self.app.buttons[@"omh.custom.openai.remove"];
    XCTAssertTrue([remove waitForExistenceWithTimeout:10], @"Remove Custom OpenAI must exist for cleanup");
    [remove tap];
    XCTAssertTrue([self.app.staticTexts[@"Removed."] waitForExistenceWithTimeout:10], @"Remove must report Removed.");
    XCUIElement *doneAgain = self.app.buttons[@"omh.custom.done"];
    [doneAgain tap];
}

/// Opens the custom provider config sheet from the provider menu.
- (void)openCustomProviderSheet {
    XCUIElement *providerMenu = self.app.buttons[@"omh.native.chat.provider"];
    XCTAssertTrue([providerMenu waitForExistenceWithTimeout:10], @"Provider menu must exist");
    // The SwiftUI Menu sometimes does not open on the first tap in the
    // simulator; retry until the Configure item appears.
    XCUIElement *configure = self.app.buttons[@"omh.custom.configure"];
    BOOL opened = NO;
    for (int attempt = 0; attempt < 3 && !opened; attempt++) {
        [providerMenu tap];
        opened = [configure waitForExistenceWithTimeout:5];
    }
    XCTAssertTrue(opened, @"Configure custom providers must exist in the provider menu");
    [configure tap];
    XCUIElement *sheet = [[self.app descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:@"omh.custom.providers"].firstMatch;
    XCTAssertTrue([sheet waitForExistenceWithTimeout:10], @"Custom provider config sheet must open");
}

/// Fills in one custom provider's URL, key and model and saves it.
/// `suffix` is @"openai" or @"anthropic". Assumes the config sheet is open.
- (void)configureCustomProviderSuffix:(NSString *)suffix baseURL:(NSString *)url key:(NSString *)key model:(NSString *)model {
    XCUIElement *urlField = self.app.textFields[[NSString stringWithFormat:@"omh.custom.%@.url", suffix]];
    XCTAssertTrue([urlField waitForExistenceWithTimeout:10], @"Custom %@ URL field must exist", suffix);
    [urlField tap];
    [urlField typeText:url];
    XCUIElement *keyField = self.app.secureTextFields[[NSString stringWithFormat:@"omh.custom.%@.key", suffix]];
    XCTAssertTrue([keyField waitForExistenceWithTimeout:10], @"Custom %@ key field must exist", suffix);
    [keyField tap];
    [keyField typeText:key];
    XCUIElement *modelField = self.app.textFields[[NSString stringWithFormat:@"omh.custom.%@.model", suffix]];
    XCTAssertTrue([modelField waitForExistenceWithTimeout:10], @"Custom %@ model field must exist", suffix);
    [modelField tap];
    [modelField typeText:model];
    XCUIElement *save = self.app.buttons[[NSString stringWithFormat:@"omh.custom.%@.save", suffix]];
    // The sheet holds both providers' sections, so the lower Save button
    // can sit below the fold and not exist in the accessibility hierarchy
    // until the sheet is scrolled. Swipe up to reveal it, then retry.
    BOOL saveFound = [save waitForExistenceWithTimeout:5];
    if (!saveFound) {
        XCUIElement *sheet = [[self.app descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:@"omh.custom.providers"].firstMatch;
        if (sheet.exists) {
            [sheet swipeUp];
        }
        saveFound = [save waitForExistenceWithTimeout:10];
    }
    XCTAssertTrue(saveFound, @"Save Custom %@ must exist", suffix);
    [save tap];
    XCTAssertTrue([self.app.staticTexts[@"Saved."] waitForExistenceWithTimeout:10], @"Save must report Saved.");
}

/// Sends `text` in the composer and waits for an assistant reply containing
/// `expectedReply`. The reply comes from the mock custom-provider server.
- (void)sendMessageExpectingReply:(NSString *)text expectedReply:(NSString *)expectedReply {
    XCUIElement *composer = [[self.app descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:@"omh.native.chat.composer"].firstMatch;
    XCTAssertTrue([composer waitForExistenceWithTimeout:10], @"Composer must exist");
    [composer tap];
    [composer typeText:text];
    XCUIElement *send = self.app.buttons[@"omh.native.chat.send"];
    XCTAssertTrue(send.enabled, @"Send must be enabled once a configured custom provider is selected and there is draft text");
    [send tap];
    // Hoist the boolean out of the XCTAssert macro: the comma inside
    // predicateWithFormat:@"label CONTAINS %@", expectedReply would split
    // the macro's arguments and break compilation.
    BOOL replyAppeared = [[self.app.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS %@", expectedReply]].firstMatch waitForExistenceWithTimeout:30];
    XCTAssertTrue(replyAppeared, @"Assistant reply '%@' must appear", expectedReply);
}

- (void)testCustomProviderPersistenceAcrossRestart {
    // The mock custom-provider server (tests/mock-custom-provider-server.py)
    // is started by the CI workflow on 127.0.0.1:18080. The simulator
    // shares the Mac's network, so the app reaches it at that address.
    // All keys here are throwaway test values, never real credentials.
    NSString *mockOpenAIURL = @"http://127.0.0.1:18080/v1";
    NSString *mockAnthropicURL = @"http://127.0.0.1:18080";
    NSString *mockKey = @"omh-test-mock-key";
    NSString *mockOpenAIModel = @"mock-openai-model";
    NSString *mockAnthropicModel = @"mock-anthropic-model";

    [self openCustomProviderSheet];

    // Redirect protection: a base URL whose models endpoint returns a 302
    // must NOT verify. The app blocks redirects, so the 302 is the
    // response and verification reports failure, not success.
    [self configureCustomProviderSuffix:@"openai" baseURL:@"http://127.0.0.1:18080/redirect" key:mockKey model:mockOpenAIModel];
    XCUIElement *verifyOpenAI = self.app.buttons[@"omh.custom.openai.verify"];
    XCTAssertTrue([verifyOpenAI waitForExistenceWithTimeout:10], @"Verify Custom OpenAI must exist");
    [verifyOpenAI tap];
    XCTAssertTrue([self.app.staticTexts[@"Provider verification failed"] waitForExistenceWithTimeout:15],
                  @"A redirecting endpoint must not verify: redirect protection must remain intact");
    // Clear the redirect probe config before configuring the real mock URL.
    XCUIElement *removeOpenAI = self.app.buttons[@"omh.custom.openai.remove"];
    XCTAssertTrue([removeOpenAI waitForExistenceWithTimeout:10], @"Remove Custom OpenAI must exist");
    [removeOpenAI tap];
    XCTAssertTrue([self.app.staticTexts[@"Removed."] waitForExistenceWithTimeout:10], @"Remove must report Removed.");

    // Configure both custom providers independently against the mock server.
    [self configureCustomProviderSuffix:@"openai" baseURL:mockOpenAIURL key:mockKey model:mockOpenAIModel];
    [self configureCustomProviderSuffix:@"anthropic" baseURL:mockAnthropicURL key:mockKey model:mockAnthropicModel];
    [self attachScreenshot:@"custom-providers-configured"];
    XCUIElement *done = self.app.buttons[@"omh.custom.done"];
    XCTAssertTrue([done waitForExistenceWithTimeout:10], @"Done must exist to dismiss the config sheet");
    [done tap];

    // Both providers must appear in the menu. Select Custom OpenAI so the
    // selected provider can be checked after the restart.
    XCUIElement *providerMenu = self.app.buttons[@"omh.native.chat.provider"];
    [providerMenu tap];
    XCUIElement *customOpenAI = [self.app.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS 'Custom OpenAI'"]].firstMatch;
    XCTAssertTrue([customOpenAI waitForExistenceWithTimeout:10], @"Custom OpenAI must appear in the provider menu after configuration");
    XCUIElement *customAnthropic = [self.app.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS 'Custom Anthropic'"]].firstMatch;
    XCTAssertTrue([customAnthropic waitForExistenceWithTimeout:10], @"Custom Anthropic must appear in the provider menu after configuration");
    [customOpenAI tap];

    // Complete app termination and relaunch. This is a stronger check than
    // backgrounding: the app process is recreated and must re-read the
    // persisted config (UserDefaults for URL/model, Keychain for the key).
    [self.app terminate];
    [self.app launch];
    [self waitForDashboardLaunch];

    // Both providers must still be listed after the restart, proving the
    // endpoint URLs and model IDs survived.
    [providerMenu tap];
    XCUIElement *customOpenAIAfter = [self.app.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS 'Custom OpenAI'"]].firstMatch;
    XCTAssertTrue([customOpenAIAfter waitForExistenceWithTimeout:10], @"Custom OpenAI must still be listed after relaunch");
    XCUIElement *customAnthropicAfter = [self.app.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS 'Custom Anthropic'"]].firstMatch;
    XCTAssertTrue([customAnthropicAfter waitForExistenceWithTimeout:10], @"Custom Anthropic must still be listed after relaunch");
    // Dismiss the menu without changing the selection.
    [providerMenu tap];

    // The config sheet must still show the persisted URLs and models, and
    // the key fields must report a saved key (recovered from the Keychain).
    [self openCustomProviderSheet];
    XCUIElement *openAIURLField = self.app.textFields[@"omh.custom.openai.url"];
    XCTAssertTrue([openAIURLField waitForExistenceWithTimeout:10], @"Custom OpenAI URL field must exist after relaunch");
    XCTAssertTrue([((NSString *)openAIURLField.value) containsString:@"127.0.0.1:18080/v1"], @"Custom OpenAI URL must survive relaunch");
    XCUIElement *openAIModelField = self.app.textFields[@"omh.custom.openai.model"];
    XCTAssertEqualObjects((NSString *)openAIModelField.value, mockOpenAIModel, @"Custom OpenAI model must survive relaunch");
    XCUIElement *openAIKeyField = self.app.secureTextFields[@"omh.custom.openai.key"];
    XCTAssertEqualObjects(openAIKeyField.placeholderValue, @"API key (saved)", @"Custom OpenAI key must be recovered from the Keychain after relaunch");
    XCUIElement *anthropicURLField = self.app.textFields[@"omh.custom.anthropic.url"];
    XCTAssertTrue([((NSString *)anthropicURLField.value) containsString:@"127.0.0.1:18080"], @"Custom Anthropic URL must survive relaunch");
    XCUIElement *anthropicModelField = self.app.textFields[@"omh.custom.anthropic.model"];
    XCTAssertEqualObjects((NSString *)anthropicModelField.value, mockAnthropicModel, @"Custom Anthropic model must survive relaunch");
    XCUIElement *anthropicKeyField = self.app.secureTextFields[@"omh.custom.anthropic.key"];
    XCTAssertEqualObjects(anthropicKeyField.placeholderValue, @"API key (saved)", @"Custom Anthropic key must be recovered from the Keychain after relaunch");
    XCUIElement *doneAgain2 = self.app.buttons[@"omh.custom.done"];
    [doneAgain2 tap];

    // The selected provider (Custom OpenAI) must have survived the
    // relaunch, and its protocol must route after restarting: sending
    // without re-selecting must reach the mock OpenAI endpoint.
    [self sendMessageExpectingReply:@"Hello mock OpenAI" expectedReply:@"mock openai reply"];
    [self attachScreenshot:@"custom-openai-reply-after-restart"];

    // Switch to Custom Anthropic and verify its protocol routes after
    // restarting too.
    [providerMenu tap];
    XCUIElement *anthropicMenuItem = [self.app.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS 'Custom Anthropic'"]].firstMatch;
    XCTAssertTrue([anthropicMenuItem waitForExistenceWithTimeout:10], @"Custom Anthropic must be selectable after relaunch");
    [anthropicMenuItem tap];
    [self sendMessageExpectingReply:@"Hello mock Anthropic" expectedReply:@"mock anthropic reply"];
    [self attachScreenshot:@"custom-anthropic-reply-after-restart"];

    // Removing one custom provider must not affect the other.
    [self openCustomProviderSheet];
    XCUIElement *removeOpenAIAgain = self.app.buttons[@"omh.custom.openai.remove"];
    XCTAssertTrue([removeOpenAIAgain waitForExistenceWithTimeout:10], @"Remove Custom OpenAI must exist");
    [removeOpenAIAgain tap];
    XCTAssertTrue([self.app.staticTexts[@"Removed."] waitForExistenceWithTimeout:10], @"Remove must report Removed.");
    XCUIElement *doneAfterRemove = self.app.buttons[@"omh.custom.done"];
    [doneAfterRemove tap];
    [providerMenu tap];
    XCUIElement *anthropicStillThere = [self.app.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS 'Custom Anthropic'"]].firstMatch;
    XCTAssertTrue([anthropicStillThere waitForExistenceWithTimeout:10], @"Custom Anthropic must remain after Custom OpenAI is removed");
    // The provider Menu lists every provider and only disables the
    // unavailable ones, so a removed provider stays visible as a disabled
    // entry labelled "<label> — Not configured". Assert exactly that:
    // present, disabled, and showing "Not configured" — not absent.
    XCUIElement *openAIDisabled = [self.app.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS 'Custom OpenAI'"]].firstMatch;
    XCTAssertTrue([openAIDisabled waitForExistenceWithTimeout:10], @"Custom OpenAI must remain in the menu as a disabled entry after removal");
    XCTAssertTrue([openAIDisabled.label isEqualToString:@"Custom OpenAI — Not configured"], @"Removed provider must display 'Custom OpenAI — Not configured'");
    XCTAssertFalse(openAIDisabled.isEnabled, @"Removed provider must be disabled in the menu so it cannot be selected for requests");
    [anthropicStillThere tap];

    // Credential security: removal must clear the saved Keychain credential
    // (and the stored URL/model) for the removed provider only. Reopen the
    // config sheet and verify the removed provider's fields are empty and
    // its key is no longer saved, while the other provider stays saved.
    [self openCustomProviderSheet];
    XCUIElement *openAIURLAfterRemove = self.app.textFields[@"omh.custom.openai.url"];
    XCTAssertTrue([openAIURLAfterRemove waitForExistenceWithTimeout:10], @"OpenAI URL field must exist after removal");
    // XCTest .value on an empty SwiftUI TextField returns its placeholder,
    // not an empty string (verified from the 48308dc hierarchy artifact:
    // the empty composer's value reads "Message OpenMind H..."). Accept
    // empty or the placeholder "Base URL"; the mock URL must be gone.
    NSString *openAIURLValue = (NSString *)openAIURLAfterRemove.value;
    XCTAssertTrue(openAIURLValue.length == 0 || [openAIURLValue isEqualToString:@"Base URL"], @"Removed provider URL must be cleared");
    XCTAssertFalse([openAIURLValue containsString:@"127.0.0.1"], @"Removed provider URL must not still be the mock URL");
    XCUIElement *openAIModelAfterRemove = self.app.textFields[@"omh.custom.openai.model"];
    XCTAssertTrue([openAIModelAfterRemove waitForExistenceWithTimeout:10], @"OpenAI model field must exist after removal");
    NSString *openAIModelValue = (NSString *)openAIModelAfterRemove.value;
    XCTAssertTrue(openAIModelValue.length == 0 || [openAIModelValue isEqualToString:@"Model ID"], @"Removed provider model must be cleared");
    XCUIElement *openAIKeyAfterRemove = self.app.secureTextFields[@"omh.custom.openai.key"];
    XCTAssertTrue([openAIKeyAfterRemove waitForExistenceWithTimeout:10], @"OpenAI key field must exist after removal");
    XCTAssertTrue([openAIKeyAfterRemove.placeholderValue isEqualToString:@"API key"], @"Removed provider key must be cleared from Keychain (placeholder must be 'API key', not 'API key (saved)')");
    // The other provider must be untouched by the removal.
    XCUIElement *anthropicURLAfterRemove = self.app.textFields[@"omh.custom.anthropic.url"];
    BOOL anthropicURLFound = [anthropicURLAfterRemove waitForExistenceWithTimeout:5];
    if (!anthropicURLFound) {
        XCUIElement *sheet = [[self.app descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:@"omh.custom.providers"].firstMatch;
        if (sheet.exists) {
            [sheet swipeUp];
        }
        anthropicURLFound = [anthropicURLAfterRemove waitForExistenceWithTimeout:10];
    }
    XCTAssertTrue(anthropicURLFound, @"Custom Anthropic URL field must exist after removing Custom OpenAI");
    XCTAssertTrue([((NSString *)anthropicURLAfterRemove.value) isEqualToString:mockAnthropicURL], @"Removing Custom OpenAI must not clear Custom Anthropic's URL");
    XCUIElement *anthropicKeyAfterRemove = self.app.secureTextFields[@"omh.custom.anthropic.key"];
    XCTAssertTrue([anthropicKeyAfterRemove waitForExistenceWithTimeout:10], @"Custom Anthropic key field must exist after removing Custom OpenAI");
    XCTAssertTrue([anthropicKeyAfterRemove.placeholderValue isEqualToString:@"API key (saved)"], @"Removing Custom OpenAI must not clear Custom Anthropic's saved key");
    XCUIElement *doneAfterVerify = self.app.buttons[@"omh.custom.done"];
    [doneAfterVerify tap];

    // Clean up: remove the remaining custom provider so later runs start clean.
    [self openCustomProviderSheet];
    XCUIElement *removeAnthropic = self.app.buttons[@"omh.custom.anthropic.remove"];
    XCTAssertTrue([removeAnthropic waitForExistenceWithTimeout:10], @"Remove Custom Anthropic must exist for cleanup");
    [removeAnthropic tap];
    XCTAssertTrue([self.app.staticTexts[@"Removed."] waitForExistenceWithTimeout:10], @"Remove must report Removed.");
    XCUIElement *doneCleanup = self.app.buttons[@"omh.custom.done"];
    [doneCleanup tap];
}

@end

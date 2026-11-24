//
//  OMHSceneDelegate.m
//  OMH
//

#import "OMHSceneDelegate.h"
#import "OMHRootViewController.h"
#import "OMHHarness.h"
#import "OMHBootCoordinator.h"
#import "OMHProviderCredentials.h"
#import <WebKit/WebKit.h>
#import "AppDelegate.h"
#import "AboutViewController.h"

// The iPad home is the same loopback dashboard that the standalone harness serves.
@interface OMHDashboardViewController : UIViewController <WKNavigationDelegate>
@property (nonatomic) WKWebView *dashboard;
@property (nonatomic) UIStackView *notice;
@property (nonatomic) UILabel *message;
@property (nonatomic) UIButton *retry;
@property (nonatomic) WKNavigation *navigation;
@property (nonatomic) NSURL *requestedURL;
@property (nonatomic) OMHRootViewController *editor;
@property (nonatomic) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic) UIView *headerView;
@property (nonatomic) UIAction *providersAction;
@property (nonatomic) UIAction *editorAction;
@property (nonatomic) UIAction *refreshAction;
@property (nonatomic) UIButton *settingsButton;
@property (nonatomic) UILabel *nativeTitle;
@end

@implementation OMHDashboardViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Dashboard";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor colorWithRed:0.035 green:0.027 blue:0.047 alpha:1];

    // Dedicated responsive header: the brand lives in its own row above the
    // WebView, not in the navigation bar, so it never competes with toolbar
    // actions for width on a compact iPhone. (PR #8 iPhone failure:
    // omh.native.brand.logo never appeared in the navigation titleView in
    // portrait; the hierarchy showed the titleView entirely absent.)
    // The logo keeps its accessibility identity and behavior.
    self.headerView = [UIView new];
    self.headerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerView.accessibilityIdentifier = @"omh.native.brand";
    UIImageView *brand = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"OMHBrandMark"]];
    brand.translatesAutoresizingMaskIntoConstraints = NO;
    brand.contentMode = UIViewContentModeScaleAspectFit;
    brand.isAccessibilityElement = YES;
    brand.accessibilityLabel = @"OpenMind Harness logo";
    brand.accessibilityIdentifier = @"omh.native.brand.logo";
    [NSLayoutConstraint activateConstraints:@[
        [brand.widthAnchor constraintEqualToConstant:30],
        [brand.heightAnchor constraintEqualToConstant:30]
    ]];
    UILabel *brandTitle = [UILabel new];
    // Start narrow on compact widths; viewWillLayoutSubviews widens it
    // again on rotation/Stage Manager. The header is a normal view, so the
    // title is re-measured by Auto Layout instead of collapsing.
    brandTitle.text = self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact ? @"OMH" : @"OpenMind Harness";
    self.nativeTitle = brandTitle;
    brandTitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    brandTitle.adjustsFontForContentSizeCategory = YES;
    brandTitle.textColor = [UIColor colorWithRed:0.75 green:0.42 blue:1 alpha:1];
    brandTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    UIStackView *identity = [[UIStackView alloc] initWithArrangedSubviews:@[brand, brandTitle]];
    identity.axis = UILayoutConstraintAxisHorizontal;
    identity.alignment = UIStackViewAlignmentCenter;
    identity.spacing = 10;
    identity.translatesAutoresizingMaskIntoConstraints = NO;
    [self.headerView addSubview:identity];
    [self.view addSubview:self.headerView];

    // Secondary controls live under a single Settings gear, so the
    // navigation bar never crowds the brand out on a compact iPhone.
    // OpenCode, provider configuration and refresh all stay reachable
    // from this menu; only their presentation changes.
    // The gear lives in the header row, not the navigation bar: a bar
    // button item's custom view is capped at 36pt by the nav bar, below
    // the 44pt accessible tap target the UI tests assert, and no explicit
    // size constraint overrides it (CI run 45474077170 measured 36 on
    // both simulators). The 52pt header gives the 44x44 button room.
    __weak typeof(self) weakSelf = self;
    self.providersAction = [UIAction actionWithTitle:@"Providers" image:nil identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf configureProvider];
    }];
    self.editorAction = [UIAction actionWithTitle:@"OpenCode" image:nil identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf openEditor];
    }];
    self.refreshAction = [UIAction actionWithTitle:@"Refresh dashboard" image:nil identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf retryDashboard];
    }];
    UIMenu *settingsMenu = [UIMenu menuWithTitle:@"" children:@[self.providersAction, self.editorAction, self.refreshAction]];
    UIButton *settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [settingsButton setImage:[UIImage systemImageNamed:@"gearshape"] forState:UIControlStateNormal];
    settingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [settingsButton.widthAnchor constraintEqualToConstant:44],
        [settingsButton.heightAnchor constraintEqualToConstant:44]
    ]];
    settingsButton.accessibilityIdentifier = @"omh.native.settings";
    settingsButton.accessibilityLabel = @"Settings";
    settingsButton.menu = settingsMenu;
    settingsButton.showsMenuAsPrimaryAction = YES;
    self.settingsButton = settingsButton;
    [self.headerView addSubview:settingsButton];

    self.loadingIndicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.loadingIndicator.color = [UIColor colorWithRed:0.75 green:0.42 blue:1 alpha:1];
    // The dashboard is the navigation root. Never reserve a blank circular
    // leading control when there is no view to go back to. Startup progress
    // is already presented by the dedicated full-screen launch gate.
    self.navigationItem.leftBarButtonItem = nil;

    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    // WebKit stays embedded, but adapts like an iPad app in Stage Manager:
    // the actual available width drives the page, not the physical screen.
    config.defaultWebpagePreferences.preferredContentMode = WKContentModeRecommended;
    config.defaultWebpagePreferences.allowsContentJavaScript = YES;
    self.dashboard = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    self.dashboard.navigationDelegate = self;
    self.dashboard.accessibilityIdentifier = @"omh.dashboard";
    self.dashboard.translatesAutoresizingMaskIntoConstraints = NO;
    self.dashboard.opaque = NO;
    self.dashboard.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:self.dashboard];

    self.message = [UILabel new];
    self.message.numberOfLines = 0;
    self.message.textAlignment = NSTextAlignmentCenter;
    self.message.textColor = UIColor.labelColor;
    self.retry = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *retryStyle = [UIButtonConfiguration tintedButtonConfiguration];
    retryStyle.title = @"Retry dashboard";
    retryStyle.image = [UIImage systemImageNamed:@"arrow.clockwise"];
    retryStyle.imagePadding = 8;
    retryStyle.baseForegroundColor = [UIColor colorWithRed:0.75 green:0.42 blue:1 alpha:1];
    retryStyle.contentInsets = NSDirectionalEdgeInsetsMake(12, 16, 12, 16);
    self.retry.configuration = retryStyle;
    self.retry.accessibilityIdentifier = @"omh.native.retry";
    [self.retry.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [self.retry addTarget:self action:@selector(retryDashboard) forControlEvents:UIControlEventTouchUpInside];
    self.notice = [[UIStackView alloc] initWithArrangedSubviews:@[self.message, self.retry]];
    self.notice.axis = UILayoutConstraintAxisVertical;
    self.notice.spacing = 12;
    self.notice.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.notice];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.headerView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.headerView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.headerView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.headerView.heightAnchor constraintEqualToConstant:52],
        [identity.centerXAnchor constraintEqualToAnchor:self.headerView.centerXAnchor],
        [identity.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [settingsButton.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-12],
        [settingsButton.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [self.dashboard.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],
        [self.dashboard.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [self.dashboard.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.dashboard.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.notice.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [self.notice.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [self.notice.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
    ]];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(stateChanged:) name:OMHBootStateDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(stateChanged:) name:OMHHarnessStateDidChangeNotification object:OMHHarness.dashboard];
    [self updateDashboard];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    // In compact iPhone and Stage Manager widths, show the short brand
    // name in the header. The header is a normal Auto Layout view, so
    // changing the label text re-measures it without any titleView
    // re-assignment (the old navigation-bar titleView collapsed instead
    // of shrinking on a narrow iPhone).
    CGFloat available = CGRectGetWidth(self.view.bounds);
    NSString *title = available < 620 ? @"OMH" : @"OpenMind Harness";
    if (![self.nativeTitle.text isEqualToString:title]) {
        self.nativeTitle.text = title;
    }
}

- (void)openEditor {
    if (!self.editor) self.editor = [OMHRootViewController new];
    if (OMHHarness.shared.state == OMHHarnessStateIdle) [OMHHarness.shared start];
    [self.navigationController pushViewController:self.editor animated:YES];
}

- (void)stateChanged:(NSNotification *)notification {
    [self updateDashboard];
}

- (void)showMessage:(NSString *)message retry:(BOOL)retry {
    self.dashboard.hidden = YES;
    self.notice.hidden = NO;
    [self.loadingIndicator startAnimating];
    self.message.text = message;
    self.retry.hidden = !retry;
    if (retry) [self.loadingIndicator stopAnimating];
}

- (void)updateDashboard {
    OMHBootCoordinator *boot = OMHBootCoordinator.shared;
    OMHHarness *server = OMHHarness.dashboard;
    // The Settings menu actions gate on the same readiness the old
    // toolbar buttons did; Providers stays available so a key can be
    // saved before the runtime is ready.
    UIMenuElementAttributes disabled = UIMenuElementAttributesDisabled;
    self.editorAction.attributes = boot.phase == OMHBootPhaseReady ? 0 : disabled;
    self.refreshAction.attributes = boot.phase == OMHBootPhaseReady ? 0 : disabled;
    if (boot.phase != OMHBootPhaseReady) {
        [self showMessage:boot.statusMessage retry:NO];
    } else if (server.state == OMHHarnessStateReady) {
        if (![server.baseURL isEqual:self.requestedURL]) {
            self.requestedURL = server.baseURL;
            [self showMessage:@"Opening dashboard…" retry:NO];
            self.navigation = [self.dashboard loadRequest:[NSURLRequest requestWithURL:server.baseURL]];
        }
    } else {
        self.requestedURL = nil;
        self.navigation = nil;
        BOOL failed = server.state == OMHHarnessStateFailed || server.state == OMHHarnessStateStopped;
        [self showMessage:failed ? (server.lastError ?: @"Dashboard stopped.") : @"Starting dashboard…" retry:failed];
    }
}

- (void)configureProvider {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Provider setup"
        message:@"Optional: save a provider API key securely on this device. Other sign-in methods remain available in OpenCode."
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSDictionary<NSString *,NSString *> *providers = @{
        @"OpenAI":@"openai", @"Anthropic":@"anthropic",
        @"Gemini":@"google", @"DeepSeek":@"deepseek",
        @"GLM / Z.AI":@"zai", @"Kimi / Moonshot":@"moonshotai",
        @"Qwen":@"qwen"
    };
    __weak typeof(self) weakSelf = self;
    for (NSString *name in @[@"OpenAI",@"Anthropic",@"Gemini",@"DeepSeek",@"GLM / Z.AI",@"Kimi / Moonshot",@"Qwen"]) {
        NSString *provider = providers[name];
        [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) { [weakSelf promptForKey:provider name:name]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Not now" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.settingsButton;
    sheet.popoverPresentationController.sourceRect = self.settingsButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)promptForKey:(NSString *)provider name:(NSString *)name {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:name
        message:@"API keys are stored in the iOS Keychain, never in the dashboard or startup logs."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Provider API key";
        field.secureTextEntry = YES;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save key" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *value = [alert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![OMHProviderCredentials saveToken:value provider:provider]) {
            UIAlertController *error = [UIAlertController alertControllerWithTitle:@"Key not saved"
                message:@"Enter a valid nonempty key and verify Keychain access."
                preferredStyle:UIAlertControllerStyleAlert];
            [error addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [weakSelf presentViewController:error animated:YES completion:nil];
            return;
        }
        // Only processes started after this point receive the updated
        // environment. Restart active services to apply the new credentials.
        if (OMHHarness.dashboard.state == OMHHarnessStateReady) [OMHHarness.dashboard restart];
        if (OMHHarness.shared.state == OMHHarnessStateReady) [OMHHarness.shared restart];
        [weakSelf updateDashboard];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)retryDashboard {
    if (OMHHarness.dashboard.state == OMHHarnessStateReady) {
        self.requestedURL = nil;
        [self updateDashboard];
    } else {
        [OMHHarness.dashboard restart];
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    NSURL *base = OMHHarness.dashboard.baseURL;
    BOOL local = [url.scheme isEqualToString:@"http"] && [url.host isEqualToString:base.host] && [url.port isEqual:base.port];
    decisionHandler(local ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (navigation != self.navigation) return;
    self.notice.hidden = YES;
    self.dashboard.hidden = NO;
    [self.loadingIndicator stopAnimating];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (navigation == self.navigation && error.code != NSURLErrorCancelled)
        [self showMessage:@"Could not load the dashboard." retry:YES];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self webView:webView didFailNavigation:navigation withError:error];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    self.requestedURL = nil;
    [self updateDashboard];
}
@end

// Full-screen native launch gate. The dashboard is not created until the
// guest has booted and its HTTP health check succeeds.
@interface OMHLaunchGateController : UIViewController
@property (nonatomic, copy) void (^onReady)(void);
@property (nonatomic) UILabel *stateLabel;
@property (nonatomic) UIProgressView *progressView;
@property (nonatomic) UITextView *diagnostics;
@property (nonatomic) UIButton *retryButton;
@property (nonatomic) UIButton *continueButton;
@property (nonatomic) BOOL showingFullLog;
@property (nonatomic) NSTimer *refreshTimer;
@property (nonatomic) BOOL transitioned;
@end

@implementation OMHLaunchGateController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.035 green:0.027 blue:0.047 alpha:1];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UIColor *openUIAccent = [UIColor colorWithRed:0.66 green:0.33 blue:0.97 alpha:1];
    UIImageView *mark = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"OMHBrandMark"]];
    mark.contentMode = UIViewContentModeScaleAspectFit;
    mark.isAccessibilityElement = NO;
    [mark.heightAnchor constraintEqualToConstant:48].active = YES;
    UILabel *brand = [UILabel new];
    brand.text = @"OpenMind Harness";
    brand.font = [UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];
    brand.adjustsFontForContentSizeCategory = YES;
    brand.textAlignment = NSTextAlignmentCenter;
    brand.textColor = UIColor.whiteColor;
    brand.numberOfLines = 0;
    brand.accessibilityIdentifier = @"omh.launch.brand";
    UILabel *sub = [UILabel new];
    sub.text = @"Preparing your local workspace";
    sub.textColor = UIColor.secondaryLabelColor;
    sub.textAlignment = NSTextAlignmentCenter;
    sub.numberOfLines = 0;
    sub.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    sub.adjustsFontForContentSizeCategory = YES;
    self.stateLabel = [UILabel new];
    self.stateLabel.text = @"Preparing Linux guest…";
    self.stateLabel.textAlignment = NSTextAlignmentCenter;
    self.stateLabel.numberOfLines = 0;
    self.stateLabel.textColor = UIColor.whiteColor;
    self.stateLabel.accessibilityIdentifier = @"omh.launch.status";
    self.progressView = [UIProgressView new];
    self.progressView.progressTintColor = openUIAccent;
    self.progressView.trackTintColor = UIColor.darkGrayColor;
    self.progressView.accessibilityIdentifier = @"omh.launch.progress";
    self.diagnostics = [UITextView new];
    self.diagnostics.backgroundColor = [UIColor colorWithRed:0.025 green:0.04 blue:0.03 alpha:1];
    self.diagnostics.textColor = [UIColor colorWithRed:0.86 green:1.0 blue:0.91 alpha:1];
    self.diagnostics.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.diagnostics.editable = NO;
    self.diagnostics.layer.cornerRadius = 12;
    self.diagnostics.layer.borderWidth = 2.0;
    self.diagnostics.layer.borderColor = [UIColor colorWithRed:0.25 green:1.0 blue:0.48 alpha:1].CGColor;
    self.diagnostics.textContainerInset = UIEdgeInsetsMake(16, 16, 16, 16);
    self.diagnostics.alwaysBounceVertical = YES;
    self.diagnostics.accessibilityIdentifier = @"omh.launch.logs";
    UIButton *logs = [UIButton buttonWithType:UIButtonTypeSystem];
    [logs setTitle:@"Full log" forState:UIControlStateNormal];
    logs.accessibilityIdentifier = @"omh.launch.full-log";
    [logs addTarget:self action:@selector(toggleLog:) forControlEvents:UIControlEventTouchUpInside];
    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.retryButton setTitle:@"Retry startup" forState:UIControlStateNormal];
    self.retryButton.accessibilityIdentifier = @"omh.launch.retry";
    [self.retryButton addTarget:self action:@selector(retryLaunch) forControlEvents:UIControlEventTouchUpInside];
    self.retryButton.hidden = YES;
    self.continueButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.continueButton setTitle:@"Open dashboard" forState:UIControlStateNormal];
    self.continueButton.accessibilityIdentifier = @"omh.launch.continue";
    [self.continueButton addTarget:self action:@selector(completeSetup) forControlEvents:UIControlEventTouchUpInside];
    self.continueButton.hidden = YES;
    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[logs,self.retryButton,self.continueButton]];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.alignment = UIStackViewAlignmentCenter;
    actions.distribution = UIStackViewDistributionEqualSpacing;
    actions.spacing = 15;
    for (UIButton *button in @[logs,self.retryButton,self.continueButton]) {
        UIButtonConfiguration *style = [UIButtonConfiguration tintedButtonConfiguration];
        style.title = [button titleForState:UIControlStateNormal];
        style.baseForegroundColor = openUIAccent;
        style.cornerStyle = UIButtonConfigurationCornerStyleMedium;
        button.configuration = style;
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    }
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        mark,brand,sub,self.stateLabel,self.progressView,actions,self.diagnostics]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 20;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [stack.centerXAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.centerXAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor multiplier:0.88],
        [self.diagnostics.heightAnchor constraintEqualToConstant:360]
    ]];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(updateGate)
             name:OMHBootStateDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(updateGate)
             name:OMHHarnessStateDidChangeNotification object:OMHHarness.dashboard];
    [nc addObserver:self selector:@selector(updateGate)
             name:OMHLogBufferDidChangeNotification object:nil];
    [self updateGate];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                             selector:@selector(updateGate) userInfo:nil repeats:YES];
    [self updateGate];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}
- (void)dealloc {
    [self.refreshTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)toggleLog:(UIButton *)sender {
    self.showingFullLog = !self.showingFullLog;
    UIButtonConfiguration *style = sender.configuration;
    style.title = self.showingFullLog ? @"Recent log" : @"Full log";
    sender.configuration = style;
    [self updateGate];
}
- (void)retryLaunch {
    OMHHarness *dashboard = OMHHarness.dashboard;
    if (OMHBootCoordinator.shared.phase != OMHBootPhaseReady) return;
    if (dashboard.state == OMHHarnessStateFailed || dashboard.state == OMHHarnessStateStopped)
        [dashboard restart];
}
- (void)completeSetup {
    if (self.transitioned || OMHBootCoordinator.shared.phase != OMHBootPhaseReady ||
        OMHHarness.dashboard.state != OMHHarnessStateReady) return;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"omh.launch.setup-completed"];
    [self finishGate];
}
- (void)finishGate {
    if (self.transitioned) return;
    self.transitioned = YES;
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    if (self.onReady) self.onReady();
}
- (void)updateGate {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self updateGate]; });
        return;
    }
    if (!self.isViewLoaded || self.transitioned) return;
    OMHBootCoordinator *boot = OMHBootCoordinator.shared;
    OMHHarness *server = OMHHarness.dashboard;
    self.diagnostics.text = self.showingFullLog ? server.log.diagnosticReport : [server.log tail:14];
    BOOL ready = boot.phase == OMHBootPhaseReady && server.state == OMHHarnessStateReady;
    if (ready) {
        self.progressView.progress = 1.0f;
        self.retryButton.hidden = YES;
        // First run allows the user to acknowledge setup. Every later
        // launch transitions automatically after actual HTTP readiness.
        if ([NSUserDefaults.standardUserDefaults boolForKey:@"omh.launch.setup-completed"]) {
            [self finishGate];
            return;
        }
        self.stateLabel.text = @"Local runtime is ready. Continue to dashboard.";
        self.continueButton.hidden = NO;
        return;
    }
    self.continueButton.hidden = YES;
    BOOL failed = boot.phase == OMHBootPhaseFailed ||
        server.state == OMHHarnessStateFailed || server.state == OMHHarnessStateStopped;
    self.retryButton.hidden = !failed || boot.phase != OMHBootPhaseReady;
    self.stateLabel.textColor = failed ? [UIColor colorWithRed:1.0 green:0.38 blue:0.43 alpha:1] : UIColor.whiteColor;
    self.stateLabel.text = boot.phase == OMHBootPhaseFailed ?
        (boot.statusMessage ?: @"Guest boot failed.") :
        boot.phase != OMHBootPhaseReady ?
        (boot.statusMessage ?: @"Preparing Linux guest…") :
        failed ? (server.lastError ?: @"Runtime failed; retry startup.") :
        @"Starting local dashboard server…";
    // The rootfs import has measurable progress; do not pretend that
    // process readiness has a known percent or countdown.
    self.progressView.progress = boot.phase == OMHBootPhaseImportingImage &&
        boot.progress >= 0 && boot.progress <= 1 ?
        (float)(boot.progress * .8) : boot.phase == OMHBootPhaseReady ? .9f : .82f;
}
@end

@implementation OMHSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    UIWindowScene *windowScene = (UIWindowScene *) scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"recovery"]) {
        // Same escape hatch as iSH: the kernel is not booted, only settings.
        UINavigationController *vc = [[UIStoryboard storyboardWithName:@"About" bundle:nil] instantiateInitialViewController];
        ((AboutViewController *) vc.topViewController).recoveryMode = YES;
        self.window.rootViewController = vc;
    } else {
        // One native UIKit shell on both iPhone (iOS) and iPad (iPadOS).
        // The dashboard adapts its own viewport; the editor is available
        // through the same labeled navigation action on either device.
        OMHLaunchGateController *gate = [OMHLaunchGateController new];
        // Create the dashboard only after setup and HTTP readiness. This
        // prevents a sidebar and toolbar appearing behind the boot screen.
        __weak typeof(self) weakSelf = self;
        gate.onReady = ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            UINavigationController *nav = [[UINavigationController alloc]
                initWithRootViewController:[OMHDashboardViewController new]];
            nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            nav.navigationBar.tintColor = [UIColor colorWithRed:0.66 green:0.33 blue:0.97 alpha:1];
            nav.navigationBar.prefersLargeTitles = NO;
            self.window.rootViewController = nav;
        };
        self.window.rootViewController = gate;
    }
    [self.window makeKeyAndVisible];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    UIViewController *root = self.window.rootViewController;
    if ([root isKindOfClass:UINavigationController.class])
        root = ((UINavigationController *)root).topViewController;
    if ([root isKindOfClass:OMHDashboardViewController.class])
        [OMHHarness.dashboard verifyAliveWithCompletion:nil];
    if ([root isKindOfClass:OMHRootViewController.class])
        [(OMHRootViewController *) root sceneDidBecomeActive];
}

@end

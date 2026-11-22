//
//  OMHSceneDelegate.m
//  OMH
//

#import "OMHSceneDelegate.h"
#import "OMHRootViewController.h"
#import "OMHHarness.h"
#import "OMHBootCoordinator.h"
#import <WebKit/WebKit.h>
#import "AppDelegate.h"
#import "AboutViewController.h"

// UINavigationBar may compress a 44-point custom UIBarButtonItem to a 36-point
// visible frame. Expand the actual hit area and accessibility frame into the
// unused vertical navigation-bar padding, including after device rotation.
@interface OMHRefreshButton : UIButton
@end

@implementation OMHRefreshButton
- (CGRect)expandedBounds {
    CGFloat verticalPadding = MAX(0.0, (44.0 - CGRectGetHeight(self.bounds)) / 2.0);
    CGFloat horizontalPadding = MAX(0.0, (44.0 - CGRectGetWidth(self.bounds)) / 2.0);
    return CGRectInset(self.bounds, -horizontalPadding, -verticalPadding);
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint([self expandedBounds], point);
}
- (CGRect)accessibilityFrame {
    return UIAccessibilityConvertFrameToScreenCoordinates([self expandedBounds], self);
}
@end

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
@property (nonatomic) UIBarButtonItem *refreshItem;
@property (nonatomic) UIBarButtonItem *editorItem;
@property (nonatomic) UILabel *nativeTitle;
@end

@implementation OMHDashboardViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Dashboard";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor colorWithRed:0.012 green:0.027 blue:0.047 alpha:1];

    // Native UIKit chrome around the existing neon dashboard: iPad toolbar,
    // 44-point touch controls, Dynamic Type and the official OMH brand mark.
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
    brandTitle.text = @"OpenMind Harness";
    self.nativeTitle = brandTitle;
    brandTitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    brandTitle.adjustsFontForContentSizeCategory = YES;
    brandTitle.textColor = [UIColor colorWithRed:0.20 green:0.89 blue:1 alpha:1];
    brandTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    UIStackView *identity = [[UIStackView alloc] initWithArrangedSubviews:@[brand, brandTitle]];
    identity.axis = UILayoutConstraintAxisHorizontal;
    identity.alignment = UIStackViewAlignmentCenter;
    identity.spacing = 10;
    identity.accessibilityIdentifier = @"omh.native.brand";
    self.navigationItem.titleView = identity;

    self.editorItem = [[UIBarButtonItem alloc] initWithTitle:@"OpenCode"
        style:UIBarButtonItemStylePlain target:self action:@selector(openEditor)];
    self.editorItem.accessibilityIdentifier = @"omh.open-editor";
    // Keep the "OpenCode" text visible in native navigation, not an icon-only
    // control that becomes ambiguous to touch and VoiceOver users.
    // A system bar button item reports a 36pt frame to XCTest, below the
    // 44pt accessible tap target the UI tests assert. Use a custom 44x44
    // button with the same refresh glyph so the measured target is
    // genuinely 44pt. UIBarButtonItem forwards `enabled` to a UIControl
    // custom view, so updateDashboard keeps working unchanged.
    UIButton *refreshButton = [OMHRefreshButton buttonWithType:UIButtonTypeSystem];
    [refreshButton setImage:[UIImage systemImageNamed:@"arrow.clockwise"] forState:UIControlStateNormal];
    [refreshButton addTarget:self action:@selector(retryDashboard) forControlEvents:UIControlEventTouchUpInside];
    refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [refreshButton.widthAnchor constraintEqualToConstant:44],
        [refreshButton.heightAnchor constraintEqualToConstant:44]
    ]];
    refreshButton.accessibilityIdentifier = @"omh.native.refresh";
    refreshButton.accessibilityLabel = @"Refresh dashboard";
    self.refreshItem = [[UIBarButtonItem alloc] initWithCustomView:refreshButton];
    self.navigationItem.rightBarButtonItems = @[self.editorItem, self.refreshItem];

    self.loadingIndicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.loadingIndicator.color = [UIColor colorWithRed:0.20 green:0.89 blue:1 alpha:1];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithCustomView:self.loadingIndicator];

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
    retryStyle.baseForegroundColor = [UIColor colorWithRed:0.20 green:0.89 blue:1 alpha:1];
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
        [self.dashboard.topAnchor constraintEqualToAnchor:safe.topAnchor],
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
    // In compact iPhone and Stage Manager widths, protect the native
    // toolbar actions rather than truncating or overlapping them.
    CGFloat available = CGRectGetWidth(self.view.bounds);
    self.nativeTitle.text = available < 620 ? @"OMH" : @"OpenMind Harness";
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
    self.editorItem.enabled = boot.phase == OMHBootPhaseReady;
    self.refreshItem.enabled = boot.phase == OMHBootPhaseReady;
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
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[OMHDashboardViewController new]];
        nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        nav.navigationBar.tintColor = [UIColor colorWithRed:0.17 green:0.87 blue:0.94 alpha:1];
        nav.navigationBar.prefersLargeTitles = NO;
        self.window.rootViewController = nav;
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

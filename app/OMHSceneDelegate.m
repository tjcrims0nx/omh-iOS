//
//  OMHSceneDelegate.m
//  OMH
//

#import "OMHSceneDelegate.h"
#import "OMHRootViewController.h"
#import "OMHHarness.h"
#import "OMHBootCoordinator.h"
#import "OMHRootUpgrader.h"
#import "OMHProviderCredentials.h"
#import "OMHApiClient.h"
#import "OMHChatViewController.h"
#import "OMHRuntimeViewController.h"
#import "OMHTheme.h"
#import "AppDelegate.h"
#import "AboutViewController.h"

// The iPad home is a fully native UIKit interface that consumes the harness
// backend API directly (OMHApiClient). There is no browser engine here: the
// dashboard WKWebView was removed by the native OpenUI migration and the
// content area under the responsive header now hosts native Chat and
// Runtime views. The OpenCode editor (OMHRootViewController) keeps its own
// web view; it is a separate component and is untouched.
@interface OMHDashboardViewController : UIViewController <UITableViewDelegate, UITableViewDataSource, UITabBarControllerDelegate>
@property (nonatomic) OMHApiClient *apiClient;
@property (nonatomic) NSURL *apiBaseURL;
@property (nonatomic) OMHChatViewController *chatViewController;
@property (nonatomic) OMHRuntimeViewController *runtimeViewController;
@property (nonatomic) UIViewController *activeViewController;
@property (nonatomic) UIView *contentView;
@property (nonatomic) UITabBarController *tabBarController;
@property (nonatomic) UITableView *sidebarTableView;
@property (nonatomic) UIView *detailContainerView;
@property (nonatomic) UIStackView *notice;
@property (nonatomic) UILabel *message;
@property (nonatomic) UIButton *retry;
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
    self.title = nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor colorWithRed:0.035 green:0.027 blue:0.047 alpha:1];

    // Dedicated responsive header: the brand lives in its own row above the
    // native content area, not in the navigation bar, so it never competes with toolbar
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
    self.editorAction = [UIAction actionWithTitle:@"Workspace" image:nil identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf openEditor];
    }];
    self.refreshAction = [UIAction actionWithTitle:@"Refresh dashboard" image:nil identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf retryDashboard];
    }];
    UIMenu *settingsMenu = [UIMenu menuWithTitle:@"" children:@[self.providersAction, self.editorAction, self.refreshAction]];
    UIButton *settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [settingsButton setImage:[UIImage systemImageNamed:@"gearshape"] forState:UIControlStateNormal];
    settingsButton.tintColor = [OMHTheme accentColor];
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

    // Native content area: the dashboard WKWebView is gone (native OpenUI
    // migration). The container below the header hosts the native Chat and
    // Runtime views. iPhone gets a bottom tab bar; iPad gets a leading
    // sidebar plus a detail area — distinct arrangements per idiom, not one
    // responsive layout. The child view controllers are installed lazily by
    // updateDashboard once the guest server is ready and baseURL is known.
    self.contentView = [UIView new];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentView.backgroundColor = [OMHTheme backgroundColor];
    self.contentView.accessibilityIdentifier = @"omh.native.dashboard";
    [self.view addSubview:self.contentView];

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
        [self.contentView.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],
        [self.contentView.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [self.contentView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.contentView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
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
    self.contentView.hidden = YES;
    self.notice.hidden = NO;
    [self.loadingIndicator startAnimating];
    self.message.text = message;
    self.retry.hidden = !retry;
    if (retry) [self.loadingIndicator stopAnimating];
}

- (BOOL)isPadIdiom {
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
}

/// Installs the native Chat and Runtime views for the current baseURL.
/// iPhone: a bottom tab bar (Chat | Runtime). iPad: a leading sidebar
/// (280pt) plus a detail area. Rebuilt when the baseURL changes (e.g. the
/// guest restarted on a different port) so the API client never goes stale.
- (void)installNativeContent {
    [self teardownNativeContent];
    self.apiClient = [[OMHApiClient alloc] initWithBaseURL:OMHHarness.dashboard.baseURL];
    self.apiBaseURL = OMHHarness.dashboard.baseURL;
    self.chatViewController = [[OMHChatViewController alloc] initWithApiClient:self.apiClient];
    self.runtimeViewController = [[OMHRuntimeViewController alloc] initWithApiClient:self.apiClient];
    if ([self isPadIdiom]) {
        [self installPadContent];
    } else {
        [self installPhoneContent];
    }
}

- (void)installPhoneContent {
    UITabBarController *tabs = [UITabBarController new];
    self.chatViewController.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Chat" image:[UIImage systemImageNamed:@"message"] tag:0];
    self.runtimeViewController.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Runtime" image:[UIImage systemImageNamed:@"gauge.with.dots.needle.33percent"] tag:1];
    tabs.viewControllers = @[self.chatViewController, self.runtimeViewController];
    tabs.tabBar.backgroundColor = [OMHTheme surfaceColor];
    tabs.tabBar.tintColor = [OMHTheme accentColor];
    tabs.tabBar.unselectedItemTintColor = [OMHTheme mutedTextColor];
    tabs.delegate = self;
    [self addChildViewController:tabs];
    tabs.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:tabs.view];
    [NSLayoutConstraint activateConstraints:@[
        [tabs.view.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [tabs.view.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [tabs.view.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [tabs.view.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
    ]];
    [tabs didMoveToParentViewController:self];
    self.tabBarController = tabs;
    self.activeViewController = self.chatViewController;
}

- (void)installPadContent {
    self.sidebarTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.sidebarTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarTableView.backgroundColor = [OMHTheme surfaceColor];
    self.sidebarTableView.separatorColor = [OMHTheme borderColor];
    self.sidebarTableView.delegate = self;
    self.sidebarTableView.dataSource = self;
    self.sidebarTableView.accessibilityIdentifier = @"omh.native.sidebar";
    [self.contentView addSubview:self.sidebarTableView];
    self.detailContainerView = [UIView new];
    self.detailContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailContainerView.backgroundColor = [OMHTheme backgroundColor];
    [self.contentView addSubview:self.detailContainerView];
    [NSLayoutConstraint activateConstraints:@[
        [self.sidebarTableView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [self.sidebarTableView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [self.sidebarTableView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [self.sidebarTableView.widthAnchor constraintEqualToConstant:280],
        [self.detailContainerView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [self.detailContainerView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [self.detailContainerView.leadingAnchor constraintEqualToAnchor:self.sidebarTableView.trailingAnchor],
        [self.detailContainerView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
    ]];
    [self.sidebarTableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0] animated:NO scrollPosition:UITableViewScrollPositionNone];
    [self showPadDetail:self.chatViewController];
}

- (void)showPadDetail:(UIViewController *)detail {
    if (self.activeViewController == detail && detail.parentViewController == self) return;
    UIViewController *old = self.activeViewController;
    [old willMoveToParentViewController:nil];
    [old.view removeFromSuperview];
    [old removeFromParentViewController];
    [self addChildViewController:detail];
    detail.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.detailContainerView addSubview:detail.view];
    [NSLayoutConstraint activateConstraints:@[
        [detail.view.topAnchor constraintEqualToAnchor:self.detailContainerView.topAnchor],
        [detail.view.bottomAnchor constraintEqualToAnchor:self.detailContainerView.bottomAnchor],
        [detail.view.leadingAnchor constraintEqualToAnchor:self.detailContainerView.leadingAnchor],
        [detail.view.trailingAnchor constraintEqualToAnchor:self.detailContainerView.trailingAnchor],
    ]];
    [detail didMoveToParentViewController:self];
    self.activeViewController = detail;
}

- (void)teardownNativeContent {
    if (self.tabBarController) {
        // iPhone: the Chat/Runtime controllers are children of the tab bar,
        // so removing the tab bar removes them too.
        [self.tabBarController willMoveToParentViewController:nil];
        [self.tabBarController.view removeFromSuperview];
        [self.tabBarController removeFromParentViewController];
        self.tabBarController = nil;
        self.activeViewController = nil;
    } else if (self.activeViewController) {
        // iPad: the detail controller is a direct child of this controller.
        [self.activeViewController willMoveToParentViewController:nil];
        [self.activeViewController.view removeFromSuperview];
        [self.activeViewController removeFromParentViewController];
        self.activeViewController = nil;
    }
    [self.sidebarTableView removeFromSuperview];
    self.sidebarTableView = nil;
    [self.detailContainerView removeFromSuperview];
    self.detailContainerView = nil;
    self.chatViewController = nil;
    self.runtimeViewController = nil;
    self.apiClient = nil;
    self.apiBaseURL = nil;
}

#pragma mark - UITabBarControllerDelegate (iPhone)

- (void)tabBarController:(UITabBarController *)tabBarController didSelectViewController:(UIViewController *)viewController {
    self.activeViewController = viewController;
}

#pragma mark - UITableViewDataSource (iPad sidebar)

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 2;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"OMHNativeSidebarCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse];
        cell.backgroundColor = [OMHTheme surfaceColor];
        cell.textLabel.textColor = [OMHTheme textColor];
        cell.selectedBackgroundView = [[UIView alloc] init];
        cell.selectedBackgroundView.backgroundColor = [OMHTheme surfaceRaisedColor];
    }
    BOOL isChat = indexPath.row == 0;
    cell.textLabel.text = isChat ? @"Chat" : @"Runtime";
    cell.imageView.image = [UIImage systemImageNamed:isChat ? @"message" : @"gauge.with.dots.needle.33percent"];
    cell.imageView.tintColor = [OMHTheme accentColor];
    cell.accessibilityIdentifier = isChat ? @"omh.native.sidebar.chat" : @"omh.native.sidebar.runtime";
    return cell;
}

#pragma mark - UITableViewDelegate (iPad sidebar)

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [self showPadDetail:indexPath.row == 0 ? self.chatViewController : self.runtimeViewController];
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
        if (server.baseURL == nil) {
            [self showMessage:@"Waiting for the dashboard address…" retry:NO];
        } else {
            if (self.apiClient == nil || ![self.apiBaseURL isEqual:server.baseURL]) {
                [self installNativeContent];
            }
            self.contentView.hidden = NO;
            self.notice.hidden = YES;
            [self.loadingIndicator stopAnimating];
        }
    } else {
        [self teardownNativeContent];
        BOOL failed = server.state == OMHHarnessStateFailed || server.state == OMHHarnessStateStopped;
        [self showMessage:failed ? (server.lastError ?: @"Dashboard stopped.") : @"Starting dashboard…" retry:failed];
    }
}

- (void)configureProvider {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Provider setup"
        message:@"Optional: save a provider API key securely on this device. Configure credentials here after startup."
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSDictionary<NSString *,NSString *> *providers = @{
        @"OpenAI":@"openai", @"Anthropic":@"anthropic",
        @"Gemini":@"google", @"DeepSeek":@"deepseek",
        @"GLM / Z.AI":@"zai", @"Kimi / Moonshot":@"moonshotai",
        @"Qwen":@"qwen", @"Groq":@"groq", @"Together":@"together", @"OpenRouter":@"openrouter"
    };
    __weak typeof(self) weakSelf = self;
    for (NSString *name in @[@"OpenAI",@"Anthropic",@"Gemini",@"DeepSeek",@"GLM / Z.AI",@"Kimi / Moonshot",@"Qwen",@"Groq",@"Together",@"OpenRouter"]) {
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
        // Refresh the native view the user is looking at; the Settings
        // menu's Refresh action and the notice retry button share this path.
        UIViewController *active = self.activeViewController;
        if ([active isKindOfClass:[OMHChatViewController class]]) {
            [(OMHChatViewController *)active reload];
        } else if ([active isKindOfClass:[OMHRuntimeViewController class]]) {
            [(OMHRuntimeViewController *)active reload];
        }
    } else {
        [OMHHarness.dashboard restart];
    }
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
             name:OMHHarnessStateDidChangeNotification object:nil];
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
    OMHHarness *codingRuntime = OMHHarness.shared;
    if ([dashboard.lastError containsString:@"(error -2)"] ||
        [codingRuntime.lastError containsString:@"(error -2)"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Runtime could not execute"
            message:@"Retry the current guest, or schedule a repair using the bundled Linux image. Repair migrates the existing workspace and configuration; provider keys remain in Keychain."
            preferredStyle:UIAlertControllerStyleAlert];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"Retry" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf retryCurrentGuest];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Repair on next launch" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [OMHRootUpgrader.shared scheduleRepairOnNextLaunch];
            UIAlertController *notice = [UIAlertController alertControllerWithTitle:@"Repair scheduled"
                message:@"Close OMH completely and reopen it to import the bundled Linux image and migrate your data."
                preferredStyle:UIAlertControllerStyleAlert];
            [notice addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [weakSelf presentViewController:notice animated:YES completion:nil];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self retryCurrentGuest];
}
- (void)retryCurrentGuest {
    OMHHarness *dashboard = OMHHarness.dashboard;
    if (OMHBootCoordinator.shared.phase != OMHBootPhaseReady) return;
    if (dashboard.state == OMHHarnessStateFailed || dashboard.state == OMHHarnessStateStopped)
        [dashboard restart];
    OMHHarness *runtime = OMHHarness.shared;
    if (runtime.state == OMHHarnessStateFailed || runtime.state == OMHHarnessStateStopped)
        [runtime restart];
}
- (void)completeSetup {
    if (self.transitioned || OMHBootCoordinator.shared.phase != OMHBootPhaseReady ||
        OMHHarness.dashboard.state != OMHHarnessStateReady ||
        OMHHarness.shared.state != OMHHarnessStateReady) return;
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
    OMHHarness *runtime = OMHHarness.shared;
    NSString *runtimeLog = self.showingFullLog ? runtime.log.diagnosticReport : [runtime.log tail:14];
    NSString *serverLog = self.showingFullLog ? server.log.diagnosticReport : [server.log tail:8];
    self.diagnostics.text = [NSString stringWithFormat:@"HARNESS RUNTIME\n%@\n\nDASHBOARD API\n%@", runtimeLog, serverLog];
    BOOL ready = boot.phase == OMHBootPhaseReady && server.state == OMHHarnessStateReady && runtime.state == OMHHarnessStateReady;
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
        server.state == OMHHarnessStateFailed || server.state == OMHHarnessStateStopped ||
        runtime.state == OMHHarnessStateFailed || runtime.state == OMHHarnessStateStopped;
    self.retryButton.hidden = !failed || boot.phase != OMHBootPhaseReady;
    self.stateLabel.textColor = failed ? [UIColor colorWithRed:1.0 green:0.38 blue:0.43 alpha:1] : UIColor.whiteColor;
    self.stateLabel.text = boot.phase == OMHBootPhaseFailed ?
        (boot.statusMessage ?: @"Guest boot failed.") :
        boot.phase != OMHBootPhaseReady ?
        (boot.statusMessage ?: @"Preparing Linux guest…") :
        failed ? (runtime.lastError ?: server.lastError ?: @"Runtime failed; retry startup.") :
        runtime.state != OMHHarnessStateReady ? @"Starting OpenMind Harness…" :
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

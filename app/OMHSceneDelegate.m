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


#pragma mark - Native iPad dashboard
// The primary iPad workspace is UIKit, not a scaled HTML document.
// The legacy web dashboard remains available as a secondary diagnostic view.
@interface OMHNativeIPadController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic) UITableView *sectionsTable;
@property (nonatomic) UITableView *detailTable;
@property (nonatomic) UILabel *heading;
@property (nonatomic) UILabel *connection;
@property (nonatomic) NSArray<NSString *> *sections;
@property (nonatomic) NSDictionary *runtimeState;
@property (nonatomic) NSInteger selection;
@property (nonatomic) NSUInteger requestGeneration;
@property (nonatomic) BOOL fetching;
@end

@implementation OMHNativeIPadController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"OpenMind Harness";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor colorWithRed:0.012 green:0.027 blue:0.047 alpha:1];
    self.sections = @[@"Overview", @"Agent teams", @"Tasks", @"Workflows", @"Skills",
                      @"Plugins", @"Trace", @"Sandbox", @"Schedules", @"Workspaces", @"Memory"];
    self.selection = 0;
    UIColor *cyan = [UIColor colorWithRed:0.20 green:0.89 blue:1 alpha:1];
    self.navigationController.navigationBar.tintColor = cyan;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"OMH" style:UIBarButtonItemStylePlain target:nil action:nil];
    UIBarButtonItem *advanced = [[UIBarButtonItem alloc]
        initWithTitle:@"Web dashboard" style:UIBarButtonItemStylePlain
        target:self action:@selector(openWebDashboard)];
    advanced.accessibilityIdentifier = @"omh.native.advanced-web";
    UIBarButtonItem *editor = [[UIBarButtonItem alloc]
        initWithTitle:@"OpenCode" style:UIBarButtonItemStylePlain
        target:self action:@selector(openEditor)];
    editor.accessibilityIdentifier = @"omh.open-editor";
    self.navigationItem.rightBarButtonItems = @[editor, advanced];

    UIView *layout = [UIView new];
    layout.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:layout];
    [NSLayoutConstraint activateConstraints:@[
        [layout.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [layout.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [layout.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [layout.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor]
    ]];

    self.sectionsTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.detailTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    for (UITableView *table in @[self.sectionsTable, self.detailTable]) {
        table.translatesAutoresizingMaskIntoConstraints = NO;
        table.backgroundColor = UIColor.clearColor;
        table.separatorColor = [cyan colorWithAlphaComponent:0.18];
        table.dataSource = self;
        table.delegate = self;
        table.rowHeight = UITableViewAutomaticDimension;
        table.estimatedRowHeight = 56;
        [layout addSubview:table];
    }
    self.sectionsTable.accessibilityIdentifier = @"omh.native.ipad.sidebar";
    self.detailTable.accessibilityIdentifier = @"omh.native.ipad.content";
    self.heading = [UILabel new];
    self.heading.text = @"Overview";
    self.heading.font = [UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];
    self.heading.adjustsFontForContentSizeCategory = YES;
    self.heading.textColor = cyan;
    self.connection = [UILabel new];
    self.connection.text = @"Starting local OMH runtime…";
    self.connection.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.connection.textColor = UIColor.secondaryLabelColor;
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[self.heading,self.connection]];
    header.axis = UILayoutConstraintAxisVertical;
    header.spacing = 7;
    header.layoutMargins = UIEdgeInsetsMake(14,20,12,20);
    header.layoutMarginsRelativeArrangement = YES;
    header.frame = CGRectMake(0,0,400,100);
    self.detailTable.tableHeaderView = header;

    UIBarButtonItem *refresh = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshRuntime)];
    refresh.accessibilityIdentifier = @"omh.native.ipad.refresh";
    self.toolbarItems = @[refresh];
    self.navigationController.toolbarHidden = NO;

    // A fixed-width native sidebar on iPad; content expands with Stage Manager
    // or rotation and does not rely on web CSS viewport or pinch scaling.
    [NSLayoutConstraint activateConstraints:@[
        [self.sectionsTable.leadingAnchor constraintEqualToAnchor:layout.leadingAnchor],
        [self.sectionsTable.topAnchor constraintEqualToAnchor:layout.topAnchor],
        [self.sectionsTable.bottomAnchor constraintEqualToAnchor:layout.bottomAnchor],
        [self.sectionsTable.widthAnchor constraintEqualToConstant:246],
        [self.detailTable.leadingAnchor constraintEqualToAnchor:self.sectionsTable.trailingAnchor],
        [self.detailTable.trailingAnchor constraintEqualToAnchor:layout.trailingAnchor],
        [self.detailTable.topAnchor constraintEqualToAnchor:layout.topAnchor],
        [self.detailTable.bottomAnchor constraintEqualToAnchor:layout.bottomAnchor]
    ]];
    [self.sectionsTable selectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]
                                    animated:NO scrollPosition:UITableViewScrollPositionNone];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(runtimeChanged:)
        name:OMHHarnessStateDidChangeNotification object:OMHHarness.dashboard];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(runtimeChanged:)
        name:OMHBootStateDidChangeNotification object:nil];
    [self refreshRuntime];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:animated];
    [self refreshRuntime];
}
- (void)runtimeChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{ [self refreshRuntime]; });
}
- (void)openWebDashboard {
    [self.navigationController pushViewController:[OMHDashboardViewController new] animated:YES];
}
- (void)openEditor {
    if (OMHHarness.shared.state == OMHHarnessStateIdle) [OMHHarness.shared start];
    [self.navigationController pushViewController:[OMHRootViewController new] animated:YES];
}
- (void)refreshRuntime {
    OMHHarness *server = OMHHarness.dashboard;
    if (server.state != OMHHarnessStateReady || server.baseURL == nil) {
        self.connection.text = server.lastError ?: @"Starting local OMH runtime…";
        [self.detailTable reloadData];
        return;
    }
    if (self.fetching) return;
    self.fetching = YES;
    NSURL *url = [server.baseURL URLByAppendingPathComponent:@"api/state"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 10;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSUInteger generation = ++self.requestGeneration;
    __weak typeof(self) weakSelf = self;
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:
      ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *state = nil;
        if (data.length && !error && [(NSHTTPURLResponse *)response statusCode] == 200) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([parsed isKindOfClass:NSDictionary.class]) state = parsed;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.requestGeneration) return;
            strongSelf.fetching = NO;
            if (state) strongSelf.runtimeState = state;
            strongSelf.connection.text = state ? @"● Connected to local runtime"
                : @"Runtime is starting or temporarily unavailable";
            [strongSelf.detailTable reloadData];
        });
    }] resume];
}
- (NSArray *)currentItems {
    NSDictionary *state = self.runtimeState;
    if (!state) return @[];
    NSString *section = self.sections[self.selection];
    if ([section isEqualToString:@"Overview"]) {
        NSDictionary *counts = [state[@"counts"] isKindOfClass:NSDictionary.class] ? state[@"counts"] : @{};
        return @[
            @{@"name":@"Queued tasks", @"status":[counts[@"queued"] description] ?: @"0"},
            @{@"name":@"Running tasks", @"status":[counts[@"running"] description] ?: @"0"},
            @{@"name":@"Completed tasks", @"status":[counts[@"completed"] description] ?: @"0"},
            @{@"name":@"Failed tasks", @"status":[counts[@"failed"] description] ?: @"0"},
            @{@"name":@"Worker", @"status":state[@"worker"] ? @"Runtime available" : @"No active worker"}
        ];
    }
    NSDictionary *keys = @{
      @"Agent teams":@"agents", @"Tasks":@"tasks", @"Workflows":@"workflowSteps",
      @"Skills":@"skills", @"Plugins":@"plugins", @"Trace":@"traces",
      @"Sandbox":@"sandbox", @"Schedules":@"schedules", @"Workspaces":@"workspaces",
      @"Memory":@"memory"};
    id items = state[keys[section]];
    return [items isKindOfClass:NSArray.class] ? items : @[];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return tableView == self.sectionsTable ? self.sections.count : MAX(1, [self currentItems].count);
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"native"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"native"];
    cell.backgroundColor = [UIColor colorWithRed:0.035 green:0.065 blue:0.10 alpha:1];
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (tableView == self.sectionsTable) {
        cell.textLabel.text = self.sections[indexPath.row];
        cell.detailTextLabel.text = nil;
        cell.accessibilityIdentifier = [NSString stringWithFormat:@"omh.native.ipad.section.%ld",(long)indexPath.row];
        cell.accessoryType = indexPath.row == self.selection ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    } else {
        NSArray *items = [self currentItems];
        if (!items.count) {
            cell.textLabel.text = self.runtimeState ? @"No records in this section" : @"Waiting for runtime…";
            cell.detailTextLabel.text = nil;
        } else {
            id item = items[indexPath.row];
            if ([item isKindOfClass:NSDictionary.class]) {
                NSDictionary *obj = item;
                cell.textLabel.text = [obj[@"name"] description] ?: [obj[@"title"] description] ?:
                    [obj[@"kind"] description] ?: [obj[@"type"] description] ?: [obj[@"id"] description] ?: @"Record";
                cell.detailTextLabel.text = [obj[@"status"] description] ?: [obj[@"scope"] description] ?:
                    [obj[@"version"] description] ?: @"";
            } else {
                cell.textLabel.text = [item description];
                cell.detailTextLabel.text = nil;
            }
        }
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView != self.sectionsTable) return;
    self.selection = indexPath.row;
    self.heading.text = self.sections[self.selection];
    [self.sectionsTable reloadData];
    [self.detailTable reloadData];
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
        UIViewController *home = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad
            ? [OMHNativeIPadController new] : [OMHDashboardViewController new];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:home];
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

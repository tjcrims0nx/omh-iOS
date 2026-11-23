//
//  OMHRootViewController.m
//  OMH
//

#import "OMHRootViewController.h"
#import "OMHHarness.h"
#import "OMHBootCoordinator.h"
#import "OMHLogViewController.h"
#import "OMHCapabilitiesViewController.h"
#import "OMHActivityViewController.h"
#import "OMHActivityLog.h"
#import "OMHTurnPresence.h"
#import "OMHRootUpgrader.h"
#import "OMHStartupMetrics.h"
#import "OMHStatusOverlayView.h"
#import "TerminalViewController.h"
#import "AppDelegate.h"
#import "OMHProviderCredentials.h"
#import "OMHProviderVerifier.h"
#import <WebKit/WebKit.h>

static NSString *const kOMHUserAgentSuffix = @" OpenMind-Harness-iOS/1.0";

@interface OMHRootViewController () <WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate>
@property (nonatomic) WKWebView *webView;
@property (nonatomic) OMHStatusOverlayView *overlay;
@property (nonatomic) UIView *controlBar;
@property (nonatomic) NSLayoutConstraint *controlBarHeight;
@property (nonatomic) UIScrollView *sidebar;
@property (nonatomic) NSLayoutConstraint *sidebarWidth;
@property (nonatomic) UIButton *sidebarTerminal;
@property (nonatomic) UIView *inspector;
@property (nonatomic) NSLayoutConstraint *inspectorWidth;
@property (nonatomic) NSLayoutConstraint *workspaceInset;
@property (nonatomic) UINavigationController *inspectorController;
@property (nonatomic) NSArray<UIButton *> *sidebarButtons;
@property (nonatomic) UILabel *titleLabel;
@property (nonatomic) UIView *statusDot;
@property (nonatomic) UIButton *menuButton;
@property (nonatomic) UIButton *activityIndicatorButton;
@property (nonatomic) UIButton *terminalButton;
@property (nonatomic, nullable) TerminalViewController *terminalVC;
@property (nonatomic) uint16_t loadedPort;
@property (nonatomic) BOOL pageLoaded;
@property (nonatomic) NSUInteger pageLoadGeneration;
@property (nonatomic) NSMutableDictionary<NSValue *, NSURL *> *downloadDestinations;
@end

@implementation OMHRootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.018 green:0.031 blue:0.071 alpha:1.0];
    self.downloadDestinations = [NSMutableDictionary dictionary];

    [self buildWebView];
    [self buildControlBar];
    [self buildDesktopWorkspace];
    [self buildOverlay];
    [self.view bringSubviewToFront:self.inspector];

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(harnessStateChanged:) name:OMHHarnessStateDidChangeNotification object:OMHHarness.shared];
    [nc addObserver:self selector:@selector(logChanged:) name:OMHLogBufferDidChangeNotification object:OMHHarness.shared.log];
    [nc addObserver:self selector:@selector(bootStateChanged:) name:OMHBootStateDidChangeNotification object:nil];
    [self observeActivity];
    [OMHTurnPresence.shared start];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(turnWasInterrupted:)
                                               name:OMHTurnWasInterruptedNotification object:nil];
    [self applyHarnessState];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - Building the view

- (void)buildWebView {
    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    config.allowsInlineMediaPlayback = YES;
    config.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    config.applicationNameForUserAgent = kOMHUserAgentSuffix;
    config.defaultWebpagePreferences.allowsContentJavaScript = YES;
    if (self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad)
        config.defaultWebpagePreferences.preferredContentMode = WKContentModeDesktop;
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.allowsBackForwardNavigationGestures = NO;
    self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.webView.scrollView.bounces = NO;
    self.webView.opaque = NO;
    self.webView.backgroundColor = UIColor.clearColor;
    self.webView.scrollView.backgroundColor = UIColor.clearColor;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.accessibilityIdentifier = @"omh.webview";
#if DEBUG
    if (@available(iOS 16.4, *))
        self.webView.inspectable = YES;
#endif
    [self.view addSubview:self.webView];
}

- (void)buildControlBar {
    UIView *bar = [UIView new];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    bar.backgroundColor = [UIColor colorWithRed:0.025 green:0.055 blue:0.11 alpha:1.0];
    bar.layer.borderColor = [UIColor colorWithRed:0.0 green:0.75 blue:0.95 alpha:0.45].CGColor;
    bar.layer.borderWidth = 0.5;
    bar.accessibilityIdentifier = @"omh.controlbar";
    self.controlBar = bar;
    [self.view addSubview:bar];

    UIView *dot = [UIView new];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.layer.cornerRadius = 4;
    dot.backgroundColor = UIColor.systemOrangeColor;
    dot.accessibilityIdentifier = @"omh.statusdot";
    dot.isAccessibilityElement = YES;
    dot.accessibilityLabel = @"Harness status";
    self.statusDot = dot;

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"OpenMind Harness";
    title.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold];
    title.textColor = [UIColor colorWithRed:0.0 green:0.89 blue:1.0 alpha:1.0];
    title.accessibilityIdentifier = @"omh.title";
    self.titleLabel = title;

    // Mirrors iOS's own privacy indicator: something on the device was just
    // used, here is where to look. Hidden until it has something to say.
    UIButton *activity = [self barButtonWithSymbol:@"antenna.radiowaves.left.and.right"
                                            action:@selector(presentActivity)
                                        identifier:@"omh.activityindicator"];
    activity.accessibilityLabel = @"Recent capability use";
    activity.tintColor = UIColor.systemOrangeColor;
    activity.hidden = YES;
    self.activityIndicatorButton = activity;

    UIButton *terminal = [self barButtonWithSymbol:@"terminal" action:@selector(presentTerminal) identifier:@"omh.terminal"];
    terminal.accessibilityLabel = @"Terminal";
    self.terminalButton = terminal;

    UIButton *menu = [self barButtonWithSymbol:@"ellipsis.circle" action:nil identifier:@"omh.menu"];
    menu.accessibilityLabel = @"More";
    menu.showsMenuAsPrimaryAction = YES;
    menu.menu = [self buildMenu];
    self.menuButton = menu;

    UIImage *brandImage = [UIImage imageNamed:@"OMHBrandMark"];
    UIImageView *brandIcon = [[UIImageView alloc] initWithImage:brandImage];
    brandIcon.translatesAutoresizingMaskIntoConstraints = NO;
    brandIcon.contentMode = UIViewContentModeScaleAspectFit;
    brandIcon.layer.cornerRadius = 5;
    brandIcon.clipsToBounds = YES;
    brandIcon.hidden = brandImage == nil;
    brandIcon.accessibilityLabel = @"OpenMind Harness app icon";
    brandIcon.accessibilityIdentifier = @"omh.brand.icon";
    [brandIcon.widthAnchor constraintEqualToConstant:24].active = YES;
    [brandIcon.heightAnchor constraintEqualToConstant:24].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[brandIcon, dot, title, [UIView new], activity, terminal, menu]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8;
    [bar addSubview:stack];

    self.controlBarHeight = [bar.heightAnchor constraintEqualToConstant:40];
    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        self.controlBarHeight,
        [stack.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-8],
        [stack.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [dot.widthAnchor constraintEqualToConstant:8],
        [dot.heightAnchor constraintEqualToConstant:8],

        [self.webView.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        // Keep the harness composer above the software keyboard. WKWebView's
        // own viewport updates are not reliable across iOS releases when its
        // scroll view uses contentInsetAdjustmentNever; the keyboard layout
        // guide makes the native contract explicit and is a no-op for a
        // hardware keyboard.
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    ]];
}

- (void)buildDesktopWorkspace {
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    UIScrollView *rail = [UIScrollView new];
    rail.translatesAutoresizingMaskIntoConstraints = NO;
    rail.backgroundColor = [UIColor colorWithRed:0.025 green:0.047 blue:0.075 alpha:1];
    rail.accessibilityIdentifier = @"omh.sidebar";
    rail.clipsToBounds = YES;
    [self.view addSubview:rail];
    self.sidebar = rail;

    UIStackView *items = [UIStackView new];
    items.axis = UILayoutConstraintAxisVertical;
    items.spacing = 6;
    items.translatesAutoresizingMaskIntoConstraints = NO;
    [rail addSubview:items];
    UIButton *workspace = [self sidebarButton:@"Workspace" symbol:@"rectangle.split.2x1" action:@selector(closeInspector) key:@"workspace"];
    self.sidebarTerminal = [self sidebarButton:@"Terminal" symbol:@"terminal" action:@selector(presentTerminal) key:@"terminal"];
    self.sidebarButtons = @[workspace, self.sidebarTerminal,
        [self sidebarButton:@"Activity" symbol:@"waveform.path.ecg" action:@selector(presentActivity) key:@"activity"],
        [self sidebarButton:@"Server Log" symbol:@"text.alignleft" action:@selector(presentLog) key:@"log"],
        [self sidebarButton:@"Capabilities" symbol:@"switch.2" action:@selector(presentCapabilities) key:@"capabilities"]];
    for (UIButton *button in self.sidebarButtons) [items addArrangedSubview:button];
    workspace.selected = YES;

    UIView *inspector = [UIView new];
    inspector.translatesAutoresizingMaskIntoConstraints = NO;
    inspector.clipsToBounds = YES;
    inspector.accessibilityIdentifier = @"omh.inspector";
    inspector.hidden = YES;
    [self.view addSubview:inspector];
    self.inspector = inspector;
    self.sidebarWidth = [rail.widthAnchor constraintEqualToConstant:0];
    self.inspectorWidth = [inspector.widthAnchor constraintEqualToConstant:0];
    self.workspaceInset = [self.webView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [rail.topAnchor constraintEqualToAnchor:self.controlBar.bottomAnchor],
        [rail.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [rail.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        self.sidebarWidth,
        [items.leadingAnchor constraintEqualToAnchor:rail.contentLayoutGuide.leadingAnchor constant:8],
        [items.trailingAnchor constraintEqualToAnchor:rail.contentLayoutGuide.trailingAnchor constant:-8],
        [items.topAnchor constraintEqualToAnchor:rail.contentLayoutGuide.topAnchor constant:16],
        [items.bottomAnchor constraintEqualToAnchor:rail.contentLayoutGuide.bottomAnchor constant:-16],
        [items.widthAnchor constraintEqualToConstant:164],
        [self.webView.leadingAnchor constraintEqualToAnchor:rail.trailingAnchor],
        self.workspaceInset,
        [inspector.topAnchor constraintEqualToAnchor:self.controlBar.bottomAnchor],
        [inspector.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [inspector.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        self.inspectorWidth,
    ]];
}

- (UIButton *)sidebarButton:(NSString *)title symbol:(NSString *)symbol action:(SEL)action key:(NSString *)key {
    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.title = title;
    config.image = [UIImage systemImageNamed:symbol];
    config.imagePadding = 9;
    config.contentInsets = NSDirectionalEdgeInsetsMake(12, 10, 12, 8);
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    // Touch targets meet the native iPad minimum, including Pointer/VoiceOver.
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    button.accessibilityIdentifier = [@"omh.sidebar." stringByAppendingString:key];
    button.configurationUpdateHandler = ^(UIButton *item) {
        UIButtonConfiguration *style = item.configuration;
        style.baseForegroundColor = item.selected ? UIColor.cyanColor : UIColor.lightTextColor;
        style.background.backgroundColor = item.selected ? [UIColor colorWithRed:0.04 green:0.15 blue:0.20 alpha:1] : UIColor.clearColor;
        item.configuration = style;
    };
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    CGFloat width = CGRectGetWidth(self.view.bounds) - self.view.safeAreaInsets.left - self.view.safeAreaInsets.right;
    BOOL desktop = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad && width >= 740;
    // Keep the OMH dark/cyan identity in compact iPad windows and portrait.
    // Size-class changes alter navigation geometry, not the color scheme.
    if (self.overrideUserInterfaceStyle != UIUserInterfaceStyleDark)
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.sidebarWidth.constant = desktop ? 180 : 0;
    self.sidebar.hidden = !desktop;
    self.controlBarHeight.constant = 52; // 44-pt controls plus native spacing
    // Keep the live web session mounted through rotation, split view and inspector changes.
    BOOL besideWorkspace = desktop && width >= 1040;
    CGFloat inspector = self.inspectorController ? (besideWorkspace ? 332 : MAX(0, width - self.sidebarWidth.constant)) : 0;
    self.inspectorWidth.constant = inspector;
    self.workspaceInset.constant = besideWorkspace ? -inspector : 0;
    BOOL covered = self.inspectorController && !besideWorkspace;
    self.webView.accessibilityElementsHidden = covered;
    self.overlay.accessibilityElementsHidden = covered;
}

- (void)closeInspector {
    UINavigationController *nav = self.inspectorController;
    if (nav) {
        [nav willMoveToParentViewController:nil];
        [nav.view removeFromSuperview];
        [nav removeFromParentViewController];
        self.inspectorController = nil;
    }
    self.inspector.hidden = YES;
    for (UIButton *button in self.sidebarButtons) button.selected = button == self.sidebarButtons.firstObject;
    [self.view setNeedsLayout];
}

- (void)showInspector:(UIViewController *)controller key:(NSString *)key {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
    if (self.sidebar.hidden) {
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [self presentViewController:nav animated:YES completion:nil];
        return;
    }
    [self closeInspector];
    [self addChildViewController:nav];
    self.inspectorController = nav;
    self.inspector.hidden = NO;
    nav.view.frame = self.inspector.bounds;
    nav.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.inspector addSubview:nav.view];
    [nav didMoveToParentViewController:self];
    [controller loadViewIfNeeded];
    for (UIBarButtonItem *item in controller.navigationItem.rightBarButtonItems) {
        if (item.action == @selector(done)) { item.target = self; item.action = @selector(closeInspector); }
    }
    NSString *identifier = [@"omh.sidebar." stringByAppendingString:key];
    for (UIButton *button in self.sidebarButtons) button.selected = [button.accessibilityIdentifier isEqualToString:identifier];
    [self.view setNeedsLayout];
}

- (UIButton *)barButtonWithSymbol:(NSString *)symbol action:(nullable SEL)action identifier:(NSString *)identifier {
    UIButtonConfiguration *conf = [UIButtonConfiguration plainButtonConfiguration];
    conf.image = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightMedium]];
    conf.contentInsets = NSDirectionalEdgeInsetsMake(12, 12, 12, 12);
    conf.baseForegroundColor = UIColor.secondaryLabelColor;
    UIButton *button = [UIButton buttonWithConfiguration:conf primaryAction:nil];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    button.accessibilityIdentifier = identifier;
    if (action)
        [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIMenu *)buildMenu {
    __weak typeof(self) weakSelf = self;
    UIAction *reload = [UIAction actionWithTitle:@"Reload" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:@"omh.reload" handler:^(UIAction *a) { [weakSelf reloadWebView]; }];
    UIAction *terminal = [UIAction actionWithTitle:@"Terminal" image:[UIImage systemImageNamed:@"terminal"] identifier:@"omh.terminal.menu" handler:^(UIAction *a) { [weakSelf presentTerminal]; }];
    UIAction *connectors = [UIAction actionWithTitle:@"Provider Connections" image:[UIImage systemImageNamed:@"key.horizontal"] identifier:@"omh.connectors" handler:^(UIAction *a) { [weakSelf showProviderConnections]; }];
    UIAction *capabilities = [UIAction actionWithTitle:@"Capabilities" image:[UIImage systemImageNamed:@"switch.2"] identifier:@"omh.capabilities" handler:^(UIAction *a) { [weakSelf presentCapabilities]; }];
    UIAction *activity = [UIAction actionWithTitle:@"Activity" image:[UIImage systemImageNamed:@"list.bullet.rectangle"] identifier:@"omh.activity" handler:^(UIAction *a) { [weakSelf presentActivity]; }];
    UIAction *log = [UIAction actionWithTitle:@"Server Log" image:[UIImage systemImageNamed:@"doc.text.magnifyingglass"] identifier:@"omh.log" handler:^(UIAction *a) { [weakSelf presentLog]; }];
    UIAction *restart = [UIAction actionWithTitle:@"Restart Harness" image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"] identifier:@"omh.restart" handler:^(UIAction *a) { [weakSelf confirmRestart]; }];
    restart.attributes = UIMenuElementAttributesDestructive;
    UIAction *repair = [UIAction actionWithTitle:@"Repair Linux Environment" image:[UIImage systemImageNamed:@"wrench.and.screwdriver"] identifier:@"omh.repair" handler:^(UIAction *a) { [weakSelf confirmRepair]; }];
    UIAction *safari = [UIAction actionWithTitle:@"Open in Safari" image:[UIImage systemImageNamed:@"safari"] identifier:@"omh.safari" handler:^(UIAction *a) {
        NSURL *url = OMHHarness.shared.baseURL;
        if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }];
    UIAction *about = [UIAction actionWithTitle:@"About OpenMind Harness" image:[UIImage systemImageNamed:@"info.circle"] identifier:@"omh.about" handler:^(UIAction *a) { [weakSelf presentAbout]; }];
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray arrayWithObjects:reload, terminal, nil];
    [children addObjectsFromArray:@[connectors, capabilities, activity, log, [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[safari, restart, repair]], about]];
    return [UIMenu menuWithChildren:children];
}

- (void)showProviderConnections {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"Provider Connections"
        message:@"Select a provider to securely save or remove an API key. Restart the harness to apply changes."
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSDictionary<NSString *,NSString *> *providers=@{
        @"OpenAI / ChatGPT":@"openai", @"Anthropic / Claude":@"anthropic",
        @"Google Gemini":@"google", @"DeepSeek":@"deepseek",
        @"GLM / Z.AI":@"zai", @"Kimi / Moonshot":@"moonshotai",
        @"Qwen":@"qwen", @"Universal bearer key":@"custom"};
    __weak typeof(self) weakSelf=self;
    for (NSString *label in @[@"OpenAI / ChatGPT",@"Anthropic / Claude",@"Google Gemini",@"DeepSeek",@"GLM / Z.AI",@"Kimi / Moonshot",@"Qwen",@"Universal bearer key"]) {
        NSString *provider=providers[label];
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf editProvider:provider label:label];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView=self.menuButton ?: self.view;
    sheet.popoverPresentationController.sourceRect=self.menuButton ? self.menuButton.bounds : CGRectMake(CGRectGetMidX(self.view.bounds),0,1,1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)editProvider:(NSString *)provider label:(NSString *)label {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:label
        message:@"API key stored in this device's Keychain. Restart the harness after saving or removing it."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder=@"Provider API key";
        field.secureTextEntry=YES;
        field.autocorrectionType=UITextAutocorrectionTypeNo;
        field.autocapitalizationType=UITextAutocapitalizationTypeNone;
        field.textContentType=UITextContentTypePassword;
    }];
    __weak typeof(self) weakSelf=self;
    if ([provider isEqualToString:@"openai"] || [provider isEqualToString:@"anthropic"]) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Official Account Login" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSString *command=[provider isEqualToString:@"openai"]
                ? @"opencode auth login --provider openai --method \"ChatGPT Pro/Plus (headless)\""
                : @"opencode auth login";
            NSString *message=[NSString stringWithFormat:@"OpenCode handles the official provider authorization. In the terminal, run:\n\n%@\n\nFollow the provider's instructions in your browser. OMH never requests your account password.",command];
            UIAlertController *instructions=[UIAlertController alertControllerWithTitle:@"OpenCode Account Authorization" message:message preferredStyle:UIAlertControllerStyleAlert];
            [instructions addAction:[UIAlertAction actionWithTitle:@"Copy Command" style:UIAlertActionStyleDefault handler:^(UIAlertAction *copyAction) {
                UIPasteboard.generalPasteboard.string=command;
                [weakSelf presentTerminal];
            }]];
            [instructions addAction:[UIAlertAction actionWithTitle:@"Open Terminal" style:UIAlertActionStyleDefault handler:^(UIAlertAction *openAction) {
                [weakSelf presentTerminal];
            }]];
            [instructions addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [weakSelf presentViewController:instructions animated:YES completion:nil];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Save Key" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *token=[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if(![OMHProviderCredentials saveToken:token provider:provider]) {
            UIAlertController *error=[UIAlertController alertControllerWithTitle:@"Key not saved" message:@"Enter a nonempty key and check Keychain access." preferredStyle:UIAlertControllerStyleAlert];
            [error addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [weakSelf presentViewController:error animated:YES completion:nil];
        } else [OMHHarness.shared restart];
    }]];
    if (![provider isEqualToString:@"custom"]) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Verify Saved Key" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [OMHProviderVerifier verifyProvider:provider completion:^(NSString *status) {
                UIAlertController *result=[UIAlertController alertControllerWithTitle:label message:status preferredStyle:UIAlertControllerStyleAlert];
                [result addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [weakSelf presentViewController:result animated:YES completion:nil];
            }];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Remove Key" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [OMHProviderCredentials removeProvider:provider];
        [OMHHarness.shared restart];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)buildOverlay {
    self.overlay = [[OMHStatusOverlayView alloc] initWithFrame:CGRectZero];
    self.overlay.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weakSelf = self;
    self.overlay.retryHandler = ^{ [OMHHarness.shared restart]; };
    self.overlay.terminalHandler = ^{ [weakSelf presentTerminal]; };
    self.overlay.logHandler = ^{ [weakSelf presentLog]; };
    [self.view addSubview:self.overlay];
    [NSLayoutConstraint activateConstraints:@[
        [self.overlay.topAnchor constraintEqualToAnchor:self.controlBar.bottomAnchor],
        [self.overlay.leadingAnchor constraintEqualToAnchor:self.webView.leadingAnchor],
        [self.overlay.trailingAnchor constraintEqualToAnchor:self.webView.trailingAnchor],
        [self.overlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

#pragma mark - Harness state

- (void)harnessStateChanged:(NSNotification *)note {
    [self applyHarnessState];
}

- (void)bootStateChanged:(NSNotification *)note {
    [self applyHarnessState];
}

- (void)logChanged:(NSNotification *)note {
    [self.overlay setLogText:[OMHHarness.shared.log tail:12]];
}

- (void)applyHarnessState {
    OMHHarness *h = OMHHarness.shared;
    UIColor *dotColor;
    switch (h.state) {
        case OMHHarnessStateReady: dotColor = UIColor.systemGreenColor; break;
        case OMHHarnessStateFailed: dotColor = UIColor.systemRedColor; break;
        case OMHHarnessStateStopped: dotColor = UIColor.systemGrayColor; break;
        default: dotColor = UIColor.systemOrangeColor; break;
    }
    self.statusDot.backgroundColor = dotColor;
    self.statusDot.accessibilityValue = OMHHarnessStateName(h.state);
    self.titleLabel.text = h.port ? [NSString stringWithFormat:@"OpenMind Harness · :%u", h.port] : @"OpenMind Harness";

    // Before the guest is up, the boot coordinator owns the overlay.
    OMHBootCoordinator *boot = OMHBootCoordinator.shared;
    self.terminalButton.enabled = boot.phase == OMHBootPhaseReady;
    self.sidebarTerminal.enabled = self.terminalButton.enabled;
    if (boot.phase != OMHBootPhaseReady) {
        if (boot.phase == OMHBootPhaseFailed) {
            [self.overlay showFailure:boot.statusMessage];
        } else {
            [self.overlay showStarting:boot.statusMessage];
            [self.overlay setDeterminateProgress:boot.progress
                                          detail:boot.progress >= 0
                                                 ? [NSString stringWithFormat:@"%.0f%% · first launch only", boot.progress * 100]
                                                 : @"this takes a moment on first launch"];
        }
        return;
    }

    switch (h.state) {
        case OMHHarnessStateIdle:
        case OMHHarnessStateStarting:
            [self.overlay showStarting:@"Starting OpenMind Harness…"];
            [self.overlay setProgressStartedAt:h.launchStartedAt ?: NSDate.date expected:h.expectedStartupDuration];
            break;
        case OMHHarnessStateRestarting:
            [self.overlay showStarting:@"Restarting the harness…"];
            [self.overlay setProgressStartedAt:nil expected:0];
            self.pageLoaded = NO;
            break;
        case OMHHarnessStateReady:
            if (!self.pageLoaded || self.loadedPort != h.port)
                [self loadHarness];
            else
                [self.overlay hide];
            break;
        case OMHHarnessStateFailed:
            [self.overlay showFailure:h.lastError ?: @"The harness could not be started."];
            break;
        case OMHHarnessStateStopped:
            [self.overlay showFailure:@"The harness is stopped."];
            break;
    }
}

- (void)loadHarness {
    NSURL *url = OMHHarness.shared.baseURL;
    if (url == nil)
        return;
    [self.overlay showStarting:@"Loading the interface…"];
    [self.overlay setProgressStartedAt:nil expected:0];
    self.loadedPort = OMHHarness.shared.port;
    self.pageLoaded = NO;
    self.pageLoadGeneration++;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [self.webView loadRequest:req];
}

- (void)sceneDidBecomeActive {
    // After a suspension the page's websocket may be gone; the client
    // reconnects on its own, but a dead server needs a restart + reload.
    if (OMHHarness.shared.state == OMHHarnessStateReady && self.pageLoaded) {
        __weak typeof(self) weakSelf = self;
        [OMHHarness.shared verifyAliveWithCompletion:^(BOOL alive) {
            if (!alive) weakSelf.pageLoaded = NO;
        }];
    }
}

#pragma mark - Actions

- (void)reloadWebView {
    if (OMHHarness.shared.state == OMHHarnessStateReady)
        [self loadHarness];
    else
        [OMHHarness.shared start];
}

- (void)confirmRestart {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restart the harness?"
                                                                   message:@"Running agent turns are interrupted; sessions are kept on disk."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restart" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [OMHHarness.shared restart];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmRepair {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Repair the Linux environment?"
        message:@"On the next launch OpenMind Harness will reinstall its bundled Linux system and migrate your sessions, credentials and workspace. The current system is kept until migration succeeds."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Repair on Next Launch" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [OMHRootUpgrader.shared scheduleRepairOnNextLaunch];
        [OMHHarness.shared.log append:@"[openmind-harness] Linux environment repair scheduled for next launch"];
        UIAlertController *done = [UIAlertController alertControllerWithTitle:@"Repair scheduled"
            message:@"Close OpenMind Harness and open it again. Your user data will be migrated after the fresh system boots."
            preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:done animated:YES completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentTerminal {
    // iSH's terminal offers to "install the built-in APK" on first use; our
    // guest ships with apk already, so skip that startup message.
    [NSUserDefaults.standardUserDefaults setInteger:1 forKey:@"Skip Startup Message"];
    if (self.terminalVC == nil) {
        UIStoryboard *sb = [UIStoryboard storyboardWithName:@"Terminal" bundle:nil];
        TerminalViewController *vc = [sb instantiateInitialViewController];
        vc.sceneSession = nil; // never let a shell exit tear down our scene
        vc.modalPresentationStyle = UIModalPresentationPageSheet;
        [vc startNewSession];
        self.terminalVC = vc;
    }
    if (self.terminalVC.presentingViewController != nil)
        return;
    [self presentViewController:self.terminalVC animated:YES completion:nil];
}

- (void)presentLog {
    OMHLogViewController *vc = [[OMHLogViewController alloc] initWithLog:OMHHarness.shared.log];
    [self showInspector:vc key:@"log"];
}

- (void)presentCapabilities {
    OMHCapabilitiesViewController *vc = [OMHCapabilitiesViewController new];
    [self showInspector:vc key:@"capabilities"];
}

- (void)presentActivity {
    OMHActivityViewController *vc = [OMHActivityViewController new];
    [self showInspector:vc key:@"activity"];
}

- (void)presentAbout {
    OMHHarness *h = OMHHarness.shared;
    NSString *version = [NSString stringWithFormat:@"%@ (%@)",
                         [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
                         [NSBundle.mainBundle objectForInfoDictionaryKey:(NSString *) kCFBundleVersionKey]];
    NSString *message = [NSString stringWithFormat:
                         @"OpenMind Harness %@\n\nOpenCode running in an Alpine Linux guest (iSH ARM64 emulator) inside this app.\n\nServer: %@\nState: %@\nStartup: %.1fs · restarts: %lu\n\n%@",
                         version, h.baseURL.absoluteString ?: @"–", OMHHarnessStateName(h.state), h.lastStartupDuration,
                         (unsigned long) h.restartCount, OMHStartupMetrics.shared.summary];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"About OpenMind Harness" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - A turn that did not survive the background

/// Long enough to read once, and it goes away on the next status update anyway.
static const NSTimeInterval kInterruptedNoticeVisible = 8;

- (void)turnWasInterrupted:(NSNotification *)note {
    // The bar, not an alert: the user came back to carry on, and a dialog to
    // dismiss first would be in the way of the thing they returned for.
    BOOL ready = [note.userInfo[OMHTurnRecoveryStatusKey] isEqualToString:@"server-ready"];
    self.titleLabel.text = ready ? @"OpenMind Harness · checking interrupted turn" : @"OpenMind Harness · turn interrupted";
    self.titleLabel.accessibilityLabel =
        ready ? @"A turn was interrupted while OpenMind Harness was away. The server is available; check the conversation before retrying."
              : @"A turn was interrupted while OpenMind Harness was away and the server is unavailable. OpenMind Harness is recovering it.";
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applyHarnessState) object:nil];
    [self performSelector:@selector(applyHarnessState) withObject:nil afterDelay:kInterruptedNoticeVisible];
}

#pragma mark - Capability activity indicator

/// Long enough to notice out of the corner of an eye, short enough that it
/// means "just now" rather than "at some point today".
static const NSTimeInterval kActivityIndicatorVisible = 6;

- (void)observeActivity {
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(activityChanged)
                                               name:OMHActivityLogDidChangeNotification object:nil];
}

- (void)activityChanged {
    OMHActivityEntry *latest = OMHActivityLog.shared.entries.firstObject;
    // Only device capabilities light it up. A shell command in the guest is
    // recorded, but it is not the thing the user needs to be told about.
    if (latest.source != OMHActivitySourceCapability || -latest.date.timeIntervalSinceNow > kActivityIndicatorVisible)
        return;
    [self showActivityIndicatorFor:latest];
}

- (void)showActivityIndicatorFor:(OMHActivityEntry *)entry {
    self.activityIndicatorButton.tintColor = entry.outcome == OMHActivityOutcomeOK
        ? UIColor.systemOrangeColor : UIColor.systemGrayColor;
    self.activityIndicatorButton.accessibilityLabel =
        [NSString stringWithFormat:@"%@ used %@", entry.name, OMHActivityOutcomeName(entry.outcome)];
    if (self.activityIndicatorButton.isHidden) {
        self.activityIndicatorButton.hidden = NO;
        self.activityIndicatorButton.alpha = 0;
        [UIView animateWithDuration:0.2 animations:^{ self.activityIndicatorButton.alpha = 1; }];
    }
    // Each new call restarts the clock, so a busy stretch stays lit throughout
    // rather than flickering once per call.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideActivityIndicator) object:nil];
    [self performSelector:@selector(hideActivityIndicator) withObject:nil afterDelay:kActivityIndicatorVisible];
}

- (void)hideActivityIndicator {
    [UIView animateWithDuration:0.3 animations:^{
        self.activityIndicatorButton.alpha = 0;
    } completion:^(BOOL finished) {
        self.activityIndicatorButton.hidden = YES;
    }];
}

#pragma mark - Keyboard shortcuts

- (NSArray<UIKeyCommand *> *)keyCommands {
    UIKeyCommand *reload = [UIKeyCommand keyCommandWithInput:@"r" modifierFlags:UIKeyModifierCommand action:@selector(reloadWebView)];
    reload.discoverabilityTitle = @"Reload";
    UIKeyCommand *terminal = [UIKeyCommand keyCommandWithInput:@"t" modifierFlags:UIKeyModifierCommand | UIKeyModifierShift action:@selector(presentTerminal)];
    terminal.discoverabilityTitle = @"Terminal";
    return @[reload, terminal];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

#pragma mark - WKNavigationDelegate

- (BOOL)isHarnessURL:(NSURL *)url {
    NSURL *base = OMHHarness.shared.baseURL;
    return base != nil && [url.host isEqualToString:base.host] && [url.port isEqual:base.port ?: @80];
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    if (url == nil || [self isHarnessURL:url] || [url.scheme isEqualToString:@"about"] || [url.scheme isEqualToString:@"blob"] || [url.scheme isEqualToString:@"data"]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    // Anything leaving the local server (docs links, OAuth pages) opens in Safari.
    if ([url.scheme hasPrefix:@"http"] || [url.scheme isEqualToString:@"mailto"]) {
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)response decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    if (!response.canShowMIMEType) {
        decisionHandler(WKNavigationResponsePolicyDownload);
        return;
    }
    if ([response.response isKindOfClass:NSHTTPURLResponse.class]) {
        NSString *disposition = ((NSHTTPURLResponse *) response.response).allHeaderFields[@"Content-Disposition"];
        if ([disposition.lowercaseString hasPrefix:@"attachment"]) {
            decisionHandler(WKNavigationResponsePolicyDownload);
            return;
        }
    }
    decisionHandler(WKNavigationResponsePolicyAllow);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.pageLoaded = YES;
    [OMHHarness.shared.log append:[NSString stringWithFormat:@"[perf] web interface loaded (harness %.3fs)", OMHHarness.shared.lastStartupDuration]];
    [OMHStartupMetrics.shared mark:@"web_ready"];
    [self.overlay hide];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self handleLoadError:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self handleLoadError:error];
}

- (void)handleLoadError:(NSError *)error {
    if (error.code == NSURLErrorCancelled)
        return;
    self.pageLoaded = NO;
    NSUInteger generation = self.pageLoadGeneration;
    [OMHHarness.shared.log append:[NSString stringWithFormat:@"[openmind-harness] page load failed: %@", error.localizedDescription]];
    [self.overlay showStarting:@"Waiting for the harness…"];
    // The server was answering a moment ago; give it a beat and retry, and
    // let the harness restart it if it is really gone.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (self == nil || self.pageLoaded || generation != self.pageLoadGeneration)
            return;
        [OMHHarness.shared verifyAliveWithCompletion:^(BOOL alive) {
            if (alive) [self loadHarness];
        }];
    });
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    [OMHHarness.shared.log append:@"[openmind-harness] web content process terminated; reloading"];
    self.pageLoaded = NO;
    if (OMHHarness.shared.state == OMHHarnessStateReady)
        [self loadHarness];
}

- (void)webView:(WKWebView *)webView navigationResponse:(WKNavigationResponse *)navigationResponse didBecomeDownload:(WKDownload *)download {
    download.delegate = self;
}

- (void)webView:(WKWebView *)webView navigationAction:(WKNavigationAction *)navigationAction didBecomeDownload:(WKDownload *)download {
    download.delegate = self;
}

#pragma mark - WKDownloadDelegate

- (void)download:(WKDownload *)download decideDestinationUsingResponse:(NSURLResponse *)response suggestedFilename:(NSString *)suggestedFilename completionHandler:(void (^)(NSURL * _Nullable))completionHandler {
    NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [docs URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *name = suggestedFilename.length ? suggestedFilename : @"download";
    NSURL *dest = [dir URLByAppendingPathComponent:name];
    NSUInteger n = 1;
    while ([NSFileManager.defaultManager fileExistsAtPath:dest.path]) {
        NSString *stem = name.stringByDeletingPathExtension, *ext = name.pathExtension;
        NSString *alt = ext.length ? [NSString stringWithFormat:@"%@-%lu.%@", stem, (unsigned long) n++, ext] : [NSString stringWithFormat:@"%@-%lu", stem, (unsigned long) n++];
        dest = [dir URLByAppendingPathComponent:alt];
    }
    self.downloadDestinations[[NSValue valueWithNonretainedObject:download]] = dest;
    completionHandler(dest);
}

- (void)downloadDidFinish:(WKDownload *)download {
    NSValue *key = [NSValue valueWithNonretainedObject:download];
    NSURL *dest = self.downloadDestinations[key];
    [self.downloadDestinations removeObjectForKey:key];
    if (dest == nil)
        return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[dest] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.menuButton;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)download:(WKDownload *)download didFailWithError:(NSError *)error resumeData:(NSData *)resumeData {
    [self.downloadDestinations removeObjectForKey:[NSValue valueWithNonretainedObject:download]];
    [OMHHarness.shared.log append:[NSString stringWithFormat:@"[openmind-harness] download failed: %@", error.localizedDescription]];
}

#pragma mark - WKUIDelegate

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures {
    // target=_blank: keep local URLs in place, hand external ones to Safari.
    NSURL *url = navigationAction.request.URL;
    if (url == nil)
        return nil;
    if ([self isHarnessURL:url])
        [webView loadRequest:navigationAction.request];
    else
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    return nil;
}

- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { completionHandler(); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { completionHandler(NO); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { completionHandler(YES); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSString * _Nullable))completionHandler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:prompt preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.text = defaultText; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { completionHandler(nil); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { completionHandler(alert.textFields.firstObject.text); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Status bar

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

@end

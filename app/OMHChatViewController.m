//
//  OMHChatViewController.m
//  OMH
//
//  Native chat tab for the OpenUI migration. The harness backend does NOT
//  persist chat history (handleChat is stateless; the React frontend keeps
//  it in memory only), so the conversation is persisted locally in
//  NSUserDefaults under @"omh.chat.history.v1", capped at the last 50
//  messages. A failed send is never appended to history, matching the
//  React frontend: a failed request does not enter conversation context.
//

#import "OMHChatViewController.h"
#import "OMHApiClient.h"
#import "OMHTheme.h"

static NSString * const OMHChatHistoryDefaultsKey = @"omh.chat.history.v1";
static const NSUInteger OMHChatMaxStoredMessages = 50;

@interface OMHChatViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>

@property (nonatomic, strong) OMHApiClient *apiClient;

@property (nonatomic, copy) NSArray<OMHChatProvider *> *providers;
@property (nonatomic, strong, nullable) OMHChatProvider *selectedProvider;
@property (nonatomic, strong) NSMutableArray<NSDictionary<NSString *, NSString *> *> *messages;
@property (nonatomic, assign) BOOL sending;
@property (nonatomic, assign) BOOL chatUnavailable;
@property (nonatomic, assign) BOOL providersLoading;

@property (nonatomic, strong) UIButton *providerButton;
@property (nonatomic, strong) UIButton *startChatButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UITextField *composerField;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;

@end

@implementation OMHChatViewController

#pragma mark - Init

- (instancetype)initWithApiClient:(OMHApiClient *)client {
    if (!client) {
        return nil;
    }
    if (self = [super initWithNibName:nil bundle:nil]) {
        _apiClient = client;
        _providers = @[];
        _messages = [NSMutableArray array];
        self.title = @"Chat";
    }
    return self;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [OMHTheme backgroundColor];
    self.view.accessibilityIdentifier = @"omh.native.chat";

    [self loadHistory];
    [self buildViews];
    [self updateProviderButton];
    [self updateSendState];
    [self fetchProviders];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.providers.count == 0) {
        [self fetchProviders];
    }
}

#pragma mark - Public

- (void)reload {
    [self fetchProviders];
}

#pragma mark - Layout

- (void)buildViews {
    // Top row: provider selector + New chat.
    UIButton *providerButton = [UIButton buttonWithType:UIButtonTypeSystem];
    providerButton.translatesAutoresizingMaskIntoConstraints = NO;
    providerButton.backgroundColor = [OMHTheme surfaceColor];
    providerButton.layer.cornerRadius = 10;
    providerButton.layer.borderWidth = 1;
    providerButton.layer.borderColor = [OMHTheme borderColor].CGColor;
    providerButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    providerButton.contentEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 16);
    [providerButton setTitleColor:[OMHTheme textColor] forState:UIControlStateNormal];
    providerButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    providerButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    providerButton.titleLabel.minimumScaleFactor = 0.7;
    providerButton.showsMenuAsPrimaryAction = YES;
    providerButton.accessibilityIdentifier = @"omh.native.chat.provider";
    self.providerButton = providerButton;

    UIButton *startChatButton = [UIButton buttonWithType:UIButtonTypeSystem];
    startChatButton.translatesAutoresizingMaskIntoConstraints = NO;
    startChatButton.backgroundColor = [OMHTheme surfaceColor];
    startChatButton.layer.cornerRadius = 10;
    startChatButton.layer.borderWidth = 1;
    startChatButton.layer.borderColor = [OMHTheme borderColor].CGColor;
    [startChatButton setTitle:@"New chat" forState:UIControlStateNormal];
    [startChatButton setTitleColor:[OMHTheme accentLightColor] forState:UIControlStateNormal];
    startChatButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    startChatButton.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    [startChatButton addTarget:self action:@selector(startChatTapped) forControlEvents:UIControlEventTouchUpInside];
    self.startChatButton = startChatButton;

    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:@[providerButton, startChatButton]];
    topRow.translatesAutoresizingMaskIntoConstraints = NO;
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.spacing = 8;
    topRow.alignment = UIStackViewAlignmentFill;
    [self.view addSubview:topRow];

    UILabel *statusLabel = [[UILabel alloc] init];
    statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    statusLabel.font = [UIFont systemFontOfSize:13];
    statusLabel.textColor = [OMHTheme mutedTextColor];
    statusLabel.numberOfLines = 0;
    statusLabel.text = @"Choose a provider to start chatting.";
    statusLabel.accessibilityIdentifier = @"omh.native.chat.status";
    self.statusLabel = statusLabel;
    [self.view addSubview:statusLabel];

    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tableView.translatesAutoresizingMaskIntoConstraints = NO;
    tableView.backgroundColor = [OMHTheme backgroundColor];
    tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    tableView.rowHeight = UITableViewAutomaticDimension;
    tableView.estimatedRowHeight = 60;
    tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.accessibilityIdentifier = @"omh.native.chat.messages";
    self.tableView = tableView;
    [self.view addSubview:tableView];

    // Composer: text field + Send + spinner, above the keyboard.
    UIView *composerContainer = [[UIView alloc] init];
    composerContainer.translatesAutoresizingMaskIntoConstraints = NO;
    composerContainer.backgroundColor = [OMHTheme surfaceColor];
    composerContainer.layer.borderColor = [OMHTheme borderColor].CGColor;
    composerContainer.layer.borderWidth = 1;
    composerContainer.layer.cornerRadius = 12;
    [self.view addSubview:composerContainer];

    UITextField *composerField = [[UITextField alloc] init];
    composerField.translatesAutoresizingMaskIntoConstraints = NO;
    composerField.backgroundColor = [OMHTheme surfaceRaisedColor];
    composerField.layer.cornerRadius = 10;
    composerField.textColor = [OMHTheme textColor];
    composerField.font = [UIFont systemFontOfSize:17];
    composerField.placeholder = @"Message";
    composerField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Message"
                                                                          attributes:@{NSForegroundColorAttributeName: [OMHTheme mutedTextColor]}];
    composerField.returnKeyType = UIReturnKeySend;
    composerField.delegate = self;
    composerField.accessibilityIdentifier = @"omh.native.chat.composer";
    self.composerField = composerField;
    [composerContainer addSubview:composerField];

    UIButton *sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    sendButton.backgroundColor = [OMHTheme accentColor];
    sendButton.layer.cornerRadius = 10;
    [sendButton setTitle:@"Send" forState:UIControlStateNormal];
    [sendButton setTitleColor:[OMHTheme textColor] forState:UIControlStateNormal];
    sendButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    sendButton.accessibilityIdentifier = @"omh.native.chat.send";
    [sendButton addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
    self.sendButton = sendButton;
    [composerContainer addSubview:sendButton];

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    spinner.color = [OMHTheme accentLightColor];
    spinner.hidesWhenStopped = YES;
    self.spinner = spinner;
    [composerContainer addSubview:spinner];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [topRow.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:12],
        [topRow.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:16],
        [topRow.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-16],
        [providerButton.heightAnchor constraintEqualToConstant:44],
        [startChatButton.heightAnchor constraintEqualToConstant:44],
        [startChatButton.widthAnchor constraintGreaterThanOrEqualToConstant:88],

        [statusLabel.topAnchor constraintEqualToAnchor:topRow.bottomAnchor constant:8],
        [statusLabel.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:16],
        [statusLabel.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-16],

        [tableView.topAnchor constraintEqualToAnchor:statusLabel.bottomAnchor constant:8],
        [tableView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor],
        [tableView.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor],
        [tableView.bottomAnchor constraintEqualToAnchor:composerContainer.topAnchor constant:-8],

        [composerContainer.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:12],
        [composerContainer.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-12],
        [composerContainer.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-8],

        [composerField.topAnchor constraintEqualToAnchor:composerContainer.topAnchor constant:8],
        [composerField.leadingAnchor constraintEqualToAnchor:composerContainer.leadingAnchor constant:8],
        [composerField.bottomAnchor constraintEqualToAnchor:composerContainer.bottomAnchor constant:-8],
        [composerField.heightAnchor constraintEqualToConstant:44],

        [sendButton.leadingAnchor constraintEqualToAnchor:composerField.trailingAnchor constant:8],
        [sendButton.centerYAnchor constraintEqualToAnchor:composerField.centerYAnchor],
        [sendButton.widthAnchor constraintEqualToConstant:64],
        [sendButton.heightAnchor constraintEqualToConstant:44],

        [spinner.leadingAnchor constraintEqualToAnchor:sendButton.trailingAnchor constant:4],
        [spinner.trailingAnchor constraintEqualToAnchor:composerContainer.trailingAnchor constant:-8],
        [spinner.centerYAnchor constraintEqualToAnchor:composerField.centerYAnchor],
        [spinner.widthAnchor constraintEqualToConstant:24],
    ]];
}

#pragma mark - Providers

- (void)fetchProviders {
    if (self.providersLoading) {
        return;
    }
    self.providersLoading = YES;
    __weak typeof(self) weakSelf = self;
    [self.apiClient fetchChatProvidersWithCompletion:^(NSArray<OMHChatProvider *> * _Nullable providers, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf.providersLoading = NO;
        if (error) {
            [strongSelf handleProvidersError:error];
            return;
        }
        strongSelf.providers = providers ?: @[];
        strongSelf.chatUnavailable = NO;
        [strongSelf restoreSelectedProvider];
        BOOL anyAvailable = NO;
        for (OMHChatProvider *provider in strongSelf.providers) {
            if (provider.available) {
                anyAvailable = YES;
                break;
            }
        }
        if (!anyAvailable) {
            strongSelf.statusLabel.text = @"No provider is configured — save a key in Settings, then come back.";
        } else if (!strongSelf.selectedProvider) {
            strongSelf.statusLabel.text = @"Choose a provider to start chatting.";
        } else {
            strongSelf.statusLabel.text = @"";
        }
        [strongSelf updateProviderButton];
        [strongSelf updateSendState];
    }];
}

- (void)handleProvidersError:(NSError *)error {
    NSNumber *statusCode = error.userInfo[OMHApiHTTPStatusCodeKey];
    if (error.code == OMHApiErrorCodeUnavailable || [statusCode integerValue] == 404) {
        // GET /api/chat 404: this harness version predates the chat endpoint.
        self.providers = @[];
        self.selectedProvider = nil;
        self.chatUnavailable = YES;
        self.statusLabel.text = @"Chat is not available on this harness version — update the harness to enable chat.";
    } else {
        self.statusLabel.text = error.localizedDescription ?: @"Could not load providers.";
    }
    [self updateProviderButton];
    [self updateSendState];
}

- (void)restoreSelectedProvider {
    NSString *savedID = self.selectedProvider.providerId ?: [[NSUserDefaults standardUserDefaults] stringForKey:@"omh.chat.selectedProvider.v1"];
    self.selectedProvider = nil;
    if (!savedID.length) return;
    for (OMHChatProvider *provider in self.providers) {
        if ([provider.providerId isEqualToString:savedID] && provider.available) {
            self.selectedProvider = provider;
            return;
        }
    }
}

- (void)updateProviderButton {
    NSString *title = self.selectedProvider ? self.selectedProvider.label : @"Choose provider";
    [self.providerButton setTitle:(title.length ? title : @"Choose provider") forState:UIControlStateNormal];

    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    for (OMHChatProvider *provider in self.providers) {
        NSString *label = provider.label.length ? provider.label : (provider.providerId.length ? provider.providerId : @"Provider");
        NSString *actionTitle;
        if (provider.available) {
            actionTitle = provider.model.length ? [NSString stringWithFormat:@"%@ — %@", label, provider.model] : label;
        } else {
            actionTitle = [NSString stringWithFormat:@"%@ (no key)", label];
        }
        UIMenuElementState state = (self.selectedProvider &&
                                     [provider.providerId isEqualToString:self.selectedProvider.providerId])
            ? UIMenuElementStateOn : UIMenuElementStateOff;
        UIAction *action = [UIAction actionWithTitle:actionTitle
                                               image:nil
                                          identifier:nil
                                             handler:^(__kindof UIAction * _Nonnull action) {
            __unused UIAction *unusedAction = action;
            [weakSelf selectProvider:provider];
        }];
        action.state = state;
        [actions addObject:action];
    }
    self.providerButton.menu = [UIMenu menuWithTitle:@"" children:actions];
}

- (void)selectProvider:(OMHChatProvider *)provider {
    if (!provider.available) {
        self.statusLabel.text = @"Configure this provider in Settings first.";
        return;
    }
    self.selectedProvider = provider;
    [[NSUserDefaults standardUserDefaults] setObject:provider.providerId forKey:@"omh.chat.selectedProvider.v1"];
    self.statusLabel.text = @"";
    [self updateProviderButton];
    [self updateSendState];
}

- (void)updateSendState {
    BOOL composerDisabled = self.chatUnavailable;
    self.composerField.enabled = !composerDisabled;
    self.sendButton.enabled = (self.selectedProvider.available && !self.sending && !composerDisabled);
}

#pragma mark - History persistence

- (void)loadHistory {
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:OMHChatHistoryDefaultsKey];
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *loaded = [NSMutableArray array];
    for (id entry in stored ?: @[]) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *role = entry[@"role"];
        NSString *content = entry[@"content"];
        if (![role isKindOfClass:[NSString class]] || ![content isKindOfClass:[NSString class]]) {
            continue;
        }
        if (!([role isEqualToString:@"user"] || [role isEqualToString:@"assistant"])) {
            continue;
        }
        [loaded addObject:@{@"role": role, @"content": content}];
    }
    if (loaded.count > OMHChatMaxStoredMessages) {
        loaded = [[loaded subarrayWithRange:NSMakeRange(loaded.count - OMHChatMaxStoredMessages, OMHChatMaxStoredMessages)] mutableCopy];
    }
    self.messages = loaded;
}

- (void)persistHistory {
    if (self.messages.count > OMHChatMaxStoredMessages) {
        [self.messages removeObjectsInRange:NSMakeRange(0, self.messages.count - OMHChatMaxStoredMessages)];
    }
    [[NSUserDefaults standardUserDefaults] setObject:[self.messages copy] forKey:OMHChatHistoryDefaultsKey];
}

- (void)startChatTapped {
    [self.messages removeAllObjects];
    [self persistHistory];
    [self.tableView reloadData];
    self.statusLabel.text = @"Started a new chat.";
}

#pragma mark - Sending

- (void)sendTapped {
    if (self.sending || !self.selectedProvider || self.chatUnavailable) {
        return;
    }
    NSString *text = [self.composerField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) {
        return;
    }

    // NOTE: The backend is NON-STREAMING (one request, one 25s-timeout
    // response). True streaming needs a backend route that does not exist
    // yet — do not fake streaming here.
    self.sending = YES;
    [self.spinner startAnimating];
    [self updateSendState];
    self.statusLabel.text = @"";

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *toSend = [self.messages mutableCopy];
    [toSend addObject:@{@"role": @"user", @"content": text}];

    __weak typeof(self) weakSelf = self;
    [self.apiClient sendChatWithProvider:self.selectedProvider.providerId
                                messages:[toSend copy]
                              completion:^(NSString * _Nullable reply, NSString * _Nullable model, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        // The client already calls completions on the main queue; stay on
        // main for every UI update regardless.
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.sending = NO;
            [strongSelf.spinner stopAnimating];
            [strongSelf updateSendState];

            if (error) {
                // Failed request does not enter conversation context: nothing
                // is appended to stored history and the typed text stays in
                // the composer so the user can retry.
                NSNumber *statusCode = error.userInfo[OMHApiHTTPStatusCodeKey];
                if (error.code == OMHApiErrorCodeNotConfigured || [statusCode integerValue] == 503) {
                    strongSelf.statusLabel.text = @"Selected provider is not configured on the server.";
                } else {
                    strongSelf.statusLabel.text = error.localizedDescription ?: @"The chat request failed.";
                }
                return;
            }
            if (reply.length == 0) {
                strongSelf.statusLabel.text = @"The server returned an empty reply.";
                return;
            }
            [strongSelf.messages addObject:@{@"role": @"user", @"content": text}];
            [strongSelf.messages addObject:@{@"role": @"assistant", @"content": reply}];
            [strongSelf persistHistory];
            [strongSelf.tableView reloadData];
            [strongSelf scrollToBottomAnimated:YES];
            strongSelf.composerField.text = @"";
            strongSelf.statusLabel.text = @"";
            __unused NSString *unusedModel = model;
        });
    }];
}

#pragma mark - Table view

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.messages.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary<NSString *, NSString *> *message = self.messages[indexPath.row];
    BOOL isUser = [message[@"role"] isEqualToString:@"user"];
    NSString *reuseId = isUser ? @"OMHChatUserCell" : @"OMHChatAssistantCell";

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseId];
    }
    cell.backgroundColor = UIColor.clearColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    for (UIView *subview in [cell.contentView.subviews copy]) {
        [subview removeFromSuperview];
    }

    UIView *bubble = [[UIView alloc] init];
    bubble.translatesAutoresizingMaskIntoConstraints = NO;
    bubble.backgroundColor = isUser ? [OMHTheme accentColor] : [OMHTheme surfaceColor];
    bubble.layer.cornerRadius = 16;
    bubble.layer.masksToBounds = YES;
    [cell.contentView addSubview:bubble];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:17];
    label.textColor = [OMHTheme textColor];
    label.text = message[@"content"] ?: @"";
    [bubble addSubview:label];

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [bubble.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:6],
        [bubble.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-6],
        [bubble.widthAnchor constraintLessThanOrEqualToAnchor:cell.contentView.widthAnchor multiplier:0.75],
        [label.topAnchor constraintEqualToAnchor:bubble.topAnchor constant:8],
        [label.bottomAnchor constraintEqualToAnchor:bubble.bottomAnchor constant:-8],
        [label.leadingAnchor constraintEqualToAnchor:bubble.leadingAnchor constant:12],
        [label.trailingAnchor constraintEqualToAnchor:bubble.trailingAnchor constant:-12],
    ]];
    if (isUser) {
        [constraints addObject:[bubble.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16]];
        [constraints addObject:[bubble.leadingAnchor constraintGreaterThanOrEqualToAnchor:cell.contentView.leadingAnchor constant:64]];
    } else {
        [constraints addObject:[bubble.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16]];
        [constraints addObject:[bubble.trailingAnchor constraintLessThanOrEqualToAnchor:cell.contentView.trailingAnchor constant:-64]];
    }
    [NSLayoutConstraint activateConstraints:constraints];

    return cell;
}

- (void)scrollToBottomAnimated:(BOOL)animated {
    NSInteger count = self.messages.count;
    if (count == 0) {
        return;
    }
    NSIndexPath *last = [NSIndexPath indexPathForRow:(count - 1) inSection:0];
    [self.tableView scrollToRowAtIndexPath:last atScrollPosition:UITableViewScrollPositionBottom animated:animated];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self sendTapped];
    return YES;
}

@end

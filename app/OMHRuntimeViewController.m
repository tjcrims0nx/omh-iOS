//
//  OMHRuntimeViewController.m
//  OMH
//
//  Native Runtime tab. Reads GET /api/state through OMHApiClient and renders
//  one table section per group: Status, Providers, Tasks, Schedules, Plugins,
//  Skills, Evidence. Evidence status is preferentially fetched fresh from
//  GET /api/plugins/omjb, falling back to state[@"evidenceMcp"] when that
//  endpoint is absent or errors.
//
//  Actions offered here are the CSRF-only ones. The privileged actions
//  (schedules Resume, plugins Enable, skills Accept, evidence Enable and
//  connectors Verify) need the dashboard admin token, which the iOS guest
//  does not set, so they return 403 on iOS: they are never offered as
//  buttons, and rows that would need them say "requires admin" instead.
//  After a successful action the state (and evidence status) is re-fetched;
//  on failure the error is shown in the status label and the old data stays.
//

#import "OMHRuntimeViewController.h"
#import "OMHApiClient.h"
#import "OMHTheme.h"

static const NSInteger OMHRuntimeSectionStatus = 0;
static const NSInteger OMHRuntimeSectionProviders = 1;
static const NSInteger OMHRuntimeSectionTasks = 2;
static const NSInteger OMHRuntimeSectionSchedules = 3;
static const NSInteger OMHRuntimeSectionPlugins = 4;
static const NSInteger OMHRuntimeSectionSkills = 5;
static const NSInteger OMHRuntimeSectionEvidence = 6;
static const NSInteger OMHRuntimeSectionCount = 7;

static NSString * const OMHRuntimeCellIdentifier = @"OMHRuntimeCell";

@interface OMHRuntimeViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) OMHApiClient *apiClient;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;

@property (nonatomic, copy, nullable) NSDictionary *state;
@property (nonatomic, copy, nullable) NSDictionary *evidenceStatus;
@property (nonatomic, assign) BOOL evidenceUnavailable; // /api/plugins/omjb 404: harness predates it
@property (nonatomic, assign) BOOL loading;

@end

@implementation OMHRuntimeViewController

#pragma mark - Init / lifecycle

- (instancetype)initWithApiClient:(OMHApiClient *)client {
    if (self = [super initWithNibName:nil bundle:nil]) {
        _apiClient = client;
        self.title = @"Runtime";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.accessibilityIdentifier = @"omh.native.runtime";
    self.view.backgroundColor = OMHTheme.backgroundColor;

    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectZero
                                                          style:UITableViewStyleInsetGrouped];
    tableView.translatesAutoresizingMaskIntoConstraints = NO;
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.backgroundColor = OMHTheme.backgroundColor;
    tableView.accessibilityIdentifier = @"omh.native.runtime.list";
    // No registerClass: cells are created below with UITableViewCellStyleSubtitle,
    // which registerClass cannot produce (it yields the Default style, whose
    // detailTextLabel is nil and would swallow all detail text).
    [self.view addSubview:tableView];
    self.tableView = tableView;
    [NSLayoutConstraint activateConstraints:@[
        [tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [tableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [tableView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [tableView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
    ]];

    // Header: status label (errors and progress live here) + Refresh
    // button + spinner. Refresh lives in the header, not the navigation
    // item: this controller is a child of the dashboard container (tab bar
    // on iPhone, sidebar detail on iPad), so its navigation item is never
    // displayed and a bar button item there would be invisible.
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    headerView.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, headerView.bounds.size.width - 136, 44)];
    statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    statusLabel.textColor = OMHTheme.mutedTextColor;
    statusLabel.numberOfLines = 0;
    statusLabel.accessibilityIdentifier = @"omh.native.runtime.status";
    [headerView addSubview:statusLabel];
    self.statusLabel = statusLabel;

    UIButton *refreshButton = [UIButton buttonWithType:UIButtonTypeSystem];
    refreshButton.frame = CGRectMake(headerView.bounds.size.width - 120, 6, 72, 32);
    refreshButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [refreshButton setTitle:@"Refresh" forState:UIControlStateNormal];
    [refreshButton setTitleColor:OMHTheme.accentColor forState:UIControlStateNormal];
    refreshButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    refreshButton.accessibilityIdentifier = @"omh.native.runtime.refresh";
    [refreshButton addTarget:self action:@selector(reload) forControlEvents:UIControlEventTouchUpInside];
    [headerView addSubview:refreshButton];

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.frame = CGRectMake(headerView.bounds.size.width - 44, 6, 32, 32);
    spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    spinner.color = OMHTheme.accentColor;
    spinner.hidesWhenStopped = YES;
    [headerView addSubview:spinner];
    self.spinner = spinner;

    tableView.tableHeaderView = headerView;
}

// The table header is built in viewDidLoad, when the view bounds may
// still be zero, and a tableHeaderView does not resize itself when the
// table does — re-fit it (and re-flow its autoresizing subviews) whenever
// the layout changes, e.g. on rotation or Stage Manager resize.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = self.tableView.tableHeaderView;
    if (header != nil && header.frame.size.width != self.tableView.bounds.size.width) {
        header.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, 44);
        self.tableView.tableHeaderView = header;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.state == nil && !self.loading) {
        [self reload];
    }
}

#pragma mark - Fetching

- (void)reload {
    if (self.loading || self.apiClient == nil) {
        return;
    }
    self.loading = YES;
    [self.spinner startAnimating];
    [self setStatusText:@"Loading…" error:NO];

    __weak typeof(self) weakSelf = self;
    [self.apiClient fetchStateWithCompletion:^(NSDictionary * _Nullable state, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (error != nil) {
            // Keep any previous data; with no previous data the table stays empty.
            strongSelf.loading = NO;
            [strongSelf.spinner stopAnimating];
            [strongSelf setStatusText:[strongSelf errorMessageForError:error] error:YES];
            [strongSelf.tableView reloadData];
            return;
        }
        strongSelf.state = state ?: @{};
        [strongSelf setStatusText:@"" error:NO];
        [strongSelf.apiClient fetchEvidenceStatusWithCompletion:^(NSDictionary * _Nullable status, NSError * _Nullable evidenceError) {
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (strongSelf2 == nil) {
                return;
            }
            strongSelf2.loading = NO;
            [strongSelf2.spinner stopAnimating];
            if (evidenceError != nil) {
                if ([evidenceError.domain isEqualToString:OMHApiClientErrorDomain] &&
                    evidenceError.code == OMHApiErrorCodeUnavailable) {
                    // The pinned harness predates /api/plugins/omjb: not an
                    // error, just a harness without the evidence endpoint.
                    strongSelf2.evidenceUnavailable = YES;
                    strongSelf2.evidenceStatus = nil;
                } else {
                    strongSelf2.evidenceUnavailable = NO;
                    // Fall back to whatever state carried, if anything.
                    strongSelf2.evidenceStatus = [strongSelf2 dictionaryFrom:strongSelf2.state[@"evidenceMcp"]];
                    if (strongSelf2.evidenceStatus == nil) {
                        [strongSelf2 setStatusText:[strongSelf2 errorMessageForError:evidenceError] error:YES];
                    }
                }
            } else {
                strongSelf2.evidenceUnavailable = NO;
                strongSelf2.evidenceStatus = status;
            }
            [strongSelf2.tableView reloadData];
        }];
    }];
}

#pragma mark - Actions

- (void)actionButtonTapped:(UIButton *)sender {
    if (self.loading) {
        return;
    }
    NSInteger section = sender.tag / 1000;
    NSInteger row = sender.tag % 1000;
    NSArray<NSDictionary *> *rows = [self rowsForSection:section];
    if (row < 0 || row >= (NSInteger)rows.count) {
        return;
    }
    NSDictionary *rowDict = rows[(NSUInteger)row];
    NSString *action = [self stringFrom:rowDict[@"action"]];
    NSString *identifier = [self stringFrom:rowDict[@"identifier"]];
    if (action == nil) {
        return;
    }

    NSString *path = nil;
    NSDictionary *body = nil;
    if ([action isEqualToString:@"taskCancel"]) {
        if (identifier == nil) return;
        path = @"/api/tasks/cancel";
        body = @{@"id": identifier};
    } else if ([action isEqualToString:@"taskRetry"]) {
        if (identifier == nil) return;
        path = @"/api/tasks/retry";
        body = @{@"id": identifier};
    } else if ([action isEqualToString:@"schedulePause"]) {
        if (identifier == nil) return;
        path = @"/api/schedules/pause";
        body = @{@"id": identifier};
    } else if ([action isEqualToString:@"pluginDisable"]) {
        if (identifier == nil) return;
        path = @"/api/plugins/disable";
        body = @{@"name": identifier};
    } else if ([action isEqualToString:@"skillReject"]) {
        if (identifier == nil) return;
        path = @"/api/skills/reject";
        body = @{@"id": identifier};
    } else if ([action isEqualToString:@"evidenceRetry"]) {
        path = @"/api/plugins/omjb/retry";
        body = @{};
    } else if ([action isEqualToString:@"evidenceDisable"]) {
        path = @"/api/plugins/omjb/disable";
        body = @{};
    } else {
        return;
    }

    sender.enabled = NO;
    [self setStatusText:@"Working…" error:NO];
    __weak typeof(self) weakSelf = self;
    [self.apiClient performAction:path body:body completion:^(NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (error != nil) {
            [strongSelf setStatusText:[strongSelf errorMessageForError:error] error:YES];
            [strongSelf.tableView reloadData]; // restores the tapped button
            return;
        }
        [strongSelf setStatusText:@"" error:NO];
        [strongSelf reload]; // re-fetch state + evidence status
    }];
}

#pragma mark - Row models (defensive: every key optional, "—" for missing)

- (NSArray<NSDictionary *> *)rowsForSection:(NSInteger)section {
    if (section == OMHRuntimeSectionStatus) {
        return [self statusRows];
    }
    if (section == OMHRuntimeSectionProviders) {
        return [self providerRows];
    }
    if (section == OMHRuntimeSectionTasks) {
        return [self taskRows];
    }
    if (section == OMHRuntimeSectionSchedules) {
        return [self scheduleRows];
    }
    if (section == OMHRuntimeSectionPlugins) {
        return [self pluginRows];
    }
    if (section == OMHRuntimeSectionSkills) {
        return [self skillRows];
    }
    if (section == OMHRuntimeSectionEvidence) {
        return [self evidenceRows];
    }
    return @[];
}

- (NSArray<NSDictionary *> *)statusRows {
    if (self.state == nil) {
        return @[@{@"title": @"No data yet",
                    @"detail": @"Runtime state has not loaded. Tap Refresh to try again."}];
    }
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];

    NSDictionary *counts = [self dictionaryFrom:self.state[@"counts"]];
    NSString *countsDetail = [NSString stringWithFormat:
        @"Queued %@ · Running %@ · Completed %@ · Failed %@ · Cancelled %@",
        [self stringOrDash:[self stringFrom:counts[@"queued"]]],
        [self stringOrDash:[self stringFrom:counts[@"running"]]],
        [self stringOrDash:[self stringFrom:counts[@"completed"]]],
        [self stringOrDash:[self stringFrom:counts[@"failed"]]],
        [self stringOrDash:[self stringFrom:counts[@"cancelled"]]]];
    [rows addObject:@{@"title": @"Tasks", @"detail": countsDetail}];

    for (id agentValue in [self arrayFrom:self.state[@"agents"]]) {
        NSDictionary *agent = [self dictionaryFrom:agentValue];
        if (agent == nil) {
            continue;
        }
        NSString *name = [self stringFrom:agent[@"name"]] ?: @"Agent";
        NSString *detail = [NSString stringWithFormat:@"Queued %@ · Running %@",
            [self stringOrDash:[self stringFrom:agent[@"queued"]]],
            [self stringOrDash:[self stringFrom:agent[@"running"]]]];
        [rows addObject:@{@"title": name, @"detail": detail}];
    }

    BOOL adminAvailable = [self boolFrom:self.state[@"adminActionsAvailable"]];
    [rows addObject:@{@"title": @"Admin actions",
                       @"detail": adminAvailable
                           ? @"Available"
                           : @"Not available — privileged actions require admin"}];

    NSDictionary *summary;
    summary = [self summaryRowForKey:@"memory" title:@"Memory"];
    if (summary != nil) [rows addObject:summary];
    summary = [self summaryRowForKey:@"traces" title:@"Traces"];
    if (summary != nil) [rows addObject:summary];
    summary = [self summaryRowForKey:@"workspaces" title:@"Workspaces"];
    if (summary != nil) [rows addObject:summary];

    return rows;
}

- (nullable NSDictionary *)summaryRowForKey:(NSString *)key title:(NSString *)title {
    id value = self.state[key];
    if (value == nil || [value isKindOfClass:[NSNull class]]) {
        return nil;
    }
    NSString *detail = nil;
    if ([value isKindOfClass:[NSDictionary class]]) {
        detail = [NSString stringWithFormat:@"%lu entries", (unsigned long)[(NSDictionary *)value count]];
    } else if ([value isKindOfClass:[NSArray class]]) {
        detail = [NSString stringWithFormat:@"%lu items", (unsigned long)[(NSArray *)value count]];
    } else if ([value isKindOfClass:[NSNumber class]]) {
        detail = [(NSNumber *)value stringValue];
    } else {
        return nil;
    }
    return @{@"title": title, @"detail": detail};
}

- (NSArray<NSDictionary *> *)providerRows {
    if (self.state == nil) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (id providerValue in [self arrayFrom:self.state[@"providers"]]) {
        NSDictionary *provider = [self dictionaryFrom:providerValue];
        if (provider == nil) {
            continue;
        }
        NSString *providerId = [self stringFrom:provider[@"id"]] ?: @"Provider";
        NSString *method = [self stringOrDash:[self stringFrom:provider[@"method"]]];
        NSString *status = [self stringOrDash:[self stringFrom:provider[@"status"]]];
        BOOL verified = [self boolFrom:provider[@"verified"]];
        NSMutableString *detail = [NSMutableString stringWithFormat:@"%@ · %@ · %@",
            method, status, verified ? @"Verified" : @"Not verified"];
        if (![status isEqualToString:@"configured"]) {
            // Verify needs the dashboard admin token: never offered here.
            [detail appendString:@" — Verify requires admin"];
        }
        [rows addObject:@{@"title": providerId, @"detail": detail}];
    }
    if (rows.count == 0) {
        [rows addObject:@{@"title": @"No providers", @"detail": @"—"}];
    }
    return rows;
}

- (NSArray<NSDictionary *> *)taskRows {
    if (self.state == nil) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (id taskValue in [self arrayFrom:self.state[@"tasks"]]) {
        NSDictionary *task = [self dictionaryFrom:taskValue];
        if (task == nil) {
            continue;
        }
        NSString *taskId = [self stringFrom:task[@"id"]];
        NSString *kind = [self stringOrDash:[self stringFrom:task[@"kind"]]];
        NSString *status = [self stringOrDash:[self stringFrom:task[@"status"]]];
        NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:
            [NSString stringWithFormat:@"%@ · %@", kind, status]];
        NSString *attempts = [self stringFrom:task[@"attempts"]];
        if (attempts != nil) {
            [lines addObject:[NSString stringWithFormat:@"Attempts: %@", attempts]];
        }
        if ([self boolFrom:task[@"blocked"]]) {
            [lines addObject:@"Blocked"];
        }
        NSString *dependsOn = [self stringFrom:task[@"dependsOn"]];
        if (dependsOn != nil) {
            [lines addObject:[NSString stringWithFormat:@"Depends on: %@", dependsOn]];
        }
        NSString *createdAt = [self readableDateFromValue:task[@"createdAt"]];
        if (createdAt != nil) {
            [lines addObject:[NSString stringWithFormat:@"Created: %@", createdAt]];
        }
        NSString *finishedAt = [self readableDateFromValue:task[@"finishedAt"]];
        if (finishedAt != nil) {
            [lines addObject:[NSString stringWithFormat:@"Finished: %@", finishedAt]];
        }
        NSString *cancelRequestedAt = [self readableDateFromValue:task[@"cancelRequestedAt"]];
        if (cancelRequestedAt != nil) {
            [lines addObject:[NSString stringWithFormat:@"Cancel requested: %@", cancelRequestedAt]];
        }
        NSMutableDictionary *row = [NSMutableDictionary dictionaryWithDictionary:
            @{@"title": taskId ?: kind, @"detail": [lines componentsJoinedByString:@"\n"]}];
        if (taskId != nil) {
            row[@"identifier"] = taskId;
            if ([status isEqualToString:@"queued"]) {
                row[@"action"] = @"taskCancel";
                row[@"actionTitle"] = @"Cancel";
            } else if ([kind isEqualToString:@"workspace.read"] && [status isEqualToString:@"failed"]) {
                row[@"action"] = @"taskRetry";
                row[@"actionTitle"] = @"Retry";
            }
        }
        [rows addObject:row];
    }
    if (rows.count == 0) {
        [rows addObject:@{@"title": @"No tasks", @"detail": @"—"}];
    }
    return rows;
}

- (NSArray<NSDictionary *> *)scheduleRows {
    if (self.state == nil) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (id scheduleValue in [self arrayFrom:self.state[@"schedules"]]) {
        NSDictionary *schedule = [self dictionaryFrom:scheduleValue];
        if (schedule == nil) {
            continue;
        }
        NSString *scheduleId = [self stringFrom:schedule[@"id"]];
        NSString *kind = [self stringOrDash:[self stringFrom:schedule[@"kind"]]];
        BOOL enabled = [self boolFrom:schedule[@"enabled"]];
        NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:
            [NSString stringWithFormat:@"%@ · %@", kind, enabled ? @"Enabled" : @"Disabled"]];
        NSString *everyMs = [self stringFrom:schedule[@"everyMs"]];
        if (everyMs != nil) {
            [lines addObject:[NSString stringWithFormat:@"Every %@", [self intervalStringFromMsValue:schedule[@"everyMs"]]]];
        }
        NSString *nextAt = [self readableDateFromValue:schedule[@"nextAt"]];
        if (nextAt != nil) {
            [lines addObject:[NSString stringWithFormat:@"Next: %@", nextAt]];
        }
        if (!enabled) {
            // Resume needs the dashboard admin token: never offered here.
            [lines addObject:@"Resume requires admin"];
        }
        NSMutableDictionary *row = [NSMutableDictionary dictionaryWithDictionary:
            @{@"title": scheduleId ?: kind, @"detail": [lines componentsJoinedByString:@"\n"]}];
        if (scheduleId != nil) {
            row[@"identifier"] = scheduleId;
            if (enabled) {
                row[@"action"] = @"schedulePause";
                row[@"actionTitle"] = @"Pause";
            }
        }
        [rows addObject:row];
    }
    if (rows.count == 0) {
        [rows addObject:@{@"title": @"No schedules", @"detail": @"—"}];
    }
    return rows;
}

- (NSArray<NSDictionary *> *)pluginRows {
    if (self.state == nil) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (id pluginValue in [self arrayFrom:self.state[@"plugins"]]) {
        NSDictionary *plugin = [self dictionaryFrom:pluginValue];
        if (plugin == nil) {
            continue;
        }
        NSString *name = [self stringFrom:plugin[@"name"]] ?: @"Plugin";
        NSString *version = [self stringOrDash:[self stringFrom:plugin[@"version"]]];
        BOOL enabled = [self boolFrom:plugin[@"enabled"]];
        NSMutableString *detail = [NSMutableString stringWithFormat:@"v%@ · %@",
            version, enabled ? @"Enabled" : @"Disabled"];
        if (!enabled) {
            // Enable needs the dashboard admin token: never offered here.
            [detail appendString:@" — Enable requires admin"];
        }
        NSMutableDictionary *row = [NSMutableDictionary dictionaryWithDictionary:
            @{@"title": name, @"detail": detail}];
        NSString *pluginName = [self stringFrom:plugin[@"name"]];
        if (pluginName != nil) {
            row[@"identifier"] = pluginName;
            if (enabled) {
                row[@"action"] = @"pluginDisable";
                row[@"actionTitle"] = @"Disable";
            }
        }
        [rows addObject:row];
    }
    if (rows.count == 0) {
        [rows addObject:@{@"title": @"No plugins", @"detail": @"—"}];
    }
    return rows;
}

- (NSArray<NSDictionary *> *)skillRows {
    if (self.state == nil) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (id skillValue in [self arrayFrom:self.state[@"skills"]]) {
        NSDictionary *skill = [self dictionaryFrom:skillValue];
        if (skill == nil) {
            continue;
        }
        NSString *skillId = [self stringFrom:skill[@"id"]];
        NSString *name = [self stringFrom:skill[@"name"]] ?: skillId ?: @"Skill";
        NSString *status = [self stringOrDash:[self stringFrom:skill[@"status"]]];
        NSMutableString *detail = [NSMutableString stringWithString:status];
        NSString *createdAt = [self readableDateFromValue:skill[@"createdAt"]];
        if (createdAt != nil) {
            [detail appendFormat:@" · Created: %@", createdAt];
        }
        // Accept needs the dashboard admin token, so it is never offered;
        // Reject is CSRF-only and is offered on every skill row.
        NSMutableDictionary *row = [NSMutableDictionary dictionaryWithDictionary:
            @{@"title": name, @"detail": detail}];
        if (skillId != nil) {
            row[@"identifier"] = skillId;
            row[@"action"] = @"skillReject";
            row[@"actionTitle"] = @"Reject";
        }
        [rows addObject:row];
    }
    if (rows.count == 0) {
        [rows addObject:@{@"title": @"No skills", @"detail": @"—"}];
    }
    return rows;
}

- (NSArray<NSDictionary *> *)evidenceRows {
    if (self.evidenceUnavailable) {
        return @[@{@"title": @"Evidence plugin not available on this harness version.",
                    @"detail": @"This harness predates the evidence MCP plugin endpoint."}];
    }
    NSDictionary *evidence = self.evidenceStatus;
    if (evidence == nil) {
        if (self.state == nil) {
            return @[];
        }
        return @[@{@"title": @"Evidence status unavailable.",
                    @"detail": @"No evidence status was returned."}];
    }
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    [rows addObject:@{@"title": @"State",
                       @"detail": [self stringOrDash:[self stringFrom:evidence[@"state"]]]}];
    NSNumber *connectedNumber = [self numberFrom:evidence[@"connected"]];
    [rows addObject:@{@"title": @"Connected",
                       @"detail": connectedNumber == nil ? @"—"
                           : ([connectedNumber boolValue] ? @"Yes" : @"No")}];
    [rows addObject:@{@"title": @"Restarts",
                       @"detail": [self stringOrDash:[self stringFrom:evidence[@"restarts"]]]}];
    NSString *lastError = [self stringFrom:evidence[@"lastError"]];
    [rows addObject:@{@"title": @"Last error",
                       @"detail": (lastError == nil || lastError.length == 0) ? @"None" : lastError}];
    NSString *lastPingAt = [self readableDateFromValue:evidence[@"lastPingAt"]];
    [rows addObject:@{@"title": @"Last ping",
                       @"detail": lastPingAt ?: @"—"}];
    [rows addObject:@{@"title": @"Tools",
                       @"detail": [self toolsSummaryFromValue:evidence[@"tools"]]}];
    NSString *dbPath = [self stringFrom:evidence[@"dbPath"]];
    if (dbPath != nil) {
        [rows addObject:@{@"title": @"Database", @"detail": dbPath}];
    }
    NSString *pid = [self stringFrom:evidence[@"pid"]];
    if (pid != nil) {
        [rows addObject:@{@"title": @"PID", @"detail": pid}];
    }
    [rows addObject:@{@"title": @"Retry evidence plugin",
                       @"detail": @"Re-check the evidence MCP connection.",
                       @"action": @"evidenceRetry",
                       @"actionTitle": @"Retry"}];
    if ([self boolFrom:evidence[@"enabled"]]) {
        [rows addObject:@{@"title": @"Disable evidence plugin",
                           @"detail": @"Stops the evidence MCP plugin.",
                           @"action": @"evidenceDisable",
                           @"actionTitle": @"Disable"}];
    } else {
        // Enable needs the dashboard admin token: never offered here.
        [rows addObject:@{@"title": @"Evidence plugin disabled",
                           @"detail": @"Enable requires admin"}];
    }
    return rows;
}

#pragma mark - UITableViewDataSource / Delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return OMHRuntimeSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[self rowsForSection:section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case OMHRuntimeSectionStatus: return @"Status";
        case OMHRuntimeSectionProviders: return @"Providers";
        case OMHRuntimeSectionTasks: return @"Tasks";
        case OMHRuntimeSectionSchedules: return @"Schedules";
        case OMHRuntimeSectionPlugins: return @"Plugins";
        case OMHRuntimeSectionSkills: return @"Skills";
        case OMHRuntimeSectionEvidence: return @"Evidence";
        default: return nil;
    }
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    UITableViewHeaderFooterView *headerView = (UITableViewHeaderFooterView *)view;
    headerView.textLabel.textColor = OMHTheme.mutedTextColor;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:OMHRuntimeCellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:OMHRuntimeCellIdentifier];
    }
    cell.backgroundColor = OMHTheme.surfaceColor;
    cell.textLabel.textColor = OMHTheme.textColor;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = OMHTheme.mutedTextColor;
    cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryView = nil;

    NSArray<NSDictionary *> *rows = [self rowsForSection:indexPath.section];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)rows.count) {
        cell.textLabel.text = @"—";
        cell.detailTextLabel.text = nil;
        return cell;
    }
    NSDictionary *row = rows[(NSUInteger)indexPath.row];
    cell.textLabel.text = [self stringFrom:row[@"title"]] ?: @"—";
    cell.detailTextLabel.text = [self stringFrom:row[@"detail"]];

    NSString *actionTitle = [self stringFrom:row[@"actionTitle"]];
    if (actionTitle != nil && [self stringFrom:row[@"action"]] != nil) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:actionTitle forState:UIControlStateNormal];
        [button setTitleColor:OMHTheme.accentColor forState:UIControlStateNormal];
        [button setTitleColor:OMHTheme.mutedTextColor forState:UIControlStateDisabled];
        button.tag = indexPath.section * 1000 + indexPath.row;
        [button addTarget:self action:@selector(actionButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [button sizeToFit];
        cell.accessoryView = button;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

#pragma mark - Defensive value helpers

- (nullable NSDictionary *)dictionaryFrom:(id)value {
    return [value isKindOfClass:[NSDictionary class]] ? (NSDictionary *)value : nil;
}

- (NSArray *)arrayFrom:(id)value {
    return [value isKindOfClass:[NSArray class]] ? (NSArray *)value : @[];
}

- (nullable NSString *)stringFrom:(id)value {
    if ([value isKindOfClass:[NSString class]]) {
        return (NSString *)value;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value stringValue];
    }
    return nil;
}

- (NSString *)stringOrDash:(nullable NSString *)value {
    return value ?: @"—";
}

- (nullable NSNumber *)numberFrom:(id)value {
    if ([value isKindOfClass:[NSNumber class]]) {
        return (NSNumber *)value;
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
        return [formatter numberFromString:(NSString *)value];
    }
    return nil;
}

- (BOOL)boolFrom:(id)value {
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value boolValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *lower = [(NSString *)value lowercaseString];
        return [lower isEqualToString:@"true"] || [lower isEqualToString:@"yes"] || [lower isEqualToString:@"1"];
    }
    return NO;
}

- (nullable NSString *)readableDateFromValue:(id)value {
    NSDate *date = nil;
    if ([value isKindOfClass:[NSString class]]) {
        NSISO8601DateFormatter *isoFormatter = [[NSISO8601DateFormatter alloc] init];
        date = [isoFormatter dateFromString:(NSString *)value];
        if (date == nil) {
            return (NSString *)value; // not ISO-8601: show the raw string
        }
    } else if ([value isKindOfClass:[NSNumber class]]) {
        NSTimeInterval seconds = [(NSNumber *)value doubleValue];
        if (seconds > 1e12) { // milliseconds since epoch
            seconds /= 1000.0;
        }
        date = [NSDate dateWithTimeIntervalSince1970:seconds];
    } else {
        return nil;
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    return [formatter stringFromDate:date];
}

- (NSString *)intervalStringFromMsValue:(id)value {
    NSNumber *number = [self numberFrom:value];
    if (number == nil) {
        return @"—";
    }
    long long ms = [number longLongValue];
    if (ms >= 3600000 && ms % 3600000 == 0) {
        return [NSString stringWithFormat:@"%lldh", ms / 3600000];
    }
    if (ms >= 60000 && ms % 60000 == 0) {
        return [NSString stringWithFormat:@"%lldm", ms / 60000];
    }
    if (ms >= 1000 && ms % 1000 == 0) {
        return [NSString stringWithFormat:@"%llds", ms / 1000];
    }
    return [NSString stringWithFormat:@"%lld ms", ms];
}

- (NSString *)toolsSummaryFromValue:(id)value {
    NSArray *tools = [self arrayFrom:value];
    if (tools.count == 0) {
        return @"—";
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id tool in tools) {
        NSString *name = [self stringFrom:tool];
        if (name == nil) {
            return [NSString stringWithFormat:@"%lu tools", (unsigned long)tools.count];
        }
        [names addObject:name];
    }
    return [names componentsJoinedByString:@", "];
}

- (NSString *)errorMessageForError:(NSError *)error {
    NSString *message = error.localizedDescription;
    if (message == nil || message.length == 0) {
        message = @"Request failed.";
    }
    return message;
}

- (void)setStatusText:(NSString *)text error:(BOOL)isError {
    self.statusLabel.text = text;
    self.statusLabel.textColor = isError ? OMHTheme.dangerColor : OMHTheme.mutedTextColor;
}

@end

//
//  OMHActivityViewController.m
//  OMH
//

#import "OMHActivityViewController.h"
#import "OMHActivityLog.h"

/// The filters worth having: everything, only what touched the device, and
/// only what went wrong — which is the one people actually come looking for.
typedef NS_ENUM(NSInteger, OMHActivityFilter) {
    OMHActivityFilterAll = 0,
    OMHActivityFilterCapabilities,
    OMHActivityFilterProblems,
};

@interface OMHActivityViewController ()
@property (nonatomic, copy) NSArray<OMHActivityEntry *> *rows;
@property (nonatomic) OMHActivityFilter filter;
@property (nonatomic) UISegmentedControl *filterControl;
@property (nonatomic) NSDateFormatter *timeFormatter;
@end

@implementation OMHActivityViewController

- (instancetype)init {
    if (self = [super initWithStyle:UITableViewStylePlain]) {
        self.title = @"Activity";
        _timeFormatter = [NSDateFormatter new];
        _timeFormatter.dateFormat = @"HH:mm:ss";
    }
    return self;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // A table header view does not get an automatic width from constraints.
    UIView *header = self.tableView.tableHeaderView;
    if (header && header.frame.size.width != self.tableView.bounds.size.width) {
        CGRect frame = header.frame;
        frame.size.width = self.tableView.bounds.size.width;
        header.frame = frame;
        self.tableView.tableHeaderView = header;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.accessibilityIdentifier = @"dsh.activity";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;

    self.filterControl = [[UISegmentedControl alloc] initWithItems:@[@"All", @"Device", @"Problems"]];
    self.filterControl.selectedSegmentIndex = 0;
    [self.filterControl addTarget:self action:@selector(filterChanged:) forControlEvents:UIControlEventValueChanged];
    // In the title view this competes with four buttons, and on a phone the
    // segments truncate to "Probl…". A header gets the full width on both.
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 48)];
    self.filterControl.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:self.filterControl];
    [NSLayoutConstraint activateConstraints:@[
        [self.filterControl.leadingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.leadingAnchor],
        [self.filterControl.trailingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.trailingAnchor],
        [self.filterControl.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    ]];
    self.tableView.tableHeaderView = header;

    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(share:)],
    ];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Clear"
                                                                            style:UIBarButtonItemStylePlain
                                                                           target:self action:@selector(confirmClear)];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload)
                                               name:OMHActivityLogDidChangeNotification object:nil];
    [self reload];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)filterChanged:(UISegmentedControl *)control {
    self.filter = control.selectedSegmentIndex;
    [self reload];
}

- (void)reload {
    NSArray<OMHActivityEntry *> *all = OMHActivityLog.shared.entries;
    if (self.filter == OMHActivityFilterCapabilities) {
        NSMutableArray *kept = [NSMutableArray array];
        for (OMHActivityEntry *entry in all)
            if (entry.source != OMHActivitySourceGuestTool)
                [kept addObject:entry];
        all = kept;
    } else if (self.filter == OMHActivityFilterProblems) {
        NSMutableArray *kept = [NSMutableArray array];
        for (OMHActivityEntry *entry in all)
            if (entry.outcome != OMHActivityOutcomeOK && entry.outcome != OMHActivityOutcomeStarted)
                [kept addObject:entry];
        all = kept;
    }
    self.rows = all;
    [self.tableView reloadData];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)share:(UIBarButtonItem *)sender {
    NSString *text = OMHActivityLog.shared.plainText;
    if (text.length == 0)
        return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[text]
                                                                        applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)confirmClear {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear the activity record?"
                                                                  message:@"This is the only record of what the agent has done on this device."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [OMHActivityLog.shared clear];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX(1, (NSInteger) self.rows.count);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (self.rows.count == 0) {
        cell.textLabel.text = self.filter == OMHActivityFilterProblems ? @"Nothing has gone wrong." : @"Nothing recorded yet.";
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.text = self.filter == OMHActivityFilterAll
            ? @"Every tool the agent runs, and every capability it uses, appears here."
            : nil;
        cell.accessibilityIdentifier = @"dsh.activity.empty";
        return cell;
    }

    OMHActivityEntry *entry = self.rows[indexPath.row];
    NSMutableString *title = [NSMutableString stringWithFormat:@"%@  %@",
                              [self.timeFormatter stringFromDate:entry.date], entry.name];
    if (entry.duration >= 0.05)
        [title appendFormat:@"  (%.1fs)", entry.duration];
    cell.textLabel.text = title;
    cell.textLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
    // The eye goes to what went wrong, which is what people open this for.
    cell.textLabel.textColor = entry.outcome == OMHActivityOutcomeOK || entry.outcome == OMHActivityOutcomeStarted
        ? UIColor.labelColor : UIColor.systemOrangeColor;

    NSMutableArray *lines = [NSMutableArray array];
    if (entry.source == OMHActivitySourceConfirmation)
        [lines addObject:[NSString stringWithFormat:@"asked — %@", OMHActivityOutcomeName(entry.outcome)]];
    else if (entry.outcome != OMHActivityOutcomeOK)
        [lines addObject:OMHActivityOutcomeName(entry.outcome)];
    if (entry.detail) [lines addObject:entry.detail];
    if (entry.result) [lines addObject:[@"→ " stringByAppendingString:entry.result]];
    cell.detailTextLabel.text = [lines componentsJoinedByString:@"\n"];
    cell.accessibilityIdentifier = [NSString stringWithFormat:@"dsh.activity.%@", entry.name];
    return cell;
}

@end

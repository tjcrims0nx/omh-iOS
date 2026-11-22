//
//  OMHCapabilitiesViewController.m
//  OMH
//

#import "OMHCapabilitiesViewController.h"
#import "OMHCapability.h"
#import "OMHActivityLog.h"
#import "OMHActivityViewController.h"
#import "OMHHostBridge.h"

@interface OMHCapabilitiesViewController ()
/// Section 0 reads, section 1 writes — because "what can it see" and "what can
/// it change" are different questions, and a flat list of a dozen switches
/// makes them look alike.
@property (nonatomic, copy) NSArray<OMHCapability *> *reading;
@property (nonatomic, copy) NSArray<OMHCapability *> *writing;
@end

@implementation OMHCapabilitiesViewController

- (instancetype)init {
    if (self = [super initWithStyle:UITableViewStyleInsetGrouped])
        self.title = @"Capabilities";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.accessibilityIdentifier = @"omh.capabilities";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload)
                                               name:OMHCapabilityRegistryDidChangeNotification object:nil];
    // A system permission can be changed in Settings while we are in the
    // background, so the states are re-read every time the app comes back.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload)
                                               name:UIApplicationDidBecomeActiveNotification object:nil];
    [self reload];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)reload {
    NSMutableArray *reading = [NSMutableArray array], *writing = [NSMutableArray array];
    for (OMHCapability *capability in OMHCapabilityRegistry.shared.capabilities)
        [capability.gate == OMHCapabilityGatePerCall ? writing : reading addObject:capability];
    self.reading = reading;
    self.writing = writing;
    [self.tableView reloadData];
}

- (nullable OMHCapability *)capabilityAt:(NSIndexPath *)indexPath {
    NSArray<OMHCapability *> *section = indexPath.section == 0 ? self.reading : self.writing;
    return indexPath.row < (NSInteger) section.count ? section[indexPath.row] : nil;
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // Capabilities register when the guest finishes booting, so the list can
    // legitimately be empty for the first few seconds after launch.
    if (section == 0) return MAX(1, (NSInteger) self.reading.count);
    if (section == 1) return MAX(1, (NSInteger) self.writing.count);
    return 2;   // bridge status, and the way into the activity record
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"What the agent can read";
    if (section == 1) return @"What the agent can change";
    return @"Bridge";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0)
        return @"Anything switched on here can be read by the agent running in OpenMind Harness — including by a model answering over the network. "
                "Switches take effect immediately, including in the middle of a turn. Items that say “Also needs iOS permission” ask iOS as soon "
                "as you switch them on; that grant can be revoked later in Settings ▸ Privacy.";
    if (section == 1)
        return @"These change something outside OpenMind Harness, so switching one on is not the last word: you are asked to confirm each individual action, "
                "and the alert says exactly what it will do. Nothing happens while OMH is in the background.";
    return @"The bridge listens on this device only (127.0.0.1) and requires a token that changes every launch, so other apps cannot reach it.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;

    if (indexPath.section == 2) {
        if (indexPath.row == 1) {
            cell.textLabel.text = @"Activity";
            cell.detailTextLabel.text = @"Everything the agent has done — the tools it ran and the capabilities it used.";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.accessibilityIdentifier = @"omh.capability.activity";
            return cell;
        }
        OMHHostBridge *bridge = OMHHostBridge.shared;
        cell.textLabel.text = bridge.isRunning ? @"Running" : @"Not running";
        cell.detailTextLabel.text = bridge.isRunning
            ? [NSString stringWithFormat:@"%@ · %lu requests served", bridge.baseURLString, (unsigned long) bridge.requestCount]
            : @"The guest cannot reach any device capability.";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessibilityIdentifier = @"omh.capability.bridge";
        return cell;
    }

    OMHCapability *capability = [self capabilityAt:indexPath];
    if (capability == nil) {
        cell.textLabel.text = @"Still starting…";
        cell.detailTextLabel.text = @"Capabilities appear once the guest has booted.";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessibilityIdentifier = @"omh.capability.empty";
        return cell;
    }

    OMHCapabilityState state = [OMHCapabilityRegistry.shared stateForIdentifier:capability.identifier];
    cell.textLabel.text = capability.title;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessibilityIdentifier = [NSString stringWithFormat:@"omh.capability.%@", capability.identifier];

    NSMutableString *detail = [capability.details mutableCopy];
    if (!capability.available)
        [detail appendString:@"\nNot available on this device."];
    else if (capability.gate == OMHCapabilityGateSystemPermission)
        [detail appendString:@"\nAlso needs iOS permission."];
    else if (capability.gate == OMHCapabilityGatePerCall)
        [detail appendString:@"\nAsks you before every action."];

    // Last: what a capability *requires* outranks when it last ran, and on a
    // phone every line pushes the next one further down.
    NSDate *lastUse = [OMHActivityLog.shared lastUseOf:capability.identifier];
    if (lastUse) {
        NSRelativeDateTimeFormatter *formatter = [NSRelativeDateTimeFormatter new];
        formatter.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleFull;
        [detail appendFormat:@"\nLast used %@.", [formatter localizedStringForDate:lastUse relativeToDate:NSDate.date]];
    }
    cell.detailTextLabel.text = detail;

    UISwitch *toggle = [UISwitch new];
    toggle.on = state != OMHCapabilityStateDisabled && state != OMHCapabilityStateUnavailable;
    toggle.enabled = capability.available;
    // Encodes both coordinates: the switch's action has no index path of its own.
    toggle.tag = indexPath.section * 1000 + indexPath.row;
    toggle.accessibilityIdentifier = [NSString stringWithFormat:@"omh.capability.switch.%@", capability.identifier];
    [toggle addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 2 || indexPath.row != 1)
        return;
    [self.navigationController pushViewController:[OMHActivityViewController new] animated:YES];
}

- (void)toggled:(UISwitch *)toggle {
    OMHCapability *capability = [self capabilityAt:[NSIndexPath indexPathForRow:toggle.tag % 1000
                                                                     inSection:toggle.tag / 1000]];
    if (capability == nil)
        return;
    if (!toggle.isOn) {
        [OMHCapabilityRegistry.shared setEnabled:NO forIdentifier:capability.identifier];
        return;
    }
    // Turning something on is the consequential direction, so it is the one
    // that gets a confirmation naming what is being handed over.
    NSString *consequence = capability.gate == OMHCapabilityGatePerCall
        ? @"You will still be asked before each individual action — this switch only decides whether the agent may ask."
        : @"The agent will be able to read this whenever it decides to, including when a remote model asks it to.";
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:capability.title
                         message:[NSString stringWithFormat:@"%@\n\n%@", capability.details, consequence]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        toggle.on = NO;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Allow" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [OMHCapabilityRegistry.shared setEnabled:YES forIdentifier:capability.identifier];
        // Ask iOS now, while the user is here and expecting it, instead of
        // letting the agent's first call fail on a permission it never asked for.
        if (capability.requestSystemPermission)
            capability.requestSystemPermission();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

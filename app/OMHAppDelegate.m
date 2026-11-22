//
//  OMHAppDelegate.m
//  OMH
//

#import "OMHAppDelegate.h"
#import "OMHBootCoordinator.h"
#import "OMHHarness.h"
#import "OMHRootViewController.h"

static NSString *const kCapabilityPreferenceRepair = @"OMHCapabilityPreferenceRepair.2";

static void OMHRepairPreferencesPollutedByLegacyTests(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:kCapabilityPreferenceRepair])
        return;

    // Builds through 1.0.13 ran unit tests inside the application process and
    // wrote their temporary capability switches into the production defaults.
    // An App Store/TestFlight update preserves those defaults. Forget only this
    // namespace once so every capability returns to its declared product
    // default; HealthKit and the other system privacy choices are untouched.
    for (NSString *key in defaults.dictionaryRepresentation.allKeys) {
        if ([key hasPrefix:@"OMHCapabilityEnabled."])
            [defaults removeObjectForKey:key];
    }
    [defaults setBool:YES forKey:kCapabilityPreferenceRepair];
}

// iSH's AppDelegate boots the kernel inside -willFinishLaunching. That takes
// far longer than iOS's launch watchdog allows on a phone (importing the guest
// image alone can take a minute), so OMH overrides both launch methods, keeps
// only their cheap parts, and lets OMHBootCoordinator do the work in the
// background while the UI is already on screen.
@implementation OMHAppDelegate

- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey,id> *)launchOptions {
    OMHRepairPreferencesPollutedByLegacyTests();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:@"hail mary"]) {
        [defaults removeObjectForKey:@"Boot Command"];
        [defaults removeObjectForKey:@"Init Command"];
        [defaults setBool:NO forKey:@"hail mary"];
    }
    return YES;   // deliberately no [super ...]: that would boot synchronously
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"recovery"])
        return YES;
    // Kicks off image import → kernel boot → data migration → harness start.
    [OMHBootCoordinator.shared start];
    return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    // Suspension may have broken the guest's sockets. Confirm the server still
    // answers; OMHHarness restarts it otherwise and the UI reloads.
    [OMHHarness.shared verifyAliveWithCompletion:nil];
}

@end

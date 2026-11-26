//
//  OMHBootCoordinator.m
//  OMH
//

#import "OMHBootCoordinator.h"
#import "OMHHarness.h"
#import "OMHRootUpgrader.h"
#import "OMHHostBridge.h"
#import "OMHDeviceCapability.h"
#import "OMHEventKitCapability.h"
#import "OMHHealthCapability.h"
#import "OMHLocationCapability.h"
#import "OMHContactsCapability.h"
#import "OMHNotificationCapability.h"
#import "OMHFilesCapability.h"
#import "OMHPhotosCapability.h"
#import "OMHShareCapability.h"
#import "OMHShortcutsCapability.h"
#import "OMHActivityCapability.h"
#import "OMHStartupMetrics.h"
#import "AppDelegate.h"
#import <UIKit/UIKit.h>

NSNotificationName const OMHBootStateDidChangeNotification = @"OMHBootStateDidChangeNotification";

// -boot lives in iSH's AppDelegate implementation; it is safe to run on any
// single thread because `current` is thread-local.
@interface AppDelegate (OMHBoot)
- (int)boot;
@end

@interface OMHBootCoordinator ()
@property (nonatomic, readwrite) OMHBootPhase phase;
@property (nonatomic, readwrite) double progress;
@property (nonatomic, readwrite, copy) NSString *statusMessage;
@property (nonatomic, readwrite) int bootError;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) BOOL started;
@end

@implementation OMHBootCoordinator

+ (instancetype)shared {
    static OMHBootCoordinator *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [OMHBootCoordinator new]; });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        // Serial and high priority: the whole guest lives on this thread until
        // init is started, and the user is staring at a spinner meanwhile.
        _queue = dispatch_queue_create("app.omh.boot", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
        _statusMessage = @"Preparing the Linux environment…";
        _progress = -1;
    }
    return self;
}

- (void)setPhase:(OMHBootPhase)phase message:(NSString *)message progress:(double)progress {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_phase = phase;
        self->_statusMessage = [message copy];
        self->_progress = progress;
        [NSNotificationCenter.defaultCenter postNotificationName:OMHBootStateDidChangeNotification object:self];
    });
}

- (void)start {
    NSAssert(NSThread.isMainThread, @"start on main");
    if (self.started)
        return;
    self.started = YES;
    [OMHStartupMetrics.shared beginLaunch];
    [OMHHarness.shared.log append:@"[perf] app boot coordinator started"];
    [self setPhase:OMHBootPhaseImportingImage message:@"Preparing the Linux environment…" progress:-1];
    // UIApplication is main-thread-only; grab the delegate here, not on the queue.
    AppDelegate *app = (AppDelegate *) UIApplication.sharedApplication.delegate;

    dispatch_async(self.queue, ^{
        NSDate *t0 = NSDate.date;
        // 1. Import the bundled image when this build ships a new one. On a
        //    fresh install this is where the 95 MB root filesystem lands.
        OMHRootUpgrader *upgrader = OMHRootUpgrader.shared;
        [upgrader prepareRootsBeforeBootWithProgress:^(double fraction, NSString *message) {
            [self setPhase:OMHBootPhaseImportingImage
                   message:message.length ? message : @"Installing the Linux image…"
                  progress:fraction];
        }];
        NSTimeInterval imported = -t0.timeIntervalSinceNow;
        [OMHHarness.shared.log append:[NSString stringWithFormat:@"[perf] image preparation %.3fs", imported]];
        [OMHStartupMetrics.shared mark:@"image_ready"];

        // 2. Boot the emulator kernel (mount the fakefs, start init).
        [self setPhase:OMHBootPhaseBootingKernel message:@"Booting the Linux guest…" progress:-1];
        int err = [app boot];
        NSTimeInterval kernelBoot = -t0.timeIntervalSinceNow - imported;
        [OMHHarness.shared.log append:[NSString stringWithFormat:@"[perf] guest kernel boot %.3fs", kernelBoot]];
        [OMHStartupMetrics.shared mark:@"kernel_ready"];
        self.bootError = err;
        [OMHHarness.shared.log append:[NSString stringWithFormat:@"[openmind-harness] guest boot %@ (image %.1fs, total %.1fs)",
                                       err == 0 ? @"ok" : [NSString stringWithFormat:@"failed: %d", err],
                                       imported, -t0.timeIntervalSinceNow]];
        if (err < 0) {
            [self setPhase:OMHBootPhaseFailed
                   message:[NSString stringWithFormat:@"The Linux guest failed to boot (error %d).", err]
                  progress:-1];
            return;
        }

        // 3. Migrate user data from a previous root, then let the harness run.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (upgrader.pendingMigrationRoot != nil) {
                [self setPhase:OMHBootPhaseMigratingData message:@"Moving your sessions to the new image…" progress:-1];
                [upgrader migrateIfNeededWithCompletion:^(BOOL migrated, NSError *error) {
                    if (error)
                        [OMHHarness.shared.log append:[NSString stringWithFormat:@"[openmind-harness] migration problem: %@", error.localizedDescription]];
                    [self finishReady];
                }];
            } else {
                [self finishReady];
            }
        });
    });
}

- (void)finishReady {
    [self setPhase:OMHBootPhaseReady message:@"Starting OpenMind Harness…" progress:-1];
    // The host bridge must be listening before opencode-serve starts: its URL and
    // token reach the guest through the server's environment.
    OMHHostBridge *bridge = OMHHostBridge.shared;
    [OMHDeviceCapability installOn:bridge];
    [OMHEventKitCapability installOn:bridge];
    [OMHHealthCapability installOn:bridge];
    [OMHLocationCapability installOn:bridge];
    [OMHContactsCapability installOn:bridge];
    [OMHNotificationCapability installOn:bridge];
    [OMHFilesCapability installOn:bridge];
    [OMHPhotosCapability installOn:bridge];
    [OMHShareCapability installOn:bridge];
    [OMHShortcutsCapability installOn:bridge];
    [OMHActivityCapability installOn:bridge];
    if ([bridge start]) {
        NSMutableDictionary *env = [OMHHarness.shared.extraEnvironment mutableCopy];
        [env addEntriesFromDictionary:bridge.guestEnvironment];
        OMHHarness.shared.extraEnvironment = env;
    } else {
        [OMHHarness.shared.log append:@"[openmind-harness] host bridge could not start; iOS capabilities are unavailable"];
    }
    [OMHStartupMetrics.shared mark:@"bridge_ready"];
    // The home screen is the dashboard web view on both idioms, so the
    // dashboard harness must start on iPhone too — not only on iPad.
    // (Before the native shell was unified, the iPhone home was the editor
    // and only the shared harness started here; the dashboard harness
    // staying Idle left the iPhone web view hidden forever.)
    [OMHHarness.dashboard start];
    // Initialize the coding runtime on both iPad and iPhone at app launch.
    [OMHHarness.shared start];
}

@end

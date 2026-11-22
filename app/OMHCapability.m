//
//  OMHCapability.m
//  OMH
//

#import "OMHCapability.h"
#import <UIKit/UIKit.h>

NSNotificationName const OMHCapabilityRegistryDidChangeNotification = @"OMHCapabilityRegistryDidChangeNotification";
static NSString *const kEnabledPrefix = @"OMHCapabilityEnabled.";

static BOOL OMHIsRunningUnitTests(void) {
    // OMHTests is injected into the real app process. Persisting its switch
    // changes would therefore leak into the developer build and, because both
    // builds share a bundle identifier, survive a later TestFlight install.
    return NSClassFromString(@"XCTestCase") != nil;
}

void OMHRunOnMainSync(dispatch_block_t block) {
    if (NSThread.isMainThread)
        block();
    else
        dispatch_sync(dispatch_get_main_queue(), block);
}

NSString *OMHCapabilityStateName(OMHCapabilityState state) {
    switch (state) {
        case OMHCapabilityStateGranted: return @"granted";
        case OMHCapabilityStateDisabled: return @"disabled";
        case OMHCapabilityStatePrompt: return @"prompt";
        case OMHCapabilityStateUnavailable: return @"unavailable";
    }
    return @"unavailable";
}

@implementation OMHCapability

- (instancetype)initWithIdentifier:(NSString *)identifier
                             title:(NSString *)title
                           details:(NSString *)details
                              gate:(OMHCapabilityGate)gate
                  enabledByDefault:(BOOL)enabledByDefault
                         available:(BOOL)available {
    if (self = [super init]) {
        _identifier = [identifier copy];
        _title = [title copy];
        _details = [details copy];
        _gate = gate;
        _enabledByDefault = enabledByDefault;
        _available = available;
    }
    return self;
}

@end

@interface OMHCapabilityRegistry ()
@property (nonatomic) NSMutableArray<OMHCapability *> *ordered;
@property (nonatomic) NSMutableDictionary<NSString *, OMHCapability *> *byIdentifier;
@property (nonatomic) NSMutableDictionary<NSString *, NSNumber *> *testingEnabledOverrides;
@end

@implementation OMHCapabilityRegistry

+ (instancetype)shared {
    static OMHCapabilityRegistry *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [OMHCapabilityRegistry new];
        [shared registerBuiltIns];
    });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        _ordered = [NSMutableArray array];
        _byIdentifier = [NSMutableDictionary dictionary];
        _testingEnabledOverrides = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)registerBuiltIns {
    // Phase 0 ships the one capability that needs no permission and no user
    // data, so the whole path can be proven before anything sensitive lands.
    [self registerCapability:[[OMHCapability alloc] initWithIdentifier:@"device.info"
                                                                title:@"Device information"
                                                              details:@"Model, iOS version, locale, battery and thermal state."
                                                                 gate:OMHCapabilityGateEnabledOnly
                                                     enabledByDefault:YES
                                                            available:YES]];
}

- (void)registerCapability:(OMHCapability *)capability {
    @synchronized (self) {
        OMHCapability *existing = self.byIdentifier[capability.identifier];
        if (existing)
            [self.ordered removeObject:existing];
        self.byIdentifier[capability.identifier] = capability;
        [self.ordered addObject:capability];
    }
}

- (NSArray<OMHCapability *> *)capabilities {
    @synchronized (self) { return [self.ordered copy]; }
}

- (OMHCapability *)capabilityWithIdentifier:(NSString *)identifier {
    @synchronized (self) { return self.byIdentifier[identifier]; }
}

- (BOOL)isEnabled:(NSString *)identifier {
    OMHCapability *capability = [self capabilityWithIdentifier:identifier];
    if (capability == nil || !capability.available)
        return NO;
    NSString *key = [kEnabledPrefix stringByAppendingString:identifier];
    if (OMHIsRunningUnitTests()) {
        @synchronized (self) {
            NSNumber *override = self.testingEnabledOverrides[identifier];
            if (override != nil)
                return override.boolValue;
        }
    }
    NSNumber *stored = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return stored != nil ? stored.boolValue : capability.enabledByDefault;
}

- (void)setEnabled:(BOOL)enabled forIdentifier:(NSString *)identifier {
    if (OMHIsRunningUnitTests()) {
        @synchronized (self) {
            self.testingEnabledOverrides[identifier] = @(enabled);
        }
    } else {
        [NSUserDefaults.standardUserDefaults setBool:enabled forKey:[kEnabledPrefix stringByAppendingString:identifier]];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:OMHCapabilityRegistryDidChangeNotification object:self];
    });
}

- (OMHCapabilityState)stateForIdentifier:(NSString *)identifier {
    OMHCapability *capability = [self capabilityWithIdentifier:identifier];
    if (capability == nil || !capability.available)
        return OMHCapabilityStateUnavailable;
    if (![self isEnabled:identifier])
        return OMHCapabilityStateDisabled;
    // Gates beyond the switch are evaluated by the capability's own handler
    // when the call arrives (system dialogs, per-call confirmation).
    return capability.gate == OMHCapabilityGateEnabledOnly ? OMHCapabilityStateGranted : OMHCapabilityStatePrompt;
}

- (NSArray<NSDictionary *> *)stateSummary {
    NSMutableArray *out = [NSMutableArray array];
    for (OMHCapability *capability in self.capabilities) {
        [out addObject:@{
            @"id": capability.identifier,
            @"title": capability.title,
            @"details": capability.details,
            @"state": OMHCapabilityStateName([self stateForIdentifier:capability.identifier]),
            @"gate": capability.gate == OMHCapabilityGateEnabledOnly ? @"enabled-only"
                   : capability.gate == OMHCapabilityGateSystemPermission ? @"system-permission" : @"per-call",
        }];
    }
    return out;
}

- (void)disableAllForTesting {
    for (OMHCapability *capability in self.capabilities)
        [self setEnabled:NO forIdentifier:capability.identifier];
}

- (void)resetForTesting {
    @synchronized (self) {
        [self.testingEnabledOverrides removeAllObjects];
        [self.ordered removeAllObjects];
        [self.byIdentifier removeAllObjects];
    }
}

@end

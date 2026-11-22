//
//  OMHCapability.h
//  OMH
//
//  The registry of iOS capabilities the guest may reach through the host
//  bridge. Each capability is off unless the user turned it on (or it is
//  harmless enough to default to on), and the app — never the guest — decides.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// How the app gates one capability.
typedef NS_ENUM(NSInteger, OMHCapabilityGate) {
    /// Allowed whenever the capability is enabled (read-only, no user data).
    OMHCapabilityGateEnabledOnly = 0,
    /// Needs the system permission dialog of its framework as well.
    OMHCapabilityGateSystemPermission,
    /// Needs a native confirmation in the app for every call.
    OMHCapabilityGatePerCall,
};

/// What a capability answers when asked whether it can run right now.
typedef NS_ENUM(NSInteger, OMHCapabilityState) {
    OMHCapabilityStateGranted = 0,  // ready to use
    OMHCapabilityStateDisabled,     // switched off in OMH's settings
    OMHCapabilityStatePrompt,       // enabled, but a permission/confirmation is still needed
    OMHCapabilityStateUnavailable,  // not supported by this build or OS
};

NSString *OMHCapabilityStateName(OMHCapabilityState state);

/// Runs `block` on the main thread and waits for it. Capability code is reached
/// both from bridge handlers (a background queue) and from the settings switches
/// (the main thread), so a bare dispatch_sync to the main queue deadlocks half
/// the callers. Runs inline when already on the main thread.
void OMHRunOnMainSync(dispatch_block_t block);

@interface OMHCapability : NSObject
@property (nonatomic, readonly, copy) NSString *identifier;   // e.g. "device.info"
@property (nonatomic, readonly, copy) NSString *title;        // shown in settings
@property (nonatomic, readonly, copy) NSString *details;      // one line for the user
@property (nonatomic, readonly) OMHCapabilityGate gate;
@property (nonatomic, readonly) BOOL enabledByDefault;
@property (nonatomic, readonly) BOOL available;               // supported on this device/build

- (instancetype)initWithIdentifier:(NSString *)identifier
                             title:(NSString *)title
                           details:(NSString *)details
                              gate:(OMHCapabilityGate)gate
                   enabledByDefault:(BOOL)enabledByDefault
                         available:(BOOL)available NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Asks the underlying framework for its permission, if it has one. Set by the
/// capability's own module; called when the user switches the capability on, so
/// the system dialog appears then rather than on the agent's first (failing)
/// call. Must be safe to call more than once and from the main thread.
@property (nonatomic, copy, nullable) void (^requestSystemPermission)(void);
@end

extern NSNotificationName const OMHCapabilityRegistryDidChangeNotification;

@interface OMHCapabilityRegistry : NSObject

+ (instancetype)shared;

/// Every capability this build knows about, in display order.
@property (nonatomic, readonly, copy) NSArray<OMHCapability *> *capabilities;

- (nullable OMHCapability *)capabilityWithIdentifier:(NSString *)identifier;
- (BOOL)isEnabled:(NSString *)identifier;
- (void)setEnabled:(BOOL)enabled forIdentifier:(NSString *)identifier;
/// Current state of one capability (unknown identifiers are Unavailable).
- (OMHCapabilityState)stateForIdentifier:(NSString *)identifier;
/// `capabilities` as JSON-ready dictionaries for `GET /v1/capabilities`.
- (NSArray<NSDictionary *> *)stateSummary;

/// Registers a capability; used by tests and by future capability modules.
- (void)registerCapability:(OMHCapability *)capability;
/// Test hook: forget every registered capability and stored preference.
- (void)resetForTesting;

/// Turns every registered capability off. Capabilities ship on, so the suites
/// that assert the refusal path have to switch them off to have one.
- (void)disableAllForTesting;

@end

NS_ASSUME_NONNULL_END

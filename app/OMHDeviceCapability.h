//
//  OMHDeviceCapability.h
//  OMH
//
//  The first bridge capability: read-only facts about the device. No user data,
//  no system permission — it exists to prove the whole path end to end.
//

#import <Foundation/Foundation.h>
@class OMHHostBridge;

NS_ASSUME_NONNULL_BEGIN

@interface OMHDeviceCapability : NSObject
/// Adds `GET /v1/device` and `GET /v1/device/power` to the bridge.
+ (void)installOn:(OMHHostBridge *)bridge;
/// The payload `/v1/device` returns (also used by tests).
+ (NSDictionary *)snapshot;
/// The smaller, faster-changing subset behind `/v1/device/power`.
+ (NSDictionary *)powerSnapshot;
@end

NS_ASSUME_NONNULL_END

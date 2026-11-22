//
//  OMHLocationCapability.h
//  OMH
//
//  One location fix, on request.
//
//  Nothing continuous: the agent asks, CoreLocation is started, the first
//  usable fix is returned and the manager is stopped again. A background agent
//  cannot quietly follow the user around, and the fix carries its accuracy so
//  the model can say "within 65 m" instead of implying more than it knows.
//

#import <Foundation/Foundation.h>
@class OMHHostBridge;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const OMHCapabilityLocationRead;

@interface OMHLocationCapability : NSObject
+ (void)installOn:(OMHHostBridge *)bridge;
@end

NS_ASSUME_NONNULL_END

//
//  OMHGuestLauncher.h
//  OMH
//
//  OMHGuestProcessLauncher backed by the emulator (ISHShellExecutor).
//

#import <Foundation/Foundation.h>
#import "OMHHarness.h"

NS_ASSUME_NONNULL_BEGIN

@interface OMHGuestLauncher : NSObject <OMHGuestProcessLauncher>
@end

NS_ASSUME_NONNULL_END

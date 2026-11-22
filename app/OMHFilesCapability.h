//
//  OMHFilesCapability.h
//  OMH
//
//  Moving files between the guest's workspace and the rest of iOS.
//
//  The app never reaches into the guest filesystem: the guest sends or receives
//  the *contents* over the bridge and writes them itself with the tools it
//  already has. That keeps the emulator's fakefs out of this entirely.
//
//  Import is confirmed by the document picker itself — the user chooses the
//  file, so there is nothing extra to ask. Export asks first: it puts data the
//  agent chose somewhere the user did not.
//

#import <Foundation/Foundation.h>
@class OMHHostBridge;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const OMHCapabilityFilesImport;
extern NSString *const OMHCapabilityFilesExport;

@interface OMHFilesCapability : NSObject
+ (void)installOn:(OMHHostBridge *)bridge;
/// Bytes a single import or export may carry.
+ (NSUInteger)maximumBytes;
@end

NS_ASSUME_NONNULL_END

//
//  OMHPhotosCapability.h
//  OMH
//
//  One photo at a time, out of the library and into the guest.
//
//  PHPickerViewController runs outside this process: it shows the whole library
//  without OMH being able to see any of it, and hands back only what the user
//  chose. That is why there is no photo-library permission here and no usage
//  string — the app never has library access to ask for. The picker is the
//  consent, the same arrangement as file import.
//
//  There is deliberately no route that lists, searches or counts photos. The
//  agent cannot ask "what pictures are there"; a human has to hand it one.
//

#import <Foundation/Foundation.h>
@class OMHHostBridge;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const OMHCapabilityPhotosImport;

@interface OMHPhotosCapability : NSObject
+ (void)installOn:(OMHHostBridge *)bridge;
@end

NS_ASSUME_NONNULL_END

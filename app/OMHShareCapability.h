//
//  OMHShareCapability.h
//  OMH
//
//  Handing something the agent produced to the rest of iOS through the share
//  sheet: a message, a note, AirDrop, whatever the user picks.
//
//  The share sheet looks like consent and is not quite. It asks *where* the
//  content goes; it does not ask whether this content should leave OMH at all,
//  and the agent wrote the content. A sheet that appears mid-turn with a
//  plausible message already in it is the shape of a mistake, so this asks
//  first, in OMH's own words, with the text shown — and only then presents the
//  sheet.
//

#import <Foundation/Foundation.h>
@class OMHHostBridge;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const OMHCapabilityShare;

@interface OMHShareCapability : NSObject
+ (void)installOn:(OMHHostBridge *)bridge;
/// Characters of shared text the route accepts.
+ (NSUInteger)maximumCharacters;
@end

NS_ASSUME_NONNULL_END

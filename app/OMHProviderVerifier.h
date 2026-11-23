#import <Foundation/Foundation.h>
typedef void (^OMHProviderVerificationCompletion)(NSString *status);
@interface OMHProviderVerifier : NSObject
+ (void)verifyProvider:(NSString *)provider completion:(OMHProviderVerificationCompletion)completion;
@end

#import <Foundation/Foundation.h>
@interface OMHProviderCredentials : NSObject
+ (NSDictionary<NSString *,NSString *> *)environment;
+ (BOOL)saveToken:(NSString *)token provider:(NSString *)provider;
+ (void)removeProvider:(NSString *)provider;
@end

#import <Foundation/Foundation.h>
@interface OMHProviderCredentials : NSObject
+ (NSDictionary<NSString *,NSString *> *)environment;
+ (BOOL)saveToken:(NSString *)token provider:(NSString *)provider;
+ (void)removeProvider:(NSString *)provider;

// Custom providers (custom-openai, custom-anthropic). The API key stays in
// the Keychain (same service/account as the built-in providers). The base
// URL and model ID are not secrets, so they live in UserDefaults.
// A custom provider is configured when URL + model + key are all present.
+ (BOOL)isCustomProvider:(NSString *)provider;
+ (NSString * _Nullable)customProviderBaseURL:(NSString *)provider;
+ (NSString * _Nullable)customProviderModel:(NSString *)provider;
+ (void)saveCustomProvider:(NSString *)provider baseURL:(NSString *)baseURL model:(NSString *)model;
+ (void)removeCustomProvider:(NSString *)provider;
@end

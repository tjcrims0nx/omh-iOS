#import "OMHProviderCredentials.h"
#import <Foundation/Foundation.h>
#import <Security/Security.h>

// Credentials remain in the iOS Keychain at rest. Never use UserDefaults for keys.
// Custom providers (custom-openai, custom-anthropic) keep only their base URL
// and model ID in UserDefaults; the API key is in the Keychain like every
// other provider. The base URL and model ID are not secrets.
@implementation OMHProviderCredentials
+ (NSDictionary<NSString *, NSString *> *)names {
    return @{@"openai":@"OPENAI_API_KEY", @"anthropic":@"ANTHROPIC_API_KEY",
             @"google":@"GEMINI_API_KEY", @"deepseek":@"DEEPSEEK_API_KEY",
             @"zai":@"ZAI_API_KEY", @"moonshotai":@"MOONSHOT_API_KEY",
             @"qwen":@"DASHSCOPE_API_KEY", @"custom":@"OPENMIND_CUSTOM_API_KEY",
             @"groq":@"GROQ_API_KEY", @"together":@"TOGETHER_API_KEY",
             @"openrouter":@"OPENROUTER_API_KEY",
             @"custom-openai":@"OPENMIND_CUSTOM_OPENAI_API_KEY",
             @"custom-anthropic":@"OPENMIND_CUSTOM_ANTHROPIC_API_KEY"};
}
+ (NSMutableDictionary *)query:(NSString *)provider {
    return [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService:@"com.openmind.omh.provider-credentials",
              (__bridge id)kSecAttrAccount:provider} mutableCopy];
}
+ (BOOL)saveToken:(NSString *)token provider:(NSString *)provider {
    if (![self names][provider] || !token.length) return NO;
    NSMutableDictionary *query=[self query:provider];
    NSData *data=[token dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *update=@{(__bridge id)kSecValueData:data};
    OSStatus status=SecItemUpdate((__bridge CFDictionaryRef)query,(__bridge CFDictionaryRef)update);
    if(status==errSecSuccess)return YES;
    if(status!=errSecItemNotFound)return NO;
    query[(__bridge id)kSecValueData]=data;
    query[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    return SecItemAdd((__bridge CFDictionaryRef)query,NULL)==errSecSuccess;
}
+ (void)removeProvider:(NSString *)provider {
    if ([self names][provider]) SecItemDelete((__bridge CFDictionaryRef)[self query:provider]);
}
+ (NSDictionary<NSString *,NSString *> *)environment {
    NSMutableDictionary *env=[NSMutableDictionary dictionary];
    [[self names] enumerateKeysAndObjectsUsingBlock:^(NSString *provider,NSString *key,BOOL *stop) {
        NSMutableDictionary *query=[self query:provider];
        query[(__bridge id)kSecReturnData]=@YES;
        query[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;
        CFTypeRef result=NULL;
        if (SecItemCopyMatching((__bridge CFDictionaryRef)query,&result)==errSecSuccess && result) {
            NSData *data=CFBridgingRelease(result);
            NSString *token=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if(token.length)env[key]=token;
        }
    }];
    return env;
}

#pragma mark - Custom providers

+ (BOOL)isCustomProvider:(NSString *)provider {
    return [provider isEqualToString:@"custom-openai"] || [provider isEqualToString:@"custom-anthropic"];
}
+ (NSString *)customURLKeyForProvider:(NSString *)provider {
    return [NSString stringWithFormat:@"omh.custom.%@.url", provider];
}
+ (NSString *)customModelKeyForProvider:(NSString *)provider {
    return [NSString stringWithFormat:@"omh.custom.%@.model", provider];
}
+ (NSString *)customProviderBaseURL:(NSString *)provider {
    if (![self isCustomProvider:provider]) return nil;
    NSString *url = [[NSUserDefaults standardUserDefaults] stringForKey:[self customURLKeyForProvider:provider]];
    url = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return url.length ? url : nil;
}
+ (NSString *)customProviderModel:(NSString *)provider {
    if (![self isCustomProvider:provider]) return nil;
    NSString *model = [[NSUserDefaults standardUserDefaults] stringForKey:[self customModelKeyForProvider:provider]];
    model = [model stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return model.length ? model : nil;
}
+ (void)saveCustomProvider:(NSString *)provider baseURL:(NSString *)baseURL model:(NSString *)model {
    if (![self isCustomProvider:provider]) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *url = [baseURL stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *modelID = [model stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (url.length) [defaults setObject:url forKey:[self customURLKeyForProvider:provider]];
    else [defaults removeObjectForKey:[self customURLKeyForProvider:provider]];
    if (modelID.length) [defaults setObject:modelID forKey:[self customModelKeyForProvider:provider]];
    else [defaults removeObjectForKey:[self customModelKeyForProvider:provider]];
}
+ (void)removeCustomProvider:(NSString *)provider {
    if (![self isCustomProvider:provider]) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:[self customURLKeyForProvider:provider]];
    [defaults removeObjectForKey:[self customModelKeyForProvider:provider]];
    [self removeProvider:provider];
}
@end

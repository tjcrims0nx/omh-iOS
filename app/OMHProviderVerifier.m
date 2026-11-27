#import "OMHProviderVerifier.h"
#import "OMHProviderCredentials.h"

@interface OMHNoRedirectDelegate : NSObject <NSURLSessionTaskDelegate>
@end

// Fixed, official HTTPS origins for the built-in providers. Never send a
// bearer token to an arbitrary URL. Custom providers (custom-openai,
// custom-anthropic) are the exception by design: the user explicitly
// configured that base URL, so the key is sent only to it, and redirects
// are still blocked so the key can never follow a redirect to another host.
@implementation OMHProviderVerifier
+ (NSDictionary<NSString *,NSString *> *)endpoints {
    return @{@"openai":@"https://api.openai.com/v1/models",
             @"anthropic":@"https://api.anthropic.com/v1/models",
             @"google":@"https://generativelanguage.googleapis.com/v1beta/models",
             @"deepseek":@"https://api.deepseek.com/models",
             @"zai":@"https://api.z.ai/api/paas/v4/models",
             @"moonshotai":@"https://api.moonshot.ai/v1/models",
             @"qwen":@"https://dashscope-intl.aliyuncs.com/compatible-mode/v1/models"};
}
+ (NSString *)customVerifyEndpointForProvider:(NSString *)provider {
    // Custom providers verify against the user-configured base URL.
    // custom-openai base URLs end in /v1, so /models is appended.
    // custom-anthropic base URLs are the API host, so /v1/models is appended.
    NSString *base = [OMHProviderCredentials customProviderBaseURL:provider];
    if (!base.length) return nil;
    while (base.length > 0 && [base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    if (!base.length) return nil;
    if ([provider isEqualToString:@"custom-openai"]) return [base stringByAppendingString:@"/models"];
    if ([provider isEqualToString:@"custom-anthropic"]) return [base stringByAppendingString:@"/v1/models"];
    return nil;
}
+ (void)verifyProvider:(NSString *)provider completion:(OMHProviderVerificationCompletion)completion {
    NSString *endpoint=[self endpoints][provider];
    if (!endpoint && [OMHProviderCredentials isCustomProvider:provider]) {
        endpoint = [self customVerifyEndpointForProvider:provider];
        if (!endpoint) { completion(@"Configure a base URL in Settings first"); return; }
    }
    if(!endpoint){completion(@"Verification unavailable for this provider");return;}
    NSDictionary *env=[OMHProviderCredentials environment];
    NSDictionary *keys=@{@"openai":@"OPENAI_API_KEY",@"anthropic":@"ANTHROPIC_API_KEY",
                         @"google":@"GEMINI_API_KEY",@"deepseek":@"DEEPSEEK_API_KEY",
                         @"zai":@"ZAI_API_KEY",@"moonshotai":@"MOONSHOT_API_KEY",
                         @"qwen":@"DASHSCOPE_API_KEY",
                         @"custom-openai":@"OPENMIND_CUSTOM_OPENAI_API_KEY",
                         @"custom-anthropic":@"OPENMIND_CUSTOM_ANTHROPIC_API_KEY"};
    NSString *token=env[keys[provider]];
    if(!token.length){completion(@"No API key saved");return;}
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    request.HTTPMethod=@"GET";
    request.timeoutInterval=8;
    if([provider isEqualToString:@"anthropic"] || [provider isEqualToString:@"custom-anthropic"]){
        [request setValue:token forHTTPHeaderField:@"x-api-key"];
        [request setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
    }else if([provider isEqualToString:@"google"]){
        [request setValue:token forHTTPHeaderField:@"x-goog-api-key"];
    }else{
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    }
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest=8;
    config.timeoutIntervalForResource=10;
    config.URLCache=nil;
    // Prevent redirects to another host from carrying provider credentials.
    NSURLSession *session=[NSURLSession sessionWithConfiguration:config delegate:[OMHNoRedirectDelegate new] delegateQueue:nil];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error) {
        NSInteger status=[(NSHTTPURLResponse *)response statusCode];
        NSString *result=error?@"Network verification failed":(status>=200&&status<300)?@"Verified":(status==401||status==403)?@"Credentials rejected":@"Provider verification failed";
        dispatch_async(dispatch_get_main_queue(),^{completion(result);});
        [session finishTasksAndInvalidate];
    }] resume];
}
@end

@implementation OMHNoRedirectDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);
}
@end

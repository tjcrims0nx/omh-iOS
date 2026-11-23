#import "OMHProviderVerifier.h"
#import "OMHProviderCredentials.h"

@interface OMHNoRedirectDelegate : NSObject <NSURLSessionTaskDelegate>
@end

// Fixed, official HTTPS origins. Never send a bearer token to an arbitrary URL.
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
+ (void)verifyProvider:(NSString *)provider completion:(OMHProviderVerificationCompletion)completion {
    NSString *endpoint=[self endpoints][provider];
    if(!endpoint){completion(@"Verification unavailable for this provider");return;}
    NSDictionary *env=[OMHProviderCredentials environment];
    NSDictionary *keys=@{@"openai":@"OPENAI_API_KEY",@"anthropic":@"ANTHROPIC_API_KEY",
                         @"google":@"GEMINI_API_KEY",@"deepseek":@"DEEPSEEK_API_KEY",
                         @"zai":@"ZAI_API_KEY",@"moonshotai":@"MOONSHOT_API_KEY",
                         @"qwen":@"DASHSCOPE_API_KEY"};
    NSString *token=env[keys[provider]];
    if(!token.length){completion(@"No API key saved");return;}
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    request.HTTPMethod=@"GET";
    request.timeoutInterval=8;
    if([provider isEqualToString:@"anthropic"]){
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

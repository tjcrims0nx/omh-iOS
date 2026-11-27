//
//  OMHApiClient.m
//  OMH
//
//  NSURLSession client for the harness backend served by the guest
//  dashboard (scripts/omh-dashboard.mjs). The iOS app is a local loopback
//  client, so authentication is CSRF, not Bearer: GET /api/session once
//  for the token, then send it as x-omh-csrf plus an Origin header
//  matching the base URL on every POST. No provider keys ever leave the
//  guest; this client only ever sends the CSRF token, provider ids and
//  message text.
//
//  Auth notes (from omh-dashboard.mjs):
//  - Every POST sends Origin: <scheme://host:port of baseURL> and
//    x-omh-csrf: <token> and Content-Type: application/json.
//  - GETs need no auth headers.
//  - The server also rejects requests whose Host does not match
//    (NSURLSession sets Host automatically; never override it) and
//    requests with a sec-fetch-site header other than same-origin/none
//    (NSURLSession does not send one; never add one).
//  - On a 403 the cached token is discarded, /api/session is re-fetched
//    once, and the POST is retried exactly once, then the error surfaces.
//

#import "OMHApiClient.h"
#import "OMHProviderCredentials.h"

NSString * const OMHApiClientErrorDomain = @"OMHApiClientErrorDomain";
NSString * const OMHApiHTTPStatusCodeKey = @"OMHApiHTTPStatusCodeKey";

static const NSTimeInterval OMHApiClientDefaultTimeout = 15.0;
static const NSTimeInterval OMHApiClientChatTimeout = 30.0; // 25s upstream + margin
static const NSUInteger OMHApiClientMaxChatMessages = 16;
static const NSUInteger OMHApiClientMaxMessageChars = 8000;
static const NSUInteger OMHApiClientMaxTotalMessageChars = 18000;
static const NSUInteger OMHApiClientMaxChatBodyBytes = 22000;

static void OMHApiClientCallOnMain(void (^block)(void)) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

@implementation OMHChatProvider
@end

@interface OMHApiClient ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, copy, nullable) NSString *csrfToken;
@end

@implementation OMHApiClient

- (instancetype)initWithBaseURL:(NSURL *)baseURL {
    self = [super init];
    if (self) {
        _baseURL = [baseURL copy];
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

#pragma mark - Errors

+ (NSError *)errorWithCode:(OMHApiErrorCode)code status:(NSInteger)status {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if (status > 0) {
        userInfo[OMHApiHTTPStatusCodeKey] = @(status);
    }
    return [NSError errorWithDomain:OMHApiClientErrorDomain code:code userInfo:userInfo];
}

+ (NSError *)errorForHTTPStatus:(NSInteger)status {
    OMHApiErrorCode code;
    if (status == 404) {
        code = OMHApiErrorCodeUnavailable;
    } else if (status == 503) {
        code = OMHApiErrorCodeNotConfigured;
    } else if (status == 401 || status == 403) {
        code = OMHApiErrorCodeUnauthorized;
    } else {
        code = OMHApiErrorCodeHTTP;
    }
    return [self errorWithCode:code status:status];
}

#pragma mark - Request plumbing

- (nullable NSURL *)URLForPath:(NSString *)path {
    return [NSURL URLWithString:path relativeToURL:self.baseURL];
}

// Origin is scheme://host:port from the base URL, no trailing slash.
- (NSString *)originHeaderValue {
    NSURL *baseURL = self.baseURL;
    NSString *scheme = baseURL.scheme ?: @"http";
    NSString *host = baseURL.host ?: @"127.0.0.1";
    NSString *origin = [NSString stringWithFormat:@"%@://%@", scheme, host];
    if (baseURL.port != nil) {
        origin = [origin stringByAppendingFormat:@":%@", baseURL.port];
    }
    return origin;
}

// GET with no auth headers. Completion runs on a background queue;
// public methods re-dispatch to the main queue before calling out.
- (void)performGET:(NSString *)path
           timeout:(NSTimeInterval)timeout
        completion:(void (^)(id _Nullable json, NSError * _Nullable error))completion {
    NSURL *url = [self URLForPath:path];
    if (url == nil) {
        completion(nil, [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0]);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = timeout;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
                                                 completionHandler:^(NSData * _Nullable data,
                                                                     NSURLResponse * _Nullable response,
                                                                     NSError * _Nullable error) {
        if (error != nil) {
            completion(nil, [OMHApiClient errorWithCode:OMHApiErrorCodeNetwork status:0]);
            return;
        }
        NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? (NSHTTPURLResponse *)response : nil;
        NSInteger status = httpResponse.statusCode;
        if (status < 200 || status >= 300) {
            completion(nil, [OMHApiClient errorForHTTPStatus:status]);
            return;
        }
        if (data == nil || data.length == 0) {
            completion(nil, [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0]);
            return;
        }
        NSError *jsonError = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError != nil || json == nil) {
            completion(nil, [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0]);
            return;
        }
        completion(json, nil);
    }];
    [task resume];
}

// Ensures a CSRF token is cached, fetching /api/session first if needed.
// Completion runs on whatever queue fetchSession uses (main for the
// cached-token fast path; see fetchSessionWithCompletion:).
- (void)ensureCSRFTokenWithCompletion:(void (^)(NSError * _Nullable error))completion {
    NSString *token = nil;
    @synchronized (self) {
        token = self.csrfToken;
    }
    if (token.length > 0) {
        completion(nil);
        return;
    }
    [self fetchSessionWithCompletion:completion];
}

// POST with Origin + x-omh-csrf + Content-Type: application/json.
// On a 403 the token is discarded, /api/session is re-fetched once and
// the POST is retried exactly once, then the error surfaces.
// A 2xx with an empty body completes with json == nil (action POSTs).
- (void)performPOST:(NSString *)path
               body:(NSDictionary *)body
            timeout:(NSTimeInterval)timeout
         completion:(void (^)(id _Nullable json, NSError * _Nullable error))completion {
    [self ensureCSRFTokenWithCompletion:^(NSError * _Nullable tokenError) {
        if (tokenError != nil) {
            completion(nil, tokenError);
            return;
        }
        [self sendPOST:path body:body timeout:timeout alreadyRetried:NO completion:completion];
    }];
}

- (void)sendPOST:(NSString *)path
            body:(NSDictionary *)body
         timeout:(NSTimeInterval)timeout
   alreadyRetried:(BOOL)alreadyRetried
        completion:(void (^)(id _Nullable json, NSError * _Nullable error))completion {
    NSURL *url = [self URLForPath:path];
    if (url == nil) {
        completion(nil, [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0]);
        return;
    }
    NSError *bodyError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&bodyError];
    if (bodyData == nil) {
        completion(nil, [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0]);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = timeout;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[self originHeaderValue] forHTTPHeaderField:@"Origin"];
    NSString *token = nil;
    @synchronized (self) {
        token = self.csrfToken;
    }
    if (token != nil) {
        [request setValue:token forHTTPHeaderField:@"x-omh-csrf"];
    }
    request.HTTPBody = bodyData;
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
                                                 completionHandler:^(NSData * _Nullable data,
                                                                     NSURLResponse * _Nullable response,
                                                                     NSError * _Nullable error) {
        if (error != nil) {
            completion(nil, [OMHApiClient errorWithCode:OMHApiErrorCodeNetwork status:0]);
            return;
        }
        NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? (NSHTTPURLResponse *)response : nil;
        NSInteger status = httpResponse.statusCode;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (status == 403 && !alreadyRetried && strongSelf != nil) {
            @synchronized (strongSelf) {
                strongSelf.csrfToken = nil;
            }
            [strongSelf fetchSessionWithCompletion:^(NSError * _Nullable fetchError) {
                if (fetchError != nil) {
                    // Could not refresh the token; surface the original 403.
                    completion(nil, [OMHApiClient errorForHTTPStatus:status]);
                    return;
                }
                [strongSelf sendPOST:path body:body timeout:timeout alreadyRetried:YES completion:completion];
            }];
            return;
        }
        if (status < 200 || status >= 300) {
            completion(nil, [OMHApiClient errorForHTTPStatus:status]);
            return;
        }
        if (data == nil || data.length == 0) {
            completion(nil, nil);
            return;
        }
        NSError *jsonError = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError != nil || json == nil) {
            completion(nil, [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0]);
            return;
        }
        completion(json, nil);
    }];
    [task resume];
}

#pragma mark - Session

- (void)fetchSessionWithCompletion:(void (^)(NSError * _Nullable error))completion {
    NSString *cached = nil;
    @synchronized (self) {
        cached = self.csrfToken;
    }
    if (cached.length > 0) {
        OMHApiClientCallOnMain(^{
            completion(nil);
        });
        return;
    }
    [self performGET:@"/api/session" timeout:OMHApiClientDefaultTimeout completion:^(id _Nullable json, NSError * _Nullable error) {
        NSError *resultError = error;
        if (resultError == nil) {
            NSString *token = nil;
            if ([json isKindOfClass:[NSDictionary class]]) {
                id rawToken = ((NSDictionary *)json)[@"csrf"];
                if ([rawToken isKindOfClass:[NSString class]]) {
                    token = (NSString *)rawToken;
                }
            }
            if (token.length > 0) {
                @synchronized (self) {
                    self.csrfToken = token;
                }
            } else {
                resultError = [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0];
            }
        }
        OMHApiClientCallOnMain(^{
            completion(resultError);
        });
    }];
}

#pragma mark - Chat

@interface OMHApiClientCustomNoRedirectDelegate : NSObject <NSURLSessionTaskDelegate>
@end

@implementation OMHApiClientCustomNoRedirectDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);
}
@end

#pragma mark - Custom providers (native direct call)

// Custom providers (custom-openai, custom-anthropic) are configured natively
// in the app and called directly at the user-configured endpoint, bypassing
// the harness backend (which only knows the 10 built-in providers). The API
// key is sent only to the configured base URL, on an ephemeral session whose
// delegate blocks redirects, so the key can never follow a redirect elsewhere.
+ (NSString *)customChatEndpointForProvider:(NSString *)providerId {
    NSString *base = [OMHProviderCredentials customProviderBaseURL:providerId];
    if (!base.length) return nil;
    while (base.length > 0 && [base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    if (!base.length) return nil;
    if ([providerId isEqualToString:@"custom-openai"]) return [base stringByAppendingString:@"/chat/completions"];
    if ([providerId isEqualToString:@"custom-anthropic"]) return [base stringByAppendingString:@"/v1/messages"];
    return nil;
}
+ (NSString *)customProviderAPIKey:(NSString *)providerId {
    NSDictionary *env = [OMHProviderCredentials environment];
    if ([providerId isEqualToString:@"custom-openai"]) return env[@"OPENMIND_CUSTOM_OPENAI_API_KEY"];
    if ([providerId isEqualToString:@"custom-anthropic"]) return env[@"OPENMIND_CUSTOM_ANTHROPIC_API_KEY"];
    return nil;
}
+ (BOOL)customProviderIsConfigured:(NSString *)providerId {
    return [OMHProviderCredentials customProviderBaseURL:providerId].length > 0
        && [OMHProviderCredentials customProviderModel:providerId].length > 0
        && [self customProviderAPIKey:providerId].length > 0;
}
+ (NSArray<OMHChatProvider *> *)customProviders {
    NSMutableArray<OMHChatProvider *> *out = [NSMutableArray array];
    for (NSString *providerId in @[@"custom-openai", @"custom-anthropic"]) {
        OMHChatProvider *provider = [[OMHChatProvider alloc] init];
        provider.providerId = providerId;
        provider.label = [providerId isEqualToString:@"custom-openai"] ? @"Custom OpenAI" : @"Custom Anthropic";
        NSString *model = [OMHProviderCredentials customProviderModel:providerId];
        provider.model = model.length ? model : @"Not configured";
        provider.available = [self customProviderIsConfigured:providerId];
        [out addObject:provider];
    }
    return [out copy];
}
// Direct call to a custom provider endpoint. `trimmed` is the validated
// message list (last 16, last is user). Completion delivers the assistant
// text and the configured model, or an error.
- (void)sendCustomChatWithProvider:(NSString *)providerId
                          messages:(NSArray<NSDictionary<NSString *, NSString *> *> *)trimmed
                        completion:(void (^)(NSString * _Nullable text, NSString * _Nullable model, NSError * _Nullable error))completion {
    NSString *endpoint = [OMHApiClient customChatEndpointForProvider:providerId];
    NSString *model = [OMHProviderCredentials customProviderModel:providerId];
    NSString *key = [OMHApiClient customProviderAPIKey:providerId];
    NSError *invalidError = [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0];
    if (!endpoint.length || !model.length || !key.length) {
        OMHApiClientCallOnMain(^{ completion(nil, nil, [OMHApiClient errorWithCode:OMHApiErrorCodeNotConfigured status:0]); });
        return;
    }
    NSURL *url = [NSURL URLWithString:endpoint];
    if (!url) {
        OMHApiClientCallOnMain(^{ completion(nil, nil, invalidError); });
        return;
    }
    NSDictionary *body = nil;
    if ([providerId isEqualToString:@"custom-openai"]) {
        body = @{@"model": model, @"messages": trimmed};
    } else {
        // Anthropic requires messages to alternate and start with a user
        // turn. The conversation alternates by construction, but trimming
        // to the last 16 can leave a leading assistant turn; drop it.
        NSMutableArray *anthropicMessages = [NSMutableArray array];
        for (NSDictionary *entry in trimmed) {
            if (anthropicMessages.count == 0 && [entry[@"role"] isEqualToString:@"assistant"]) continue;
            [anthropicMessages addObject:entry];
        }
        if (anthropicMessages.count == 0) {
            OMHApiClientCallOnMain(^{ completion(nil, nil, invalidError); });
            return;
        }
        body = @{@"model": model, @"max_tokens": @1024, @"messages": anthropicMessages};
    }
    NSError *bodyError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&bodyError];
    if (bodyData == nil || bodyData.length > OMHApiClientMaxChatBodyBytes) {
        OMHApiClientCallOnMain(^{ completion(nil, nil, invalidError); });
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = bodyData;
    request.timeoutInterval = OMHApiClientChatTimeout;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if ([providerId isEqualToString:@"custom-anthropic"]) {
        [request setValue:key forHTTPHeaderField:@"x-api-key"];
        [request setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
    } else {
        [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    }
    // Ephemeral session with a delegate that blocks redirects, so the
    // provider key is never carried to another host.
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.URLCache = nil;
    NSURLSession *customSession = [NSURLSession sessionWithConfiguration:config delegate:[OMHApiClientCustomNoRedirectDelegate new] delegateQueue:nil];
    [[customSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *text = nil;
        NSError *resultError = error;
        if (resultError == nil) {
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            if (status < 200 || status >= 300) {
                resultError = [OMHApiClient errorWithCode:OMHApiErrorCodeHTTP status:status];
            } else if (data) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([providerId isEqualToString:@"custom-openai"]) {
                    NSArray *choices = [json isKindOfClass:[NSDictionary class]] ? json[@"choices"] : nil;
                    NSDictionary *first = [choices isKindOfClass:[NSArray class]] && choices.count > 0 ? choices[0] : nil;
                    NSDictionary *message = [first isKindOfClass:[NSDictionary class]] ? first[@"message"] : nil;
                    id content = [message isKindOfClass:[NSDictionary class]] ? message[@"content"] : nil;
                    if ([content isKindOfClass:[NSString class]] && ((NSString *)content).length > 0) text = (NSString *)content;
                } else {
                    NSArray *content = [json isKindOfClass:[NSDictionary class]] ? json[@"content"] : nil;
                    for (id block in [content isKindOfClass:[NSArray class]] ? content : @[]) {
                        if ([block isKindOfClass:[NSDictionary class]] && [block[@"type"] isEqualToString:@"text"]) {
                            id blockText = block[@"text"];
                            if ([blockText isKindOfClass:[NSString class]] && ((NSString *)blockText).length > 0) { text = (NSString *)blockText; break; }
                        }
                    }
                }
                if (text == nil) resultError = [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0];
            } else {
                resultError = [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0];
            }
        }
        NSString *modelCopy = model;
        OMHApiClientCallOnMain(^{ completion(text, modelCopy, resultError); });
        [customSession finishTasksAndInvalidate];
    }] resume];
}

- (void)fetchChatProvidersWithCompletion:(void (^)(NSArray<OMHChatProvider *> * _Nullable providers, NSError * _Nullable error))completion {
    [self performGET:@"/api/chat" timeout:OMHApiClientDefaultTimeout completion:^(id _Nullable json, NSError * _Nullable error) {
        NSArray<OMHChatProvider *> *providers = nil;
        NSError *resultError = error;
        if (resultError == nil) {
            NSArray *rawProviders = nil;
            if ([json isKindOfClass:[NSDictionary class]]) {
                id raw = ((NSDictionary *)json)[@"providers"];
                if ([raw isKindOfClass:[NSArray class]]) {
                    rawProviders = (NSArray *)raw;
                }
            }
            if (rawProviders == nil) {
                resultError = [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0];
            } else {
                NSMutableArray<OMHChatProvider *> *parsed = [NSMutableArray arrayWithCapacity:rawProviders.count];
                BOOL valid = YES;
                for (id entry in rawProviders) {
                    if (![entry isKindOfClass:[NSDictionary class]]) {
                        valid = NO;
                        break;
                    }
                    NSDictionary *dict = (NSDictionary *)entry;
                    id providerId = dict[@"id"];
                    id label = dict[@"label"];
                    id model = dict[@"model"];
                    id available = dict[@"available"];
                    if (![providerId isKindOfClass:[NSString class]] ||
                        ![label isKindOfClass:[NSString class]] ||
                        ![model isKindOfClass:[NSString class]]) {
                        valid = NO;
                        break;
                    }
                    OMHChatProvider *provider = [[OMHChatProvider alloc] init];
                    provider.providerId = (NSString *)providerId;
                    provider.label = (NSString *)label;
                    provider.model = (NSString *)model;
                    provider.available = [available isKindOfClass:[NSNumber class]]
                        ? [(NSNumber *)available boolValue] : NO;
                    [parsed addObject:provider];
                }
                if (valid) {
                    // The harness backend lists only the 10 built-in
                    // providers. Custom providers are configured natively
                    // in the app, so they are appended here.
                    NSMutableArray<OMHChatProvider *> *all = [parsed mutableCopy];
                    [all addObjectsFromArray:[OMHApiClient customProviders]];
                    providers = [all copy];
                } else {
                    resultError = [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0];
                }
            }
        }
        OMHApiClientCallOnMain(^{
            completion(providers, resultError);
        });
    }];
}

// STREAMING: the backend is non-streaming (one request, one response,
// 25s upstream timeout). This method waits for the full response;
// callers show a spinner and a timeout. True streaming needs a backend
// route that does not exist yet — do not fake it here.
- (void)sendChatWithProvider:(NSString *)providerId
                     messages:(NSArray<NSDictionary<NSString *, NSString *> *> *)messages
                   completion:(void (^)(NSString * _Nullable text, NSString * _Nullable model, NSError * _Nullable error))completion {
    NSError *invalidError = [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0];

    // Client-side validation. Any failure returns InvalidResponse
    // without sending a request.
    if (![providerId isKindOfClass:[NSString class]] || providerId.length == 0) {
        OMHApiClientCallOnMain(^{
            completion(nil, nil, invalidError);
        });
        return;
    }
    // Trim to the last 16 entries before validating/sending.
    NSArray *trimmed = messages;
    if (messages.count > OMHApiClientMaxChatMessages) {
        trimmed = [messages subarrayWithRange:NSMakeRange(messages.count - OMHApiClientMaxChatMessages,
                                                         OMHApiClientMaxChatMessages)];
    }
    if (trimmed.count < 1 || trimmed.count > OMHApiClientMaxChatMessages) {
        OMHApiClientCallOnMain(^{
            completion(nil, nil, invalidError);
        });
        return;
    }
    NSUInteger totalChars = 0;
    BOOL valid = YES;
    for (id entry in trimmed) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            valid = NO;
            break;
        }
        NSDictionary *message = (NSDictionary *)entry;
        id role = message[@"role"];
        id content = message[@"content"];
        if (![role isKindOfClass:[NSString class]] ||
            (![(NSString *)role isEqualToString:@"user"] && ![(NSString *)role isEqualToString:@"assistant"]) ||
            ![content isKindOfClass:[NSString class]] ||
            ((NSString *)content).length < 1 ||
            ((NSString *)content).length > OMHApiClientMaxMessageChars) {
            valid = NO;
            break;
        }
        totalChars += ((NSString *)content).length;
    }
    if (valid && totalChars > OMHApiClientMaxTotalMessageChars) {
        valid = NO;
    }
    if (valid) {
        NSDictionary *lastMessage = (NSDictionary *)trimmed.lastObject;
        id lastRole = lastMessage[@"role"];
        if (![lastRole isKindOfClass:[NSString class]] || ![(NSString *)lastRole isEqualToString:@"user"]) {
            valid = NO;
        }
    }
    if (!valid) {
        OMHApiClientCallOnMain(^{
            completion(nil, nil, invalidError);
        });
        return;
    }
    // Custom providers are called directly at the user-configured
    // endpoint (OpenAI-compatible or Anthropic protocol), not via
    // the harness backend, which does not know them.
    if ([OMHProviderCredentials isCustomProvider:providerId]) {
        [self sendCustomChatWithProvider:providerId messages:trimmed completion:completion];
        return;
    }
    NSDictionary *body = @{@"provider": providerId, @"messages": trimmed};
    NSError *bodyError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&bodyError];
    if (bodyData == nil || bodyData.length > OMHApiClientMaxChatBodyBytes) {
        OMHApiClientCallOnMain(^{
            completion(nil, nil, invalidError);
        });
        return;
    }
    [self performPOST:@"/api/chat" body:body timeout:OMHApiClientChatTimeout completion:^(id _Nullable json, NSError * _Nullable error) {
        NSString *text = nil;
        NSString *model = nil;
        NSError *resultError = error;
        if (resultError == nil) {
            if ([json isKindOfClass:[NSDictionary class]]) {
                id rawText = ((NSDictionary *)json)[@"text"];
                id rawModel = ((NSDictionary *)json)[@"model"];
                if ([rawText isKindOfClass:[NSString class]] && [rawModel isKindOfClass:[NSString class]]) {
                    text = (NSString *)rawText;
                    model = (NSString *)rawModel;
                }
            }
            if (text == nil || model == nil) {
                resultError = [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0];
            }
        }
        OMHApiClientCallOnMain(^{
            completion(text, model, resultError);
        });
    }];
}

#pragma mark - State & connectors

- (void)fetchStateWithCompletion:(void (^)(NSDictionary * _Nullable state, NSError * _Nullable error))completion {
    [self performGET:@"/api/state" timeout:OMHApiClientDefaultTimeout completion:^(id _Nullable json, NSError * _Nullable error) {
        NSDictionary *state = nil;
        NSError *resultError = error;
        if (resultError == nil) {
            if ([json isKindOfClass:[NSDictionary class]]) {
                state = (NSDictionary *)json;
            } else {
                resultError = [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0];
            }
        }
        OMHApiClientCallOnMain(^{
            completion(state, resultError);
        });
    }];
}

- (void)fetchConnectorsWithCompletion:(void (^)(NSArray<NSDictionary *> * _Nullable providers, NSError * _Nullable error))completion {
    [self performGET:@"/api/connectors" timeout:OMHApiClientDefaultTimeout completion:^(id _Nullable json, NSError * _Nullable error) {
        NSArray<NSDictionary *> *providers = nil;
        NSError *resultError = error;
        if (resultError == nil) {
            NSArray *rawProviders = nil;
            if ([json isKindOfClass:[NSDictionary class]]) {
                id raw = ((NSDictionary *)json)[@"providers"];
                if ([raw isKindOfClass:[NSArray class]]) {
                    rawProviders = (NSArray *)raw;
                }
            }
            if (rawProviders == nil) {
                resultError = [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0];
            } else {
                BOOL valid = YES;
                for (id entry in rawProviders) {
                    if (![entry isKindOfClass:[NSDictionary class]]) {
                        valid = NO;
                        break;
                    }
                }
                if (valid) {
                    providers = (NSArray<NSDictionary *> *)rawProviders;
                } else {
                    resultError = [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0];
                }
            }
        }
        OMHApiClientCallOnMain(^{
            completion(providers, resultError);
        });
    }];
}

- (void)verifyConnector:(NSString *)providerId
              completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion {
    // Requires the dashboard admin token, which the iOS guest does not
    // set, so this returns 403 (OMHApiErrorCodeUnauthorized) on iOS.
    // Callers surface that; do not retry.
    if (![providerId isKindOfClass:[NSString class]] || providerId.length == 0) {
        NSError *invalidError = [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0];
        OMHApiClientCallOnMain(^{
            completion(nil, invalidError);
        });
        return;
    }
    [self performPOST:@"/api/connectors/verify"
                 body:@{@"id": providerId}
              timeout:OMHApiClientDefaultTimeout
           completion:^(id _Nullable json, NSError * _Nullable error) {
        NSDictionary *result = nil;
        NSError *resultError = error;
        if (resultError == nil) {
            if ([json isKindOfClass:[NSDictionary class]]) {
                result = (NSDictionary *)json;
            } else {
                resultError = [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0];
            }
        }
        OMHApiClientCallOnMain(^{
            completion(result, resultError);
        });
    }];
}

#pragma mark - Evidence

- (void)fetchEvidenceStatusWithCompletion:(void (^)(NSDictionary * _Nullable status, NSError * _Nullable error))completion {
    [self performGET:@"/api/plugins/omjb" timeout:OMHApiClientDefaultTimeout completion:^(id _Nullable json, NSError * _Nullable error) {
        NSDictionary *status = nil;
        NSError *resultError = error;
        if (resultError == nil) {
            if ([json isKindOfClass:[NSDictionary class]]) {
                status = (NSDictionary *)json;
            } else {
                resultError = [OMHApiClient errorWithCode:OMHApiErrorCodeInvalidResponse status:0];
            }
        }
        OMHApiClientCallOnMain(^{
            completion(status, resultError);
        });
    }];
}

#pragma mark - Generic actions

- (void)performAction:(NSString *)path
                 body:(NSDictionary *)body
           completion:(void (^)(NSError * _Nullable error))completion {
    [self performPOST:path body:body timeout:OMHApiClientDefaultTimeout completion:^(id _Nullable json, NSError * _Nullable error) {
        // Any 2xx is success; the response body (if any) is not needed.
        OMHApiClientCallOnMain(^{
            completion(error);
        });
    }];
}

@end

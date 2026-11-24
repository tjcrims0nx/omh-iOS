//
//  OMHApiClient.h
//  OMH
//
//  Small NSURLSession client for the harness backend served by the guest
//  dashboard (scripts/omh-dashboard.mjs). The iOS app is a local loopback
//  client, so authentication is CSRF, not Bearer: GET /api/session once for
//  the token, then send it as x-omh-csrf plus an Origin header matching the
//  base URL on every POST. No provider keys ever leave the guest; this
//  client only ever sends the CSRF token, provider ids and message text.
//
//  Endpoint notes (verified against harness main c7f254e):
//  - GET /api/chat -> {providers:[{id,label,model,available}]}
//  - POST /api/chat {provider, messages:[{role,content}]} -> {provider,model,text}
//    Messages: 1..16 entries, each role user|assistant, content 1..8000 chars,
//    total <= 18000 chars, last message must be role "user", body <= 22000 bytes.
//    The upstream provider call has a 25s timeout and is NON-STREAMING.
//  - GET /api/state -> runtime state (version, counts, agents, tasks,
//    workflowSteps, skills, plugins, sandbox, schedules, memory, traces,
//    workspaces, providers, evidenceMcp, adminActionsAvailable)
//  - GET /api/connectors -> {providers:[{id,method,status,verified}]}
//  - POST /api/connectors/verify {id} -> verification result. Requires the
//    dashboard admin token, which the iOS guest does not set, so this
//    returns 403 (unauthorized) on iOS; callers must surface that, not retry.
//  - GET /api/plugins/omjb -> evidence MCP status {name,enabled,connected,
//    state,restarts,lastError,lastPingAt,tools,dbPath,pid}
//  - Action POSTs, all {id} except plugins (which take {name}) and omjb
//    (which take {}): /api/tasks/cancel|retry, /api/schedules/pause|resume,
//    /api/plugins/enable|disable, /api/skills/accept|reject,
//    /api/plugins/omjb/retry|enable|disable.
//    Privileged actions (admin token required, 403 on iOS):
//    /api/schedules/resume, /api/plugins/enable, /api/skills/accept,
//    /api/plugins/omjb/enable.
//
//  Harness-version note: the pinned harness (e754cec) predates /api/chat
//  and /api/plugins/omjb, so those return 404 (OMHApiErrorCodeUnavailable)
//  until the pin is bumped. Callers must handle that as "not available on
//  this harness version", not as a crash or a retry loop.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const OMHApiClientErrorDomain;
extern NSString * const OMHApiHTTPStatusCodeKey;

typedef NS_ENUM(NSInteger, OMHApiErrorCode) {
    OMHApiErrorCodeNetwork = 1,        // NSURLSession transport error
    OMHApiErrorCodeHTTP = 2,           // non-2xx; OMHApiHTTPStatusCodeKey holds the status
    OMHApiErrorCodeInvalidResponse = 3, // body is not the expected JSON shape
    OMHApiErrorCodeUnavailable = 4,     // HTTP 404: endpoint absent on this harness version
    OMHApiErrorCodeNotConfigured = 5,   // HTTP 503: selected provider has no key on the server
    OMHApiErrorCodeUnauthorized = 6,    // HTTP 401/403: CSRF mismatch or admin token required
};

@interface OMHChatProvider : NSObject
@property (nonatomic, copy) NSString *providerId;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *model;
@property (nonatomic, assign) BOOL available;
@end

@interface OMHApiClient : NSObject

- (instancetype)initWithBaseURL:(NSURL *)baseURL;
@property (nonatomic, readonly) NSURL *baseURL;

/// GET /api/session. Caches the CSRF token for later POSTs. Safe to call
/// repeatedly; a cached token is reused until a POST is rejected with 403,
/// after which the next POST re-fetches it once and retries.
- (void)fetchSessionWithCompletion:(void (^)(NSError * _Nullable error))completion;

/// GET /api/chat. Returns the 10 chat providers with model + availability.
- (void)fetchChatProvidersWithCompletion:(void (^)(NSArray<OMHChatProvider *> * _Nullable providers, NSError * _Nullable error))completion;

/// POST /api/chat. `messages` is the full conversation to send, including
/// the new user message as the last entry; the client trims it to the last
/// 16 entries and enforces the server limits before sending. Completion
/// delivers the assistant text and the model that produced it.
/// STREAMING: the backend is non-streaming (one request, one response, 25s
/// upstream timeout). This method waits for the full response; callers show
/// a spinner and a timeout. True streaming needs a backend route that does
/// not exist yet — do not fake it here.
- (void)sendChatWithProvider:(NSString *)providerId
                     messages:(NSArray<NSDictionary<NSString *, NSString *> *> *)messages
                   completion:(void (^)(NSString * _Nullable text, NSString * _Nullable model, NSError * _Nullable error))completion;

/// GET /api/state. Returns the raw state dictionary (see header comment).
- (void)fetchStateWithCompletion:(void (^)(NSDictionary * _Nullable state, NSError * _Nullable error))completion;

/// GET /api/connectors. Returns the providers array
/// [{id,method,status,verified}] where status is configured|disconnected.
- (void)fetchConnectorsWithCompletion:(void (^)(NSArray<NSDictionary *> * _Nullable providers, NSError * _Nullable error))completion;

/// POST /api/connectors/verify {id}. Requires the dashboard admin token;
/// on iOS this returns OMHApiErrorCodeUnauthorized. Implemented for
/// completeness; callers surface the result, they do not retry it.
- (void)verifyConnector:(NSString *)providerId
              completion:(void (^)(NSDictionary * _Nullable result, NSError * _Nullable error))completion;

/// GET /api/plugins/omjb. Returns the evidence MCP status dictionary.
- (void)fetchEvidenceStatusWithCompletion:(void (^)(NSDictionary * _Nullable status, NSError * _Nullable error))completion;

/// Generic action POST. `path` is e.g. @"/api/tasks/cancel".
/// `body` is the JSON object: {id} for tasks/schedules/skills,
/// {name} for plugins, {} for omjb actions. Sends Origin + x-omh-csrf.
/// On a 403 the CSRF token is re-fetched once and the request retried.
- (void)performAction:(NSString *)path
                 body:(NSDictionary *)body
           completion:(void (^)(NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

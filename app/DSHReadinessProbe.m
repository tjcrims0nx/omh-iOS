//
//  DSHReadinessProbe.m
//  DSH
//

#import "DSHReadinessProbe.h"

@interface DSHReadinessProbe ()
@property (nonatomic) NSURL *url;
@property (nonatomic) NSTimeInterval interval;
@property (nonatomic) NSTimeInterval timeout;
@property (nonatomic, copy, nullable) DSHReadinessHandler handler;
@property (nonatomic) NSDate *startedAt;
@property (nonatomic) NSUInteger generation;
@property (nonatomic, readwrite, getter=isRunning) BOOL running;
@end

@implementation DSHReadinessProbe

+ (NSURLSession *)ephemeralSession {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 3;
    config.timeoutIntervalForResource = 3;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    config.waitsForConnectivity = NO;
    return [NSURLSession sessionWithConfiguration:config];
}

- (instancetype)initWithURL:(NSURL *)url interval:(NSTimeInterval)interval timeout:(NSTimeInterval)timeout {
    if (self = [super init]) {
        _url = url;
        _interval = MAX(interval, 0.05);
        _timeout = timeout;
        _session = [DSHReadinessProbe ephemeralSession];
    }
    return self;
}

- (void)startWithHandler:(DSHReadinessHandler)handler {
    NSAssert(NSThread.isMainThread, @"start on main");
    [self cancel];
    self.handler = handler;
    self.startedAt = NSDate.date;
    self.running = YES;
    self.generation++;
    [self probeWithGeneration:self.generation];
}

- (void)cancel {
    NSAssert(NSThread.isMainThread, @"cancel on main");
    if (!self.running)
        return;
    self.running = NO;
    self.generation++;
    DSHReadinessHandler handler = self.handler;
    self.handler = nil;
    if (handler)
        handler(NO, -self.startedAt.timeIntervalSinceNow);
}

- (void)finish:(BOOL)ready {
    if (!self.running)
        return;
    self.running = NO;
    self.generation++;
    DSHReadinessHandler handler = self.handler;
    self.handler = nil;
    if (handler)
        handler(ready, -self.startedAt.timeIntervalSinceNow);
}

- (void)probeWithGeneration:(NSUInteger)generation {
    if (generation != self.generation || !self.running)
        return;
    if (self.timeout > 0 && -self.startedAt.timeIntervalSinceNow > self.timeout) {
        [self finish:NO];
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:self.url];
    req.HTTPMethod = @"GET";
    req.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL ok = NO;
        if ([response isKindOfClass:NSHTTPURLResponse.class]) {
            NSInteger code = ((NSHTTPURLResponse *) response).statusCode;
            // A 404/405 can come from an unrelated listener or an unready
            // guest server. Require a successful endpoint response.
            ok = code >= 200 && code < 400;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (self == nil || generation != self.generation || !self.running)
                return;
            if (ok) {
                [self finish:YES];
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (self.interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf probeWithGeneration:generation];
            });
        });
    }];
    [task resume];
}

+ (void)checkURL:(NSURL *)url timeout:(NSTimeInterval)timeout completion:(void (^)(BOOL))completion {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = timeout;
    config.timeoutIntervalForResource = timeout;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL ok = NO;
        if ([response isKindOfClass:NSHTTPURLResponse.class])
            ok = ((NSHTTPURLResponse *) response).statusCode >= 200 && ((NSHTTPURLResponse *) response).statusCode < 400;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok); });
        [session finishTasksAndInvalidate];
    }] resume];
}

@end

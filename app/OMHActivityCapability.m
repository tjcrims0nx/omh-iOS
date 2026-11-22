//
//  OMHActivityCapability.m
//  OMH
//

#import "OMHActivityCapability.h"
#import "OMHHostBridge.h"
#import "OMHActivityLog.h"

/// A turn can report a burst; accept them in one request rather than one
/// connection each.
static const NSUInteger kMaxBatch = 50;

@implementation OMHActivityCapability

+ (void)installOn:(OMHHostBridge *)bridge {
    [bridge registerRoute:@"POST" path:@"/v1/activity" capability:nil
                  handler:^OMHHostBridgeResponse *(OMHHostBridgeRequest *request) {
        NSArray *events = request.json[@"events"];
        if (![events isKindOfClass:NSArray.class])
            return [OMHHostBridgeResponse errorWithStatus:400 code:@"invalid_request"
                                                  message:@"send {\"events\": [...]}"
                                              recoverable:NO];
        NSUInteger accepted = 0;
        for (NSDictionary *event in events) {
            if (accepted >= kMaxBatch)
                break;
            if (![event isKindOfClass:NSDictionary.class])
                continue;
            NSString *name = event[@"name"];
            if (![name isKindOfClass:NSString.class] || name.length == 0)
                continue;
            NSString *status = event[@"outcome"];
            OMHActivityOutcome outcome = OMHActivityOutcomeOK;
            if ([status isEqualToString:@"error"]) outcome = OMHActivityOutcomeError;
            else if ([status isEqualToString:@"refused"]) outcome = OMHActivityOutcomeRefused;
            else if ([status isEqualToString:@"declined"]) outcome = OMHActivityOutcomeDeclined;
            else if ([status isEqualToString:@"started"]) outcome = OMHActivityOutcomeStarted;

            [OMHActivityLog.shared recordSource:OMHActivitySourceGuestTool
                                           name:name
                                         detail:[event[@"detail"] isKindOfClass:NSString.class] ? event[@"detail"] : nil
                                         result:[event[@"result"] isKindOfClass:NSString.class] ? event[@"result"] : nil
                                        outcome:outcome
                                       duration:[event[@"duration"] doubleValue]
                                  correlationID:[event[@"id"] isKindOfClass:NSString.class] ? event[@"id"] : nil];
            accepted += 1;
        }
        return [OMHHostBridgeResponse ok:@{ @"accepted": @(accepted) }];
    }];
}

@end

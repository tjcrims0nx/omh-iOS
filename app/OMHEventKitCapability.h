//
//  OMHEventKitCapability.h
//  OMH
//
//  Calendar and Reminders over EventKit — reading, and creating.
//
//  Reading is gated twice: the user's switch in OMH's settings, and iOS's own
//  permission dialog. A call that arrives before the system has been asked
//  triggers the request and answers `permission_denied` with `recoverable`,
//  rather than blocking the agent's turn on a dialog (docs/host-bridge.md §2).
//
//  Creating an event or a reminder is gated a third time, per call: the switch
//  is old consent to a kind of access, not consent to put this particular thing
//  in the user's calendar today (OMHCallConfirmation).
//

#import <Foundation/Foundation.h>
@class OMHHostBridge;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const OMHCapabilityCalendarRead;
extern NSString *const OMHCapabilityRemindersRead;
extern NSString *const OMHCapabilityCalendarWrite;
extern NSString *const OMHCapabilityRemindersWrite;

@interface OMHEventKitCapability : NSObject

/// Registers the capabilities and adds the `/v1/calendar/*` and `/v1/reminders`
/// routes, reading and writing.
+ (void)installOn:(OMHHostBridge *)bridge;

/// Parses the date formats the guest may send: ISO 8601, or `YYYY-MM-DD HH:mm`
/// and `YYYY-MM-DD` in the device's own time zone (what a model usually writes).
+ (nullable NSDate *)dateFromString:(NSString *)string;

/// Events in the next `days` days (or the past when negative), newest first,
/// at most `limit`. Returns the route's JSON body.
+ (NSDictionary *)eventsWithinDays:(NSInteger)days limit:(NSInteger)limit;
/// Reminders, optionally including completed ones.
+ (NSDictionary *)remindersIncludingCompleted:(BOOL)includeCompleted limit:(NSInteger)limit;

@end

NS_ASSUME_NONNULL_END

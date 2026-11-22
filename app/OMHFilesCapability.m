//
//  OMHFilesCapability.m
//  OMH
//

#import "OMHFilesCapability.h"
#import "OMHHostBridge.h"
#import "OMHCapability.h"
#import "OMHCallConfirmation.h"
#import "OMHHarness.h"
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NSString *const OMHCapabilityFilesImport = @"files.import";
NSString *const OMHCapabilityFilesExport = @"files.export";

/// Everything crosses the bridge base64-encoded inside a JSON body, so this is
/// a real ceiling, not a formality.
static const NSUInteger kMaxBytes = 8 * 1024 * 1024;
/// The picker is a human interaction; give it room but not forever.
static const NSTimeInterval kPickerTimeout = 120;

#pragma mark - Picker plumbing

/// Presents a document picker and turns its delegate callbacks back into a
/// blocking call for the bridge handler.
@interface OMHDocumentPicker : NSObject <UIDocumentPickerDelegate>
@property (nonatomic) NSURL *pickedURL;
@property (nonatomic) BOOL cancelled;
@property (nonatomic) dispatch_semaphore_t done;
@end

@implementation OMHDocumentPicker

- (instancetype)init {
    if (self = [super init])
        _done = dispatch_semaphore_create(0);
    return self;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    self.pickedURL = urls.firstObject;
    dispatch_semaphore_signal(self.done);
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.cancelled = YES;
    dispatch_semaphore_signal(self.done);
}

@end

@implementation OMHFilesCapability

+ (NSUInteger)maximumBytes { return kMaxBytes; }

+ (nullable UIViewController *)topViewController {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive)
            continue;
        for (UIWindow *candidate in ((UIWindowScene *) scene).windows)
            if (candidate.isKeyWindow) { window = candidate; break; }
        if (window) break;
    }
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController)
        controller = controller.presentedViewController;
    return controller;
}

+ (OMHHostBridgeResponse *)noForegroundUI {
    return [OMHHostBridgeResponse errorWithStatus:409 code:@"unavailable"
                                          message:@"OpenMind Harness is not in the foreground, so it cannot show the file picker. Ask the user to open OpenMind Harness and try again."
                                      recoverable:YES];
}

#pragma mark - Routes

+ (void)installOn:(OMHHostBridge *)bridge {
    OMHCapabilityRegistry *registry = OMHCapabilityRegistry.shared;
    [registry registerCapability:[[OMHCapability alloc] initWithIdentifier:OMHCapabilityFilesImport
                                                                    title:@"Files (import)"
                                                                  details:@"Opens the file picker so you can hand a file to the agent. You choose the file."
                                                                     gate:OMHCapabilityGateEnabledOnly
                                                         enabledByDefault:YES
                                                                available:YES]];
    [registry registerCapability:[[OMHCapability alloc] initWithIdentifier:OMHCapabilityFilesExport
                                                                    title:@"Files (export)"
                                                                  details:@"Lets the agent save a file out of OpenMind Harness; you choose where it goes."
                                                                     gate:OMHCapabilityGatePerCall
                                                         enabledByDefault:YES
                                                                available:YES]];

    // Import: the picker *is* the confirmation, so there is no extra prompt.
    [bridge registerRoute:@"POST" path:@"/v1/files/import" capability:OMHCapabilityFilesImport
                  handler:^OMHHostBridgeResponse *(OMHHostBridgeRequest *request) {
        OMHDocumentPicker *picker = [OMHDocumentPicker new];
        __block BOOL presented = NO;
        OMHRunOnMainSync(^{
            UIViewController *top = [self topViewController];
            if (top == nil)
                return;
            UIDocumentPickerViewController *controller =
                [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
            controller.delegate = picker;
            controller.allowsMultipleSelection = NO;
            [top presentViewController:controller animated:YES completion:nil];
            presented = YES;
        });
        if (!presented)
            return [self noForegroundUI];

        dispatch_semaphore_wait(picker.done, dispatch_time(DISPATCH_TIME_NOW, (int64_t) (kPickerTimeout * NSEC_PER_SEC)));
        if (picker.cancelled || picker.pickedURL == nil)
            return [OMHHostBridgeResponse errorWithStatus:403 code:@"permission_denied"
                                                  message:@"The user closed the file picker without choosing anything."
                                              recoverable:NO];

        NSURL *url = picker.pickedURL;
        NSNumber *size = nil;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (size.unsignedLongLongValue > kMaxBytes)
            return [OMHHostBridgeResponse errorWithStatus:413 code:@"invalid_request"
                                                  message:[NSString stringWithFormat:@"“%@” is %.1f MB; the bridge carries at most %lu MB.",
                                                           url.lastPathComponent, size.doubleValue / 1024 / 1024, (unsigned long) (kMaxBytes / 1024 / 1024)]
                                              recoverable:NO];

        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
        if (data == nil)
            return [OMHHostBridgeResponse errorWithStatus:500 code:@"internal"
                                                  message:[NSString stringWithFormat:@"Could not read the chosen file: %@", error.localizedDescription]
                                              recoverable:NO];
        return [OMHHostBridgeResponse ok:@{
            @"name": url.lastPathComponent ?: @"file",
            @"bytes": @(data.length),
            @"base64": [data base64EncodedStringWithOptions:0],
        }];
    }];

    // Export: the agent chose the contents and the name, so it asks first and
    // only then shows the picker.
    [bridge registerRoute:@"POST" path:@"/v1/files/export" capability:OMHCapabilityFilesExport
                  handler:^OMHHostBridgeResponse *(OMHHostBridgeRequest *request) {
        NSString *name = request.json[@"name"];
        NSString *base64 = request.json[@"base64"];
        if (![name isKindOfClass:NSString.class] || name.length == 0 || ![base64 isKindOfClass:NSString.class])
            return [OMHHostBridgeResponse errorWithStatus:400 code:@"invalid_request"
                                                  message:@"Send a JSON body with `name` and base64-encoded `base64` contents."
                                              recoverable:NO];
        NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (data == nil)
            return [OMHHostBridgeResponse errorWithStatus:400 code:@"invalid_request"
                                                  message:@"`base64` is not valid base64."
                                              recoverable:NO];
        if (data.length > kMaxBytes)
            return [OMHHostBridgeResponse errorWithStatus:413 code:@"invalid_request"
                                                  message:[NSString stringWithFormat:@"That is %.1f MB; the bridge carries at most %lu MB.",
                                                           data.length / 1024.0 / 1024.0, (unsigned long) (kMaxBytes / 1024 / 1024)]
                                              recoverable:NO];
        // A name from the guest must not be able to escape the temp directory.
        NSString *safeName = [[name lastPathComponent] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        if (safeName.length == 0 || [safeName hasPrefix:@"."])
            safeName = [@"export-" stringByAppendingString:safeName];

        OMHConfirmationOutcome outcome =
            [OMHCallConfirmation confirmTitle:@"Save a file out of OpenMind Harness?"
                                       detail:[NSString stringWithFormat:@"OpenMind Harness wants to save “%@” (%.1f KB). You will choose where it goes.",
                                               OMHDisplayValue(safeName, 80), data.length / 1024.0]
                                   capability:OMHCapabilityFilesExport];
        OMHHostBridgeResponse *refusal = [OMHCallConfirmation refusalFor:outcome action:[NSString stringWithFormat:@"saving “%@”", OMHDisplayValue(safeName, 80)]];
        if (refusal)
            return refusal;

        NSURL *temporary = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:safeName];
        NSError *error = nil;
        if (![data writeToURL:temporary options:NSDataWritingAtomic error:&error])
            return [OMHHostBridgeResponse errorWithStatus:500 code:@"internal"
                                                  message:[NSString stringWithFormat:@"Could not stage the file: %@", error.localizedDescription]
                                              recoverable:NO];

        OMHDocumentPicker *picker = [OMHDocumentPicker new];
        __block BOOL presented = NO;
        OMHRunOnMainSync(^{
            UIViewController *top = [self topViewController];
            if (top == nil)
                return;
            UIDocumentPickerViewController *controller =
                [[UIDocumentPickerViewController alloc] initForExportingURLs:@[temporary] asCopy:YES];
            controller.delegate = picker;
            [top presentViewController:controller animated:YES completion:nil];
            presented = YES;
        });
        if (!presented)
            return [self noForegroundUI];

        dispatch_semaphore_wait(picker.done, dispatch_time(DISPATCH_TIME_NOW, (int64_t) (kPickerTimeout * NSEC_PER_SEC)));
        [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
        if (picker.cancelled)
            return [OMHHostBridgeResponse errorWithStatus:403 code:@"permission_denied"
                                                  message:@"The user closed the save dialog without saving."
                                              recoverable:NO];
        return [OMHHostBridgeResponse ok:@{ @"saved": @YES, @"name": safeName, @"bytes": @(data.length) }];
    }];
}

@end

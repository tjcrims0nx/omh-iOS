//
//  OMHBootCoordinator.h
//  OMH
//
//  Runs everything that must happen before the harness can start — importing
//  the bundled guest image when it changed, and booting the emulator kernel —
//  on a background thread.
//
//  This work takes tens of seconds on a phone, and iOS kills an app whose
//  launch methods block for ~20 s (0x8badf00d). So the UI comes up first and
//  the boot reports progress through OMHBootStateDidChangeNotification.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OMHBootPhase) {
    OMHBootPhaseIdle = 0,
    OMHBootPhaseImportingImage,   // first launch, or an app update with a new image
    OMHBootPhaseBootingKernel,    // mounting the fakefs and starting init
    OMHBootPhaseMigratingData,    // copying ~/.config/opencode and the workspace from the previous root
    OMHBootPhaseReady,            // the guest is up; the harness may start
    OMHBootPhaseFailed,
};

extern NSNotificationName const OMHBootStateDidChangeNotification;

@interface OMHBootCoordinator : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) OMHBootPhase phase;
/// 0…1 while importing an image, -1 when the step has no measurable progress.
@property (nonatomic, readonly) double progress;
/// Human-readable status for the startup overlay.
@property (nonatomic, readonly, copy) NSString *statusMessage;
/// Kernel boot result (0 = success); valid once the phase is Ready or Failed.
@property (nonatomic, readonly) int bootError;
/// Starts the sequence on a background queue. Safe to call once per launch.
- (void)start;

@end

NS_ASSUME_NONNULL_END

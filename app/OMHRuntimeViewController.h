//
//  OMHRuntimeViewController.h
//  OMH
//
//  Native Runtime tab: providers, tasks, schedules, plugins, skills and
//  evidence status, read from the harness backend (GET /api/state and
//  GET /api/plugins/omjb) through OMHApiClient. No WebView, no images,
//  black and neon-purple theme (OMHTheme).
//

#import <UIKit/UIKit.h>

@class OMHApiClient;

@interface OMHRuntimeViewController : UIViewController

- (instancetype)initWithApiClient:(OMHApiClient *)client;

/// Re-fetch GET /api/state (and GET /api/plugins/omjb) and refresh the
/// table. Safe to call repeatedly; ignored while a fetch is in flight.
- (void)reload;

@end

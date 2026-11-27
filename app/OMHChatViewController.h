//
//  OMHChatViewController.h
//  OMH
//
//  Native chat tab for the OpenUI migration: provider selector, message
//  list and composer talking to the harness backend through OMHApiClient
//  (GET /api/chat, POST /api/chat). No WebView, no streaming, no artwork.
//

#import <UIKit/UIKit.h>

@class OMHApiClient;

@interface OMHChatViewController : UIViewController

- (instancetype)initWithApiClient:(OMHApiClient *)client NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Re-fetches the provider list from GET /api/chat and refreshes the
/// provider selector. Called by the dashboard container for Refresh.
- (void)reload;

@end

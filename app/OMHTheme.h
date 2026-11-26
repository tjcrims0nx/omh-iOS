//
//  OMHTheme.h
//  OMH
//
//  Black and neon-purple theme for the native OpenUI interface.
//  Official colors (harness PR #14): #050505 black, #100B16 dark purple
//  surface, #BF00FF neon purple, #E0AAFF light purple.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface OMHTheme : NSObject

+ (UIColor *)backgroundColor;    // #050505
+ (UIColor *)surfaceColor;       // #100B16
+ (UIColor *)surfaceRaisedColor; // #30203D
+ (UIColor *)accentColor;        // #BF00FF
+ (UIColor *)accentLightColor;   // #E0AAFF
+ (UIColor *)textColor;          // #F5F2FF
+ (UIColor *)mutedTextColor;     // #C7A8DC
+ (UIColor *)borderColor;        // #654078
+ (UIColor *)dangerColor;        // #FF6170 (failure / error text)

@end

NS_ASSUME_NONNULL_END

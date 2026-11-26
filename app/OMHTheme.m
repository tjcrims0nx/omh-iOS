//
//  OMHTheme.m
//  OMH
//

#import "OMHTheme.h"

@implementation OMHTheme

+ (UIColor *)colorWithHex:(uint32_t)hex {
    CGFloat r = ((hex >> 16) & 0xFF) / 255.0;
    CGFloat g = ((hex >> 8) & 0xFF) / 255.0;
    CGFloat b = (hex & 0xFF) / 255.0;
    return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
}

+ (UIColor *)backgroundColor { return [self colorWithHex:0x050505]; }
+ (UIColor *)surfaceColor { return [self colorWithHex:0x100B16]; }
+ (UIColor *)surfaceRaisedColor { return [self colorWithHex:0x30203D]; }
+ (UIColor *)accentColor { return [self colorWithHex:0xBF00FF]; }
+ (UIColor *)accentLightColor { return [self colorWithHex:0xE0AAFF]; }
+ (UIColor *)textColor { return [self colorWithHex:0xF5F2FF]; }
+ (UIColor *)mutedTextColor { return [self colorWithHex:0xC7A8DC]; }
+ (UIColor *)borderColor { return [self colorWithHex:0x654078]; }
+ (UIColor *)dangerColor { return [self colorWithHex:0xFF6170]; }

@end

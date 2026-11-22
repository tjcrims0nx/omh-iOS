//
//  OMHMain.m
//  OMH
//

#import <UIKit/UIKit.h>
#import "OMHAppDelegate.h"
#import "ExceptionExfiltrator.h"

int main(int argc, char * argv[]) {
    NSSetUncaughtExceptionHandler(iSHExceptionHandler);
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([OMHAppDelegate class]));
    }
}

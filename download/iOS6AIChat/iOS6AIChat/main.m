//
//  main.m
//  iOS6AIChat
//
//  Application entry point. iOS 6 does not have a storyboard-based
//  launch screen, so we boot straight into the AppDelegate.
//

#import <UIKit/UIKit.h>
#import "AppDelegate.h"

int main(int argc, char *argv[])
{
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                  NSStringFromClass([AppDelegate class]));
    }
}

#import <UIKit/UIKit.h>

@interface DYFSLivePreStreamLayoutCoordinator : NSObject
+ (void)activateLayoutForController:(UIViewController *)viewController;
+ (void)restoreLayoutForController:(UIViewController *)viewController;
+ (void)scheduleUpdateForController:(UIViewController *)viewController;
+ (void)scheduleUpdateForView:(UIView *)view;
@end

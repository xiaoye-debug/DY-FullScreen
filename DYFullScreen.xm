#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <QuartzCore/QuartzCore.h>

#pragma mark - Standalone fullscreen state

static NSString *const kDYFSFullScreenEnabledKey = @"DYYYEnableFullScreen";

BOOL DYFSIsEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kDYFSFullScreenEnabledKey] == nil) {
        [defaults setBool:YES forKey:kDYFSFullScreenEnabledKey];
    }
    return [defaults boolForKey:kDYFSFullScreenEnabledKey];
}

static CGFloat gDYFSOriginalTabBarHeight = 0.0;
static CGFloat gDYFSCurrentTabBarHeight = 0.0;

static char kDYFSFeedTableOriginalGapKey;
static char kDYFSFeedTableAppliedKey;
static char kDYFSAuthorOriginalFrameKey;

static BOOL DYFSShouldAdjustMetalView(UIView *view);
static BOOL DYFSIsAuthorWorkDetailContext(UIView *view);

static UIViewController *DYFSFirstViewControllerFromView(UIView *view) {
    if (!view) return nil;
    UIResponder *r = view;
    while ((r = [r nextResponder])) {
        if ([r isKindOfClass:UIViewController.class]) return (UIViewController *)r;
    }
    return nil;
}

NSArray<UIView *> *DYFSFindAllSubviewsOfClass(Class cls, UIView *container) {
    if (!cls || !container) return @[];
    NSMutableArray *result = [NSMutableArray array];
    NSMutableArray *queue = [NSMutableArray arrayWithObject:container];
    while (queue.count) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([view isKindOfClass:cls] && view != container) [result addObject:view];
        [queue addObjectsFromArray:view.subviews];
    }
    return result;
}

BOOL DYFSContainsSubviewOfClass(Class cls, UIView *container) {
    if (!cls || !container) return NO;
    if ([container isKindOfClass:cls]) return YES;
    for (UIView *sub in container.subviews) {
        if (DYFSContainsSubviewOfClass(cls, sub)) return YES;
    }
    return NO;
}

static BOOL DYFSIsAuthorProfileContext(UIView *view) {
    if (!view) return NO;
    UIResponder *r = view;
    NSInteger depth = 0;
    while ((r = [r nextResponder]) && depth++ < 20) {
        NSString *name = NSStringFromClass([r class]);
        if ([name containsString:@"UserHomeViewController"] ||
            [name containsString:@"UserProfileViewController"] ||
            [name containsString:@"ProfileViewController"] ||
            [name containsString:@"UserHome"]) {
            return YES;
        }
    }
    return NO;
}

static UIWindow *DYFSActiveWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState == UISceneActivationStateUnattached) continue;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow && !w.hidden) return w;
        }
        for (UIWindow *w in ws.windows) {
            if (!w.hidden && w.alpha > 0.01 && w.rootViewController) return w;
        }
    }
    return nil;
}

#pragma mark - Tab bar

@interface AWENormalModeTabBar : UIView
@property(nonatomic,strong) UIView *skinContainerView;
- (void)initializeOriginalTabBarHeight;
@end

%hook AWENormalModeTabBar

- (void)didMoveToWindow {
    %orig;
    if (self.window && gDYFSOriginalTabBarHeight <= 0.0) {
        CGFloat h = self.bounds.size.height;
        if (h < 30.0) h = 49.0 + self.window.safeAreaInsets.bottom;
        gDYFSOriginalTabBarHeight = h;
        gDYFSCurrentTabBarHeight = h;
    }
}

- (void)layoutSubviews {
    %orig;

    if (gDYFSOriginalTabBarHeight <= 0.0) {
        CGFloat h = self.bounds.size.height;
        if (h >= 30.0) {
            gDYFSOriginalTabBarHeight = h;
            gDYFSCurrentTabBarHeight = h;
        }
    }
    if (gDYFSCurrentTabBarHeight <= 0.0) gDYFSCurrentTabBarHeight = gDYFSOriginalTabBarHeight;

    Class bgClass = NSClassFromString(@"_UIBarBackground");
    for (UIView *sub in self.subviews) {
        if ([sub isKindOfClass:bgClass] ||
            ([sub isMemberOfClass:UIView.class] && gDYFSOriginalTabBarHeight > 0.0 &&
             fabs(sub.frame.size.height - gDYFSCurrentTabBarHeight) < 0.5)) {
            sub.hidden = YES;
        }
        if (sub.frame.size.height > 0 && sub.frame.size.height < 1.0 &&
            sub.frame.size.width > 300.0) {
            sub.hidden = YES;
        }
    }
    if (self.skinContainerView) self.skinContainerView.hidden = YES;
}

%end

#pragma mark - Main feed/detail height

#pragma mark - DYKiller-style feed table stretching

@interface AWEFeedDataSafeTableView : UITableView
@end

%hook AWEFeedDataSafeTableView

- (void)setFrame:(CGRect)frame {
    if (!DYFSIsEnabled()) {
        %orig(frame);
        return;
    }

    UIView *parent = self.superview;
    CGFloat target = parent ? parent.bounds.size.height : 0.0;
    CGFloat current = frame.size.height;

    if (target > 0.0 && current < target - 0.5 && current >= target * 0.5) {
        if (!objc_getAssociatedObject(self, &kDYFSFeedTableOriginalGapKey)) {
            objc_setAssociatedObject(self, &kDYFSFeedTableOriginalGapKey,
                                     @(target - current),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        frame.size.height = target;
    }

    %orig(frame);
}

%end

@interface AWEPlayInteractionViewController : UIViewController
@property(nonatomic,copy) NSString *referString;
@property(nonatomic,strong) id model;
@end

%hook AWEPlayInteractionViewController

- (void)viewDidLayoutSubviews {
    %orig;

    UIWindow *window = DYFSActiveWindow();
    if (window && window.safeAreaInsets.bottom == 0) return;

    UIView *superview = self.view.superview;
    if (!superview) return;

    UIViewController *parent = self.parentViewController;
    for (NSInteger i=0; parent && i<4; i++, parent=parent.parentViewController) {
        if ([NSStringFromClass(parent.class) containsString:@"AFDPlayRemoteFeedTableViewController"]) return;
    }

    CGRect frame = self.view.frame;
    CGFloat screenWidth = UIScreen.mainScreen.bounds.size.width;
    CGFloat parentHeight = superview.bounds.size.height;
    if (frame.size.width != screenWidth && frame.size.height < parentHeight) return;

    NSString *refer = self.referString;
    // 作品主页不能改 FeedTable 的分页高度，否则会破坏上下 Cell；
    // 但当前正在播放的作品视频容器本身仍然必须占满父容器。
    BOOL isAuthorProfile = DYFSIsAuthorProfileContext(self.view);
    BOOL fullHeight =
        [refer isEqualToString:@"general_search"] ||
        [refer isEqualToString:@"search_result"] ||
        [refer isEqualToString:@"search_ecommerce"] ||
        [refer isEqualToString:@"close_friends_moment"] ||
        [refer isEqualToString:@"offline_mode"] ||
        [refer isEqualToString:@"challenge"] ||
        [refer isEqualToString:@"general_search_scan"] ||
        refer == nil ||
        isAuthorProfile;

    if ([refer isEqualToString:@"co_play_watch"]) {
        Class rich = NSClassFromString(@"AWEFriendsImpl.RichContentNewListViewController");
        if (rich && [self.parentViewController isKindOfClass:rich]) fullHeight = YES;
    }

    if ([refer isEqualToString:@"chat"]) {
        id model = self.model;
        BOOL live = NO;
        if ([model respondsToSelector:@selector(isLive)]) {
            live = ((BOOL (*)(id, SEL))objc_msgSend)(model, @selector(isLive));
        }
        if (!live && [model respondsToSelector:@selector(cellRoom)]) {
            live = (((id (*)(id, SEL))objc_msgSend)(model, @selector(cellRoom)) != nil);
        }
        if (!live && [model respondsToSelector:@selector(videoFeedTag)]) {
            id tag = ((id (*)(id, SEL))objc_msgSend)(model, @selector(videoFeedTag));
            live = [tag isKindOfClass:NSString.class] && [tag isEqualToString:@"直播中"];
        }
        if (!live) fullHeight = YES;
    }

    frame.size.height = fullHeight ? parentHeight : MAX(parentHeight - gDYFSCurrentTabBarHeight, 0);
    if (fabs(frame.size.height - self.view.frame.size.height) > 0.5) self.view.frame = frame;
}

%end

@interface AWEDPlayerFeedPlayerViewController : UIViewController
@property(nonatomic,strong) UIView *contentView;
@end

%hook AWEDPlayerFeedPlayerViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *content = self.contentView;
    if (!content.superview) return;
    CGRect f = content.frame;
    CGFloat h = content.superview.bounds.size.height;
    if (fabs(f.size.height - (h - gDYFSCurrentTabBarHeight)) < 1.0) {
        f.size.height = h;
        content.frame = f;
    } else if (fabs(f.size.height - (h - 2*gDYFSCurrentTabBarHeight)) < 1.0) {
        f.size.height = h - gDYFSCurrentTabBarHeight;
        content.frame = f;
    }
}
%end

@interface AWEDPlayerViewController_Merge : UIViewController
@property(nonatomic,strong) UIView *contentView;
@end

%hook AWEDPlayerViewController_Merge
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *content = self.contentView;
    if (!content.superview) return;
    CGRect f = content.frame;
    CGFloat h = content.superview.bounds.size.height;
    if (fabs(f.size.height - (h - gDYFSCurrentTabBarHeight)) < 1.0) {
        f.size.height = h;
        content.frame = f;
    } else if (fabs(f.size.height - (h - 2*gDYFSCurrentTabBarHeight)) < 1.0) {
        f.size.height = h - gDYFSCurrentTabBarHeight;
        content.frame = f;
    }
}
%end

@interface AWEFeedTableView : UIView
@end

%hook AWEFeedTableView
- (void)layoutSubviews {
    %orig;
    UIView *superview = self.superview;
    if (!superview) return;

    BOOL applied = [objc_getAssociatedObject(self, &kDYFSFeedTableAppliedKey) boolValue];
    CGFloat superH = superview.bounds.size.height;

    if (!applied) {
        CGFloat gap = MAX(superH - self.bounds.size.height, 0.0);
        objc_setAssociatedObject(self, &kDYFSFeedTableOriginalGapKey, @(gap), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kDYFSFeedTableAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (fabs(self.bounds.size.height - superH) > 0.5) {
        CGRect f = self.frame;
        f.size.height = superH;
        self.frame = f;
    }
}
%end

#pragma mark - Author profile / image works

@interface AWEStoryContainerCollectionView : UIView
@end

%hook AWEStoryContainerCollectionView
- (void)layoutSubviews {
    %orig;
    if (self.subviews.count == 2) return;

    id enableEnterProfile = nil;
    @try { enableEnterProfile = [self valueForKey:@"enableEnterProfile"]; } @catch (__unused NSException *e) {}
    BOOL isHome = [enableEnterProfile respondsToSelector:@selector(boolValue)] && [enableEnterProfile boolValue];

    BOOL isAuthor = DYFSIsAuthorProfileContext(self);
    if (!isHome && !isAuthor) return;

    for (UIView *subview in [self.subviews copy]) {
        UIView *next = (UIView *)subview.nextResponder;

        if (isHome && [next isKindOfClass:NSClassFromString(@"AWEPlayInteractionViewController")]) {
            UIViewController *base = nil;
            @try { base = [next valueForKey:@"awemeBaseViewController"]; } @catch (__unused NSException *e) {}
            if (base && ![base isKindOfClass:NSClassFromString(@"AWEFeedCellViewController")]) continue;

            CGRect f = subview.frame;
            f.size.height = subview.superview.bounds.size.height - gDYFSCurrentTabBarHeight;
            subview.frame = f;
        } else if (isAuthor) {
            BOOL isWorkImage = NO;
            for (UIView *child in subview.subviews) {
                NSString *name = NSStringFromClass(child.class);
                if ([name containsString:@"ImageView"] || [name containsString:@"ThumbnailView"]) {
                    isWorkImage = YES;
                    break;
                }
            }
            if (!isWorkImage) continue;

            // 关键修复：原逻辑每次 layout 都 += tabBarHeight，导致滑动后位置累计漂移/重叠。
            CGRect original = subview.frame;
            NSValue *stored = objc_getAssociatedObject(subview, &kDYFSAuthorOriginalFrameKey);
            if (stored) original = stored.CGRectValue;
            else objc_setAssociatedObject(subview, &kDYFSAuthorOriginalFrameKey,
                                           [NSValue valueWithCGRect:original],
                                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            CGRect adjusted = original;
            adjusted.origin.y += MAX(gDYFSCurrentTabBarHeight, 0.0);
            if (!CGRectEqualToRect(subview.frame, adjusted)) subview.frame = adjusted;
        }
    }
}
%end

@interface AWEAwemeDetailTableView : UITableView
@end

%hook AWEAwemeDetailTableView
- (void)setFrame:(CGRect)frame {
    if (DYFSIsAuthorProfileContext(self)) {
        %orig(frame);
        return;
    }
    if (frame.size.height > 0) {
        CGFloat screenH = UIScreen.mainScreen.bounds.size.height;
        CGFloat remainder = fmod(frame.size.height, screenH);
        if (remainder > 0.01) frame.size.height += screenH - remainder;
    }
    %orig(frame);
}
%end


#pragma mark - Live preview HUD

@interface AWELivePreStream4LayerContainerView : UIView
@property(nonatomic,strong) UIImageView *bottomDarkWatermark;
@property(nonatomic,strong) UIView *controlContainer;
@end

static char kDYFSLiveChromeTransformKey;
static char kDYFSBaselineTransformKey;

static void DYFSApplyLiveLift(UIView *target, CGFloat lift, BOOL wanted) {
    if (!target) return;

    NSValue *baseline = objc_getAssociatedObject(target, &kDYFSBaselineTransformKey);
    if (!baseline) {
        if (!CGAffineTransformIsIdentity(target.transform)) return;
        baseline = [NSValue valueWithCGAffineTransform:target.transform];
        objc_setAssociatedObject(target, &kDYFSBaselineTransformKey, baseline,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (wanted && lift > 0.5) {
        target.transform = CGAffineTransformMakeTranslation(0.0, -lift);
        objc_setAssociatedObject(target, &kDYFSLiveChromeTransformKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (objc_getAssociatedObject(target, &kDYFSLiveChromeTransformKey)) {
        target.transform = baseline.CGAffineTransformValue;
        objc_setAssociatedObject(target, &kDYFSLiveChromeTransformKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static CGFloat DYFSCurrentLiveLift(AWELivePreStream4LayerContainerView *container) {
    if (!container) return 0.0;

    Class tableClass = NSClassFromString(@"AWEFeedDataSafeTableView");
    UIView *ancestor = container.superview;
    for (NSUInteger i = 0; ancestor && i < 12; i++, ancestor = ancestor.superview) {
        if (tableClass && [ancestor isKindOfClass:tableClass]) {
            NSNumber *gap = objc_getAssociatedObject(ancestor, &kDYFSFeedTableOriginalGapKey);
            return gap ? MAX(gap.doubleValue, 0.0) : 0.0;
        }
    }
    return 0.0;
}

static void DYFSSyncLiveChrome(AWELivePreStream4LayerContainerView *container) {
    if (!container) return;

    CGFloat lift = DYFSIsEnabled() ? DYFSCurrentLiveLift(container) : 0.0;

    // DYKiller 实际使用具名 controlContainer：昵称、简介、直播中标签、
    // 进入直播间按钮等都在这个容器里，不能只移动一个 status label。
    DYFSApplyLiveLift(container.controlContainer, lift, lift > 0.5);

    UIImageView *watermark = container.bottomDarkWatermark;
    BOOL watermarkWanted = NO;
    if (watermark && lift > 0.5) {
        CGRect f = watermark.frame;
        CGFloat bottom = CGRectGetMaxY(f);
        watermarkWanted = bottom > container.bounds.size.height - lift + 0.5;
    }
    DYFSApplyLiveLift(watermark, lift, watermarkWanted);
}

%hook AWELivePreStream4LayerContainerView

- (void)layoutSubviews {
    %orig;
    DYFSSyncLiveChrome(self);
}

%end

#pragma mark - Visual cleanup needed by fullscreen

@interface AWEPlayInteractionProgressContainerView : UIView @end
%hook AWEPlayInteractionProgressContainerView
- (void)layoutSubviews {
    %orig;
    for (UIView *v in self.subviews) if ([v isMemberOfClass:UIView.class]) v.backgroundColor = UIColor.clearColor;
}
%end

@interface AWEDPlayerProgressContainerView : UIView @end
%hook AWEDPlayerProgressContainerView
- (void)layoutSubviews {
    %orig;
    for (UIView *v in self.subviews) {
        if (![v isMemberOfClass:UIView.class]) continue;
        UIColor *c=v.backgroundColor;
        CGFloat h,s,b,a;
        if (c && [c getHue:&h saturation:&s brightness:&b alpha:&a] && b < 0.2) v.backgroundColor=UIColor.clearColor;
    }
}
%end

@interface AFDFastSpeedView : UIView @end
%hook AFDFastSpeedView
- (void)layoutSubviews {
    %orig;
    for (UIView *v in self.subviews) if ([v isMemberOfClass:UIView.class]) v.backgroundColor=UIColor.clearColor;
}
%end

@interface AFDViewedBottomView : UIView
@property(nonatomic,strong) UIView *effectView;
@end
%hook AFDViewedBottomView
- (void)layoutSubviews {
    %orig;
    self.backgroundColor=UIColor.clearColor;
    self.effectView.hidden=YES;
}
%end

#pragma mark - Landscape / image album positioning

@interface TTMetalView : UIView @end
%hook TTMetalView
- (void)setCenter:(CGPoint)center {
    if (DYFSShouldAdjustMetalView(self)) center.y -= (gDYFSCurrentTabBarHeight > 0 ? gDYFSCurrentTabBarHeight : gDYFSOriginalTabBarHeight) * 0.5;
    %orig(center);
}
%end

@interface TTMetalViewNew : UIView @end
%hook TTMetalViewNew
- (void)setCenter:(CGPoint)center {
    if (DYFSShouldAdjustMetalView(self)) center.y -= (gDYFSCurrentTabBarHeight > 0 ? gDYFSCurrentTabBarHeight : gDYFSOriginalTabBarHeight) * 0.5;
    %orig(center);
}
%end

@interface TTMetalViewVP : UIView @end
%hook TTMetalViewVP
- (void)setCenter:(CGPoint)center {
    if (DYFSShouldAdjustMetalView(self)) center.y -= (gDYFSCurrentTabBarHeight > 0 ? gDYFSCurrentTabBarHeight : gDYFSOriginalTabBarHeight) * 0.5;
    %orig(center);
}
%end

static BOOL DYFSShouldAdjustMetalView(UIView *view) {
    if (!view || !DYFSIsEnabled()) return NO;
    if (view.bounds.size.width + 0.5 < UIScreen.mainScreen.bounds.size.width) return NO;
    UIViewController *vc = DYFSFirstViewControllerFromView(view);
    Class playClass = NSClassFromString(@"AWEPlayVideoViewController");
    if (!playClass || ![vc isKindOfClass:playClass]) return NO;
    id model = nil;
    @try { model = [vc valueForKey:@"model"]; } @catch (__unused NSException *e) {}
    if (![model respondsToSelector:@selector(isShowLandscapeEntryView)]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(model, @selector(isShowLandscapeEntryView));
}

@interface AWEStoryProgressContainerView : UIView @end
%hook AWEStoryProgressContainerView
- (void)setCenter:(CGPoint)center {
    UIViewController *vc=DYFSFirstViewControllerFromView(self);
    BOOL pure=[vc isKindOfClass:NSClassFromString(@"AWEFeedPlayControlImpl.PureModePageCellViewController")];
    NSString *version=NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];
    BOOL legacy=version.length==0 || [version compare:@"37.2.0" options:NSNumericSearch] == NSOrderedAscending;
    if (pure && legacy && gDYFSCurrentTabBarHeight>0) center.y -= gDYFSCurrentTabBarHeight;
    %orig(center);
}
%end

#pragma mark - Other fullscreen layout compensation

@interface AWEMixVideoPanelMoreView : UIView @end
%hook AWEMixVideoPanelMoreView
- (void)setFrame:(CGRect)frame {
    CGFloat targetY=frame.origin.y-gDYFSCurrentTabBarHeight;
    CGFloat expected=UIScreen.mainScreen.bounds.size.height-gDYFSCurrentTabBarHeight;
    if (fabs(targetY-expected)<=10.0) frame.origin.y=targetY;
    %orig(frame);
}
- (void)layoutSubviews {
    %orig;
    self.backgroundColor=UIColor.clearColor;
}
%end

@interface CommentInputContainerView : UIView @end
%hook CommentInputContainerView
- (void)layoutSubviews {
    %orig;
    if (!DYFSIsEnabled()) return;
    if (DYFSIsAuthorWorkDetailContext(self) || DYFSIsAuthorProfileContext(self)) {
        self.hidden = YES;
        self.alpha = 0.0;
        return;
    }
    UIViewController *parent=nil;
    if ([self respondsToSelector:@selector(viewController)]) {
        id vc=[self performSelector:@selector(viewController)];
        if ([vc respondsToSelector:@selector(parentViewController)]) parent=[vc parentViewController];
    }
    if (parent && ([parent isKindOfClass:NSClassFromString(@"AWEAwemeDetailTableViewController")] ||
                   [parent isKindOfClass:NSClassFromString(@"AWEAwemeDetailCellViewController")])) {
        UIView *target=nil;
        static char kTarget;
        target=objc_getAssociatedObject(self,&kTarget);
        if (!target) {
            for (UIView *v in self.subviews) if ([v isMemberOfClass:UIView.class]) { target=v; objc_setAssociatedObject(self,&kTarget,target,OBJC_ASSOCIATION_ASSIGN); break; }
        }
        if (target) target.hidden=(self.frame.size.height <= gDYFSCurrentTabBarHeight+0.5);
    }
}
%end

@interface AWEIMFeedBottomQuickEmojiInputBar : UIView @end
%hook AWEIMFeedBottomQuickEmojiInputBar
- (void)layoutSubviews {
    %orig;
    if (!DYFSIsEnabled()) return;
    UIView *p=self.superview;
    while (p && ![NSStringFromClass(p.class) isEqualToString:@"UIView"]) p=p.superview;
    if (p) { p.backgroundColor=UIColor.clearColor; p.layer.backgroundColor=UIColor.clearColor.CGColor; p.opaque=NO; }
}
%end

@interface AWEConcernCellLastView : UIView @end
%hook AWEConcernCellLastView
- (void)layoutSubviews {
    %orig;
    if (!DYFSIsEnabled() || gDYFSCurrentTabBarHeight<=0) return;

    static char kDYFSConcernOriginalFramesKey;
    NSArray *frames = objc_getAssociatedObject(self, &kDYFSConcernOriginalFramesKey);
    if (!frames) {
        NSMutableArray *saved = [NSMutableArray array];
        for (UIView *v in self.subviews) {
            [saved addObject:[NSValue valueWithCGRect:v.frame]];
        }
        frames = [saved copy];
        objc_setAssociatedObject(self, &kDYFSConcernOriginalFramesKey, frames, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSUInteger count = MIN(frames.count, self.subviews.count);
    for (NSUInteger i = 0; i < count; i++) {
        UIView *v = self.subviews[i];
        CGRect f = [frames[i] CGRectValue];
        f.origin.y -= gDYFSCurrentTabBarHeight;
        v.frame = f;
    }
}
%end

@interface AWECommentInputBackgroundView : UIView @end
%hook AWECommentInputBackgroundView
- (void)layoutSubviews {
    %orig;
    if (!DYFSIsEnabled()) return;

    if (DYFSIsAuthorWorkDetailContext(self) || DYFSIsAuthorProfileContext(self)) {
        self.hidden = YES;
        self.alpha = 0.0;
        return;
    }

    self.transform=CGAffineTransformMakeTranslation(0, gDYFSOriginalTabBarHeight-gDYFSCurrentTabBarHeight);
}
%end

#pragma mark - Native Douyin Settings fullscreen switch

@interface AWESettingItemModel : NSObject
@property(nonatomic,copy) NSString *identifier;
@property(nonatomic,copy) NSString *title;
@property(nonatomic,copy) NSString *subTitle;
@property(nonatomic,copy) NSString *detail;
@property(nonatomic,copy) NSString *svgIconImageName;
@property(nonatomic,assign) NSInteger cellType;
@property(nonatomic,assign) NSInteger colorStyle;
@property(nonatomic,assign) BOOL isEnable;
@property(nonatomic,assign) BOOL isSwitchOn;
@property(nonatomic,copy) void (^switchChangedBlock)(void);
@end

@interface AWESettingSectionModel : NSObject
@property(nonatomic,copy) NSString *sectionHeaderTitle;
@property(nonatomic,assign) CGFloat sectionHeaderHeight;
@property(nonatomic,copy) NSString *sectionFooterTitle;
@property(nonatomic,assign) NSInteger type;
@property(nonatomic,strong) NSArray *itemArray;
@end

@interface AWESettingsViewModel : NSObject
@property(nonatomic,strong) NSArray *sectionDataArray;
@property(nonatomic,assign) NSInteger colorStyle;
@end

static AWESettingItemModel *DYFSMakeNativeFullscreenItem(void) {
    Class itemClass = NSClassFromString(@"AWESettingItemModel");
    if (!itemClass) return nil;

    AWESettingItemModel *item = [itemClass new];
    item.identifier = @"DYFSNativeFullScreen";
    item.title = @"视频全屏";
    item.subTitle = @"首页、朋友页、搜索页和他人作品铺满屏幕";
    item.detail = @"";
    item.svgIconImageName = @"ic_fullscreen_outlined_16";
    item.cellType = 6;
    item.colorStyle = 0;
    item.isEnable = YES;
    item.isSwitchOn = DYFSIsEnabled();

    __weak AWESettingItemModel *weakItem = item;
    item.switchChangedBlock = ^{
        AWESettingItemModel *strongItem = weakItem;
        if (!strongItem) return;

        // 抖音的 switch cell 会先更新 isSwitchOn，再调用 block。
        BOOL enabled = !strongItem.isSwitchOn;
        strongItem.isSwitchOn = enabled;
        [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kDYFSFullScreenEnabledKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
    };
    return item;
}

%hook AWESettingsViewModel

- (NSArray *)sectionDataArray {
    NSArray *sections = %orig;
    if (![sections isKindOfClass:NSArray.class]) return sections;

    // 不重复插入；抖音会多次读取这个属性。
    for (id section in sections) {
        NSArray *items = nil;
        @try { items = [section valueForKey:@"itemArray"]; } @catch (__unused NSException *e) {}
        for (id item in items) {
            NSString *identifier = nil;
            @try { identifier = [item valueForKey:@"identifier"]; } @catch (__unused NSException *e) {}
            if ([identifier isEqualToString:@"DYFSNativeFullScreen"]) {
                return sections;
            }
        }
    }

    AWESettingItemModel *item = DYFSMakeNativeFullscreenItem();
    Class sectionClass = NSClassFromString(@"AWESettingSectionModel");
    if (!item || !sectionClass) return sections;

    AWESettingSectionModel *section = [sectionClass new];
    section.sectionHeaderTitle = @"DY-FullScreen";
    section.sectionHeaderHeight = 40.0;
    section.sectionFooterTitle = @"关闭后全屏布局立即停止。";
    section.type = 0;
    section.itemArray = @[item];

    NSMutableArray *result = [sections mutableCopy];
    if (!result) result = [NSMutableArray array];
    [result insertObject:section atIndex:0];
    return [result copy];
}

%end

#pragma mark - Live preview

// 不再直接平移 AWELivePrestream 文案、昵称、状态标签。
// 这类视图由抖音自己的布局管理；此前额外按底栏高度做 transform 会导致：
// 1) 文案/名字被推到视频中部；
// 2) 进入直播页第一条内容出现一次明显的延迟上移。
// standalone 全屏只处理视频容器与底栏遮挡，不改直播预览文案坐标。

#pragma mark - Author profile comment bar removal

// DYKiller 的关键点：从详情控制器入口阻止作者主页底栏显示。
// 普通详情页保持原行为。
@interface AWEAwemeDetailTableViewController : UIViewController
@property(nonatomic,copy) NSString *referString;
- (BOOL)canShowFixedBottomBar;
- (void)setBottomBarHidden:(BOOL)hidden;
@end

static BOOL DYFSIsAuthorWorkDetailContext(UIView *view) {
    if (!view) return NO;
    UIResponder *r = view;
    NSInteger depth = 0;
    while ((r = [r nextResponder]) && depth++ < 40) {
        NSString *name = NSStringFromClass(r.class);
        if ([name containsString:@"UserHome"] ||
            [name containsString:@"UserProfile"] ||
            [name containsString:@"ProfileViewController"] ||
            [name containsString:@"AWEAwemeDetailCellViewController"]) {
            return YES;
        }
    }
    return NO;
}

%hook AWEAwemeDetailTableViewController

- (BOOL)canShowFixedBottomBar {
    if (DYFSIsAuthorWorkDetailContext(self.view)) return NO;
    return %orig;
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (DYFSIsAuthorWorkDetailContext(self.view) &&
        [self respondsToSelector:@selector(setBottomBarHidden:)]) {
        [self setBottomBarHidden:YES];
    }
}

%end

#pragma mark - Native Swift comment input

%group DYFSAuthorSwiftCommentInput

%hook CommentInputContainerView

- (void)layoutSubviews {
    %orig;
    UIView *view = (UIView *)self;
    if (DYFSIsEnabled() && DYFSIsAuthorWorkDetailContext(view)) {
        view.hidden = YES;
        view.alpha = 0.0;
        view.userInteractionEnabled = NO;
    }
}

%end

%end

%ctor {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kDYFSFullScreenEnabledKey] == nil) {
        [defaults setBool:YES forKey:kDYFSFullScreenEnabledKey];
    }

    // 文件中除命名 group 外的所有 %hook 属于 Logos 自动生成的 _ungrouped group。
    // 一旦存在命名 %group，就必须显式初始化这个默认 group。
    %init(_ungrouped);

    Class swiftCommentInput = NSClassFromString(@"AWECommentInputViewSwiftImpl.CommentInputContainerView");
    if (swiftCommentInput) {
        %init(DYFSAuthorSwiftCommentInput, CommentInputContainerView=swiftCommentInput);
    }

    NSLog(@"[DY-FullScreen] loaded, fullscreen=%@", DYFSIsEnabled() ? @"ON" : @"OFF");
}

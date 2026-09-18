#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

#import "DYFSLivePreStreamLayoutCoordinator.h"

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

    // 关键修复：作品主页不要强改 FeedTable 高度。
    if (DYFSIsAuthorProfileContext(self)) return;

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


#pragma mark - Home live title / status label

@interface AWELiveFeedStatusLabel : UIView
@end

%hook AWELiveFeedStatusLabel

- (void)layoutSubviews {
    %orig;

    static char kDYFSBaseTransformKey;
    if (!self.window || self.hidden || self.alpha <= 0.01) return;

    UIWindow *window = self.window;
    Class tabBarClass = NSClassFromString(@"AWENormalModeTabBar");
    UIView *tabBar = nil;

    if (tabBarClass) {
        NSArray *bars = DYFSFindAllSubviewsOfClass(tabBarClass, window);
        for (UIView *candidate in bars) {
            if (candidate.hidden || candidate.alpha <= 0.01) continue;
            CGRect rect = [candidate convertRect:candidate.bounds toView:window];
            if (CGRectGetMidY(rect) >= CGRectGetMidY(window.bounds) &&
                CGRectGetHeight(CGRectIntersection(rect, window.bounds)) > 1.0) {
                tabBar = candidate;
                break;
            }
        }
    }

    if (!tabBar) return;

    UIViewController *vc = DYFSFirstViewControllerFromView(self);
    BOOL inPlayInteraction = NO;
    UIResponder *responder = self;
    NSInteger depth = 0;
    while ((responder = [responder nextResponder]) && depth++ < 20) {
        NSString *name = NSStringFromClass([responder class]);
        if ([name isEqualToString:@"AWEPlayInteractionViewController"]) {
            inPlayInteraction = YES;
            break;
        }
    }

    if (!inPlayInteraction && ![vc isKindOfClass:NSClassFromString(@"AWEFeedTableViewController")]) {
        return;
    }

    CGRect labelRect = [self convertRect:self.bounds toView:window];
    CGRect tabRect = [tabBar convertRect:tabBar.bounds toView:window];
    CGFloat overlap = CGRectGetMaxY(labelRect) - CGRectGetMinY(tabRect);

    CGAffineTransform baseTransform = CGAffineTransformIdentity;
    NSValue *stored = objc_getAssociatedObject(self, &kDYFSBaseTransformKey);
    if (stored) {
        baseTransform = stored.CGAffineTransformValue;
    } else {
        baseTransform = self.transform;
        objc_setAssociatedObject(self, &kDYFSBaseTransformKey,
                                 [NSValue valueWithCGAffineTransform:baseTransform],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (overlap > 0.0) {
        CGFloat offset = MIN(overlap + 6.0, CGRectGetHeight(window.bounds) * 0.20);
        CGAffineTransform adjusted = CGAffineTransformTranslate(baseTransform, 0.0, -offset);
        if (!CGAffineTransformEqualToTransform(self.transform, adjusted)) {
            self.transform = adjusted;
        }
    } else if (!CGAffineTransformEqualToTransform(self.transform, baseTransform)) {
        self.transform = baseTransform;
    }
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
    if (DYFSIsAuthorProfileContext(self)) {
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

    if (DYFSIsAuthorProfileContext(self)) {
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
- (void)refreshCell;
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

@interface AWESettingBaseViewController : UIViewController
- (AWESettingsViewModel *)viewModel;
@end

static char kDYFSNativeSettingInstalledKey;

static void DYFSInstallNativeSetting(UIViewController *vc) {
    if (!vc || ![vc isKindOfClass:NSClassFromString(@"AWESettingBaseViewController")]) return;

    AWESettingsViewModel *vm = nil;
    @try { vm = [vc viewModel]; } @catch (__unused NSException *e) {}
    if (!vm) return;

    NSArray *sections = vm.sectionDataArray;
    if (![sections isKindOfClass:NSArray.class]) return;

    for (id section in sections) {
        NSArray *items = nil;
        @try { items = [section valueForKey:@"itemArray"]; } @catch (__unused NSException *e) {}
        for (id item in items) {
            NSString *identifier = nil;
            @try { identifier = [item valueForKey:@"identifier"]; } @catch (__unused NSException *e) {}
            if ([identifier isEqualToString:@"DYFSNativeFullScreen"]) return;
        }
    }

    AWESettingItemModel *item = [NSClassFromString(@"AWESettingItemModel") new];
    item.identifier = @"DYFSNativeFullScreen";
    item.title = @"启用首页全屏";
    item.subTitle = @"视频扩展到屏幕底部，隐藏底栏遮挡";
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
        BOOL enabled = !strongItem.isSwitchOn;
        strongItem.isSwitchOn = enabled;
        [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kDYFSFullScreenEnabledKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
        dispatch_async(dispatch_get_main_queue(), ^{
            [vc.view setNeedsLayout];
            [vc.view layoutIfNeeded];
        });
    };

    AWESettingSectionModel *section = [NSClassFromString(@"AWESettingSectionModel") new];
    section.sectionHeaderTitle = @"DY-FullScreen";
    section.sectionHeaderHeight = 40.0;
    section.sectionFooterTitle = @"关闭后本插件的全屏布局不会生效。";
    section.type = 0;
    section.itemArray = @[item];

    NSMutableArray *newSections = [sections mutableCopy];
    [newSections addObject:section];
    vm.sectionDataArray = [newSections copy];
    objc_setAssociatedObject(vc, &kDYFSNativeSettingInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if ([vc.view respondsToSelector:@selector(setNeedsLayout)]) {
        [vc.view setNeedsLayout];
    }
}

%hook AWESettingBaseViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    dispatch_async(dispatch_get_main_queue(), ^{
        DYFSInstallNativeSetting(self);
    });
}
%end

#pragma mark - Direct live preview title / copy layout

static void DYFSShiftLivePreviewStack(UIView *stack) {
    if (!stack || !DYFSIsEnabled()) return;

    UIViewController *vc = DYFSFirstViewControllerFromView(stack);
    if (![vc isKindOfClass:NSClassFromString(@"AWELiveNewPreStreamViewController")]) return;

    Class guideClass = NSClassFromString(@"AWELivePrestreamGuideView");
    Class tagClass = NSClassFromString(@"AWELiveFeedLabelTagView");
    Class statusClass = NSClassFromString(@"AWELiveFeedStatusLabel");

    BOOL hasGuide = guideClass && DYFSContainsSubviewOfClass(guideClass, stack);
    BOOL hasTag = tagClass && DYFSContainsSubviewOfClass(tagClass, stack);
    BOOL hasStatus = statusClass && DYFSContainsSubviewOfClass(statusClass, stack);

    if (!hasGuide && !hasTag && !hasStatus) return;

    UIWindow *window = stack.window;
    CGFloat shift = gDYFSCurrentTabBarHeight;
    if (window && window.safeAreaInsets.bottom == 0.0) {
        shift = MAX(0.0, gDYFSCurrentTabBarHeight - gDYFSOriginalTabBarHeight);
    }
    if (shift <= 0.0) return;

    static char kDYFSLiveBaseTransformKey;
    NSValue *base = objc_getAssociatedObject(stack, &kDYFSLiveBaseTransformKey);
    CGAffineTransform baseTransform = base ? base.CGAffineTransformValue : stack.transform;
    if (!base) {
        objc_setAssociatedObject(stack, &kDYFSLiveBaseTransformKey,
                                 [NSValue valueWithCGAffineTransform:baseTransform],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGFloat scale = 1.0;
    if (hasGuide || hasTag || hasStatus) {
        NSString *scaleString = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYNicknameScale"];
        CGFloat v = [scaleString floatValue];
        if (v > 0.01) scale = v;
    }

    CGFloat ty = -shift;
    NSArray *subs = [stack.subviews copy];
    for (UIView *v in subs) {
        CGFloat h = v.bounds.size.height;
        ty += (h - h * scale) * 0.5;
    }

    CGAffineTransform t = CGAffineTransformConcat(baseTransform,
        CGAffineTransformMake(scale, 0, 0, scale, 0, ty));
    if (!CGAffineTransformEqualToTransform(stack.transform, t)) {
        stack.transform = t;
    }
}

@interface AWEElementStackView : UIView @end
%hook AWEElementStackView
- (void)layoutSubviews {
    %orig;
    DYFSShiftLivePreviewStack(self);
}
%end

@interface IESLiveStackView : UIView @end
%hook IESLiveStackView
- (void)layoutSubviews {
    %orig;
    DYFSShiftLivePreviewStack(self);
}
%end

@interface AWELiveFeedStatusLabel : UILabel @end
%hook AWELiveFeedStatusLabel
- (void)layoutSubviews {
    %orig;
    if (!DYFSIsEnabled()) return;
    UIViewController *vc = DYFSFirstViewControllerFromView(self);
    if (![vc isKindOfClass:NSClassFromString(@"AWELiveNewPreStreamViewController")]) return;

    static char kDYFSStatusBaseTransformKey;
    NSValue *base = objc_getAssociatedObject(self, &kDYFSStatusBaseTransformKey);
    CGAffineTransform baseTransform = base ? base.CGAffineTransformValue : self.transform;
    if (!base) objc_setAssociatedObject(self, &kDYFSStatusBaseTransformKey,
                                        [NSValue valueWithCGAffineTransform:baseTransform],
                                        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGFloat shift = gDYFSCurrentTabBarHeight;
    if (shift > 0.0) {
        self.transform = CGAffineTransformTranslate(baseTransform, 0, -shift);
    }
}
%end

@interface AWELiveFeedLabelTagView : UIView @end
%hook AWELiveFeedLabelTagView
- (void)layoutSubviews {
    %orig;
    if (!DYFSIsEnabled()) return;
    UIViewController *vc = DYFSFirstViewControllerFromView(self);
    if (![vc isKindOfClass:NSClassFromString(@"AWELiveNewPreStreamViewController")]) return;

    static char kDYFSTagBaseTransformKey;
    NSValue *base = objc_getAssociatedObject(self, &kDYFSTagBaseTransformKey);
    CGAffineTransform baseTransform = base ? base.CGAffineTransformValue : self.transform;
    if (!base) objc_setAssociatedObject(self, &kDYFSTagBaseTransformKey,
                                        [NSValue valueWithCGAffineTransform:baseTransform],
                                        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGFloat shift = gDYFSCurrentTabBarHeight;
    if (shift > 0.0) self.transform = CGAffineTransformTranslate(baseTransform, 0, -shift);
}
%end

#pragma mark - Author profile comment bar removal

static BOOL DYFSIsAuthorWorkDetailContext(UIView *view) {
    if (!view) return NO;
    UIResponder *r = view;
    NSInteger depth = 0;
    while ((r = [r nextResponder]) && depth++ < 30) {
        NSString *name = NSStringFromClass(r.class);
        if ([name containsString:@"UserHome"] ||
            [name containsString:@"UserProfile"] ||
            [name containsString:@"ProfileViewController"] ||
            [name isEqualToString:@"AWEAwemeDetailCellViewController"]) {
            return YES;
        }
    }
    return NO;
}

%hook CommentInputContainerView
- (void)layoutSubviews {
    %orig;
    if (!DYFSIsEnabled()) return;
    if (DYFSIsAuthorWorkDetailContext(self)) {
        self.hidden = YES;
        self.alpha = 0.0;
    }
}
%end

%hook AWECommentInputBackgroundView
- (void)layoutSubviews {
    %orig;
    if (!DYFSIsEnabled()) return;
    if (DYFSIsAuthorWorkDetailContext(self)) {
        self.hidden = YES;
        self.alpha = 0.0;
    }
}
%end

%ctor {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kDYFSFullScreenEnabledKey] == nil) {
        [defaults setBool:YES forKey:kDYFSFullScreenEnabledKey];
    }
    NSLog(@"[DY-FullScreen] loaded, fullscreen=%@", DYFSIsEnabled() ? @"ON" : @"OFF");
}

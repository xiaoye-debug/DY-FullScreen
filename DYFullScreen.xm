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
        [defaults setBool:NO forKey:kDYFSFullScreenEnabledKey];
        [defaults synchronize];
    }
    return [defaults boolForKey:kDYFSFullScreenEnabledKey];
}

static CGFloat gDYFSOriginalTabBarHeight = 0.0;
static CGFloat gDYFSCurrentTabBarHeight = 0.0;

static char kDYFSFeedTableOriginalHeightKey;
static char kDYFSAuthorOriginalFrameKey;
static char kDYFSLiveAppliedKey;

static void (*gDYFSRestoreHooks[8])(void);
static NSUInteger gDYFSRestoreCount = 0;
static NSHashTable<UITableView *> *gDYFSStretchedTables;

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

static void DYFSRegisterRestore(void (*restore)(void)) {
    if (!restore || gDYFSRestoreCount >= 8) return;
    gDYFSRestoreHooks[gDYFSRestoreCount++] = restore;
}

static void DYFSRunRestoreHooks(void) {
    for (NSUInteger i = 0; i < gDYFSRestoreCount; i++) {
        if (gDYFSRestoreHooks[i]) gDYFSRestoreHooks[i]();
    }
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

    if (!DYFSIsEnabled()) return;

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

    if (!DYFSIsEnabled()) return;

    UIView *table = self.view.superview;
    NSNumber *originalNumber = nil;
    if ([table isKindOfClass:NSClassFromString(@"AWEFeedDataSafeTableView")]) {
        originalNumber = objc_getAssociatedObject(table, &kDYFSFeedTableOriginalHeightKey);
    }
    CGFloat original = originalNumber.doubleValue;
    if (original <= 0.0) return;

    CGRect frame = self.view.frame;
    if (fabs(frame.origin.y) <= 0.5 && frame.size.height <= original + 0.5) return;

    frame.origin.y = 0.0;
    frame.size.height = original;
    self.view.frame = frame;
}

%end

@interface AWEDPlayerFeedPlayerViewController : UIViewController
@property(nonatomic,strong) UIView *contentView;
@end

%hook AWEDPlayerFeedPlayerViewController
- (void)viewDidLayoutSubviews {
    // Keep Douyin's original contentView geometry.
    // Expanding this view to the stretched feed height pushes the title/caption down.
    %orig;
}
%end

@interface AWEDPlayerViewController_Merge : UIViewController
@property(nonatomic,strong) UIView *contentView;
@end

%hook AWEDPlayerViewController_Merge
- (void)viewDidLayoutSubviews {
    // Keep Douyin's original contentView geometry so the title/caption
    // remains at its normal position in fullscreen.
    %orig;
}
%end

@interface AWEFeedDataSafeTableView : UITableView
@end

static void DYFSAdjustFeedTableFrame(UITableView *table, CGRect *frame) {
    if (!DYFSIsEnabled()) return;

    UIView *parent = table.superview;
    CGFloat target = parent ? parent.bounds.size.height : 0.0;
    UIWindow *window = table.window;
    CGFloat screenHeight = window ? CGRectGetHeight(window.bounds) : CGRectGetHeight(UIScreen.mainScreen.bounds);
    if (screenHeight > 0.0 && target > screenHeight) target = screenHeight;

    CGFloat current = frame->size.height;

    if (target <= 0.0 || current >= target - 0.5 || current < target * 0.5) return;

    if (!objc_getAssociatedObject(table, &kDYFSFeedTableOriginalHeightKey)) {
        objc_setAssociatedObject(table, &kDYFSFeedTableOriginalHeightKey,
                                 @(current), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!gDYFSStretchedTables) gDYFSStretchedTables = [NSHashTable weakObjectsHashTable];
        [gDYFSStretchedTables addObject:table];
    }

    frame->size.height = target;
}

static UIView *DYFSFeedTableForView(UIView *view) {
    if (!view) return nil;
    Class tableClass = NSClassFromString(@"AWEFeedDataSafeTableView");
    if (!tableClass) return nil;

    UIView *ancestor = view.superview;
    for (NSUInteger i = 0; ancestor && i < 8; i++, ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:tableClass]) return ancestor;
    }
    return nil;
}

static CGFloat DYFSFeedTableOriginalHeight(UIView *view) {
    UIView *table = DYFSFeedTableForView(view);
    if (!table) return 0.0;
    NSNumber *n = objc_getAssociatedObject(table, &kDYFSFeedTableOriginalHeightKey);
    return n.doubleValue;
}

static void DYFSRestoreFeedTables(void) {
    for (UITableView *table in gDYFSStretchedTables.allObjects) {
        NSNumber *original = objc_getAssociatedObject(table, &kDYFSFeedTableOriginalHeightKey);
        if (!original) continue;

        objc_setAssociatedObject(table, &kDYFSFeedTableOriginalHeightKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        CGRect f = table.frame;
        f.size.height = original.doubleValue;
        table.frame = f;
    }
    [gDYFSStretchedTables removeAllObjects];
}

%hook AWEFeedDataSafeTableView
- (void)setFrame:(CGRect)frame {
    DYFSAdjustFeedTableFrame(self, &frame);
    %orig(frame);
}
%end

// AWEFeedTableView 在部分版本会自己实现 setFrame:，因此基类 hook 不够。
@interface AWEFeedTableView : UITableView
@end
%hook AWEFeedTableView
- (void)setFrame:(CGRect)frame {
    DYFSAdjustFeedTableFrame(self, &frame);
    %orig(frame);
}
%end

#pragma mark - Author profile / image works

@interface AWEStoryContainerCollectionView : UIView
@end

%hook AWEStoryContainerCollectionView
- (void)layoutSubviews {
    %orig;
    if (!DYFSIsEnabled()) return;
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
    DYFSAdjustFeedTableFrame(self, &frame);
    %orig(frame);
}
%end

#pragma mark - Live preview chrome

@interface AWELivePreStream4LayerContainerView : UIView
@property(nonatomic,strong) UIImageView *bottomDarkWatermark;
@property(nonatomic,strong) UIView *controlContainer;
@end

static BOOL DYFSIsLivePreviewController(UIView *view) {
    UIViewController *vc = DYFSFirstViewControllerFromView(view);
    if (!vc) return NO;
    NSString *name = NSStringFromClass(vc.class);
    return [name containsString:@"AWELiveNewPreStreamViewController"] ||
           [name containsString:@"AWELivePreStream"];
}

static void DYFSApplyLivePreviewLift(AWELivePreStream4LayerContainerView *container) {
    if (!container || !DYFSIsEnabled() || !container.window) return;
    if (!DYFSIsLivePreviewController(container)) return;

    UIView *control = container.controlContainer;
    if (control && !objc_getAssociatedObject(control, &kDYFSLiveAppliedKey)) {
        CGFloat lift = MAX(gDYFSCurrentTabBarHeight, gDYFSOriginalTabBarHeight);
        if (lift > 0.5) {
            CGAffineTransform base = control.transform;
            objc_setAssociatedObject(control, &kDYFSLiveAppliedKey,
                                     [NSValue valueWithCGAffineTransform:base],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            control.transform = CGAffineTransformTranslate(base, 0.0, -lift);
        }
    }

    UIView *watermark = container.bottomDarkWatermark;
    if (watermark && !objc_getAssociatedObject(watermark, &kDYFSLiveAppliedKey)) {
        CGFloat lift = MAX(gDYFSCurrentTabBarHeight, gDYFSOriginalTabBarHeight);
        CGAffineTransform base = watermark.transform;
        objc_setAssociatedObject(watermark, &kDYFSLiveAppliedKey,
                                 [NSValue valueWithCGAffineTransform:base],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        watermark.transform = CGAffineTransformTranslate(base, 0.0, -lift);
    }
}

%hook AWELivePreStream4LayerContainerView
- (void)layoutSubviews {
    %orig;
    if (!DYFSIsEnabled()) return;
    if (!self.window) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        DYFSApplyLivePreviewLift(self);
    });
}
%end

#pragma mark - Visual cleanup needed by fullscreen

@interface AWEPlayInteractionProgressContainerView : UIView @end
%hook AWEPlayInteractionProgressContainerView
- (void)layoutSubviews {
    %orig;
    if (!DYFSIsEnabled()) return;
    for (UIView *v in self.subviews) if ([v isMemberOfClass:UIView.class]) v.backgroundColor = UIColor.clearColor;
}
%end

@interface AWEDPlayerProgressContainerView : UIView @end
%hook AWEDPlayerProgressContainerView
- (void)layoutSubviews {
    %orig;
    if (!DYFSIsEnabled()) return;
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
    if (!DYFSIsEnabled()) return;
    for (UIView *v in self.subviews) if ([v isMemberOfClass:UIView.class]) v.backgroundColor=UIColor.clearColor;
}
%end

@interface AFDViewedBottomView : UIView
@property(nonatomic,strong) UIView *effectView;
@end
%hook AFDViewedBottomView
- (void)layoutSubviews {
    %orig;
    if (!DYFSIsEnabled()) return;
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
    if (!DYFSIsEnabled()) {
        %orig(center);
        return;
    }
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
    if (!DYFSIsEnabled()) {
        %orig(frame);
        return;
    }
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
        for (UIView *v in self.subviews) [saved addObject:[NSValue valueWithCGRect:v.frame]];
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

#pragma mark - Global video geometry guard

// 40.4.0 writes the actual video container and the interaction HUD through
// UIView setFrame:. Intercept the write itself so search-page extra content
// cannot move the video down or leave a black strip below it.

static Class DYFSMergeClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = NSClassFromString(@"AWEDPlayerViewController_Merge"); });
    return cls;
}

static Class DYFSHUDClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = NSClassFromString(@"AWEPlayInteractionViewController"); });
    return cls;
}

static UIView *DYFSCellContentView(UIView *view) {
    Class cls = NSClassFromString(@"UITableViewCellContentView");
    if (!cls) return nil;
    for (NSUInteger i = 0; view && i < 12; i++, view = view.superview) {
        if ([view isKindOfClass:cls]) return view;
    }
    return nil;
}

static CGFloat DYFSFullCellHeightForView(UIView *view) {
    UIView *content = DYFSCellContentView(view ? view.superview : nil);
    CGFloat h = content ? CGRectGetHeight(content.bounds) : 0.0;
    UIWindow *window = view.window;
    CGFloat screenH = window ? CGRectGetHeight(window.bounds) : CGRectGetHeight(UIScreen.mainScreen.bounds);
    if (screenH > 0.0 && h > screenH) h = screenH;
    return h;
}

static BOOL DYFSCanFullscreenMerge(UIViewController *merge) {
    if (!merge || ![merge isKindOfClass:DYFSMergeClass()]) return NO;

    id model = nil;
    @try { model = [merge valueForKey:@"model"]; } @catch (__unused NSException *e) {}

    NSNumber *type = nil;
    @try { type = [model valueForKey:@"awemeType"]; } @catch (__unused NSException *e) {}
    if (type && type.longLongValue == 68) return NO;

    NSNumber *landscape = nil;
    @try { landscape = [merge valueForKey:@"hasInlandscape"]; } @catch (__unused NSException *e) {}
    if (landscape.boolValue) return NO;

    if ([merge respondsToSelector:@selector(isInLandscapeFeedStatus)]) {
        BOOL inLandscape = NO;
        @try { inLandscape = ((BOOL (*)(id, SEL))objc_msgSend)(merge, @selector(isInLandscapeFeedStatus)); }
        @catch (__unused NSException *e) {}
        if (inLandscape) return NO;
    }

    id video = nil;
    @try { video = [model valueForKey:@"video"]; } @catch (__unused NSException *e) {}
    NSNumber *w = nil;
    NSNumber *h = nil;
    @try { w = [video valueForKey:@"width"]; h = [video valueForKey:@"height"]; }
    @catch (__unused NSException *e) {}

    double width = w.doubleValue;
    double height = h.doubleValue;
    return width <= 0.0 || height <= 0.0 || (height / width) >= 1.70;
}

static CGRect DYFSAdjustMergeFrame(UIView *view, CGRect frame) {
    if (!DYFSIsEnabled() || !view) return CGRectNull;

    UIWindow *window = view.window;
    if (window && window.windowLevel != UIWindowLevelNormal) return CGRectNull;

    UIViewController *owner = (UIViewController *)view.nextResponder;
    if (![owner isKindOfClass:DYFSMergeClass()]) return CGRectNull;
    if (!DYFSCanFullscreenMerge(owner)) return CGRectNull;

    UIView *parent = view.superview;
    if (!parent) return CGRectNull;

    CGFloat width = CGRectGetWidth(parent.bounds);
    CGFloat height = CGRectGetHeight(parent.bounds);
    if (width <= 0.0 || height <= 0.0) return CGRectNull;

    CGFloat full = DYFSFullCellHeightForView(view);
    if (full > height) height = full;

    if (window) {
        CGFloat screenH = CGRectGetHeight(window.bounds);
        if (screenH > 0.0 && height > screenH) height = screenH;
    }

    CGRect target = CGRectMake(0.0, 0.0, width, height);
    if (fabs(frame.origin.x - target.origin.x) <= 0.5 &&
        fabs(frame.origin.y - target.origin.y) <= 0.5 &&
        fabs(frame.size.width - target.size.width) <= 0.5 &&
        fabs(frame.size.height - target.size.height) <= 0.5) return CGRectNull;
    return target;
}

static CGRect DYFSAdjustHUDFrame(UIView *view, CGRect frame) {
    if (!DYFSIsEnabled() || !view) return CGRectNull;

    UIResponder *owner = view.nextResponder;
    if (![owner isKindOfClass:DYFSHUDClass()]) return CGRectNull;

    UIView *table = DYFSFeedTableForView(view);
    if (!table) return CGRectNull;

    NSNumber *originalNumber = objc_getAssociatedObject(table, &kDYFSFeedTableOriginalHeightKey);
    CGFloat original = originalNumber.doubleValue;
    if (original <= 0.0) return CGRectNull;

    if (frame.size.height <= original + 0.5 && fabs(frame.origin.y) <= 0.5) return CGRectNull;

    frame.origin.y = 0.0;
    frame.size.height = original;
    return frame;
}

%hook UIView
- (void)setFrame:(CGRect)frame {
    CGRect adjusted = DYFSAdjustMergeFrame(self, frame);
    if (!CGRectIsNull(adjusted)) {
        %orig(adjusted);
        return;
    }
    adjusted = DYFSAdjustHUDFrame(self, frame);
    if (!CGRectIsNull(adjusted)) {
        %orig(adjusted);
        return;
    }
    %orig(frame);
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
    item.identifier = kDYFSFullScreenEnabledKey;
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

        BOOL enabled = !strongItem.isSwitchOn;
        strongItem.isSwitchOn = enabled;

        [[NSUserDefaults standardUserDefaults] setBool:enabled
                                                  forKey:kDYFSFullScreenEnabledKey];
        [[NSUserDefaults standardUserDefaults] synchronize];

        NSLog(@"[DY-FullScreen] switchChanged -> %@", enabled ? @"ON" : @"OFF");

        if (!enabled) {
            DYFSRunRestoreHooks();
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *window = DYFSActiveWindow();
            [window.rootViewController.view setNeedsLayout];
            [window.rootViewController.view layoutIfNeeded];
        });
    };
    return item;
}

%hook AWESettingsViewModel
- (NSArray *)sectionDataArray {
    NSArray *sections = %orig;
    if (![sections isKindOfClass:NSArray.class]) return sections;

    for (id section in sections) {
        NSArray *items = nil;
        @try { items = [section valueForKey:@"itemArray"]; } @catch (__unused NSException *e) {}
        for (id item in items) {
            NSString *identifier = nil;
            @try { identifier = [item valueForKey:@"identifier"]; } @catch (__unused NSException *e) {}
            if ([identifier isEqualToString:kDYFSFullScreenEnabledKey] || [identifier isEqualToString:@"DYFSNativeFullScreen"]) return sections;
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

#pragma mark - Author profile comment bar removal

@interface AWEAwemeDetailTableViewController : UIViewController
@property(nonatomic,copy) NSString *referString;
- (BOOL)canShowFixedBottomBar;
- (void)setBottomBarHidden:(BOOL)hidden;
@end

static BOOL DYFSShouldHideDetailBottomBar(void) {
    return DYFSIsEnabled();
}

static BOOL DYFSIsAuthorWorkDetailContext(UIView *view) {
    if (!view) return NO;
    UIResponder *r = view;
    NSInteger depth = 0;
    while ((r = [r nextResponder]) && depth++ < 40) {
        NSString *name = NSStringFromClass(r.class);
        if ([name containsString:@"UserHome"] ||
            [name containsString:@"UserProfile"] ||
            [name containsString:@"ProfileViewController"] ||
            [name containsString:@"Personal"] ||
            [name containsString:@"AWEAwemeDetailCellViewController"]) {
            return YES;
        }
    }
    return NO;
}

%hook AWEAwemeDetailTableViewController
- (BOOL)canShowFixedBottomBar {
    if (DYFSShouldHideDetailBottomBar()) return NO;
    return %orig;
}

- (void)setBottomBarHidden:(BOOL)hidden {
    if (DYFSShouldHideDetailBottomBar()) hidden = YES;
    %orig(hidden);
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (DYFSShouldHideDetailBottomBar() &&
        [self respondsToSelector:@selector(setBottomBarHidden:)]) {
        [self setBottomBarHidden:YES];
    }
}
%end

@interface AWEAwemeIMDetailTableViewController : UIViewController
- (void)setBottomBarHidden:(BOOL)hidden;
@end
%hook AWEAwemeIMDetailTableViewController
- (void)setBottomBarHidden:(BOOL)hidden {
    if (DYFSShouldHideDetailBottomBar()) hidden = YES;
    %orig(hidden);
}
%end

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
        [defaults setBool:NO forKey:kDYFSFullScreenEnabledKey];
        [defaults synchronize];
    }

    %init(_ungrouped);

    if (!gDYFSStretchedTables) {
        gDYFSStretchedTables = [NSHashTable weakObjectsHashTable];
    }
    DYFSRegisterRestore(DYFSRestoreFeedTables);

    Class swiftCommentInput = NSClassFromString(@"AWECommentInputViewSwiftImpl.CommentInputContainerView");
    if (swiftCommentInput) {
        %init(DYFSAuthorSwiftCommentInput, CommentInputContainerView=swiftCommentInput);
    }

    NSLog(@"[DY-FullScreen] loaded, fullscreen=%@", DYFSIsEnabled() ? @"ON" : @"OFF");
}

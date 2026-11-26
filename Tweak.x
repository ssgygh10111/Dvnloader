// Dvnloader — record live Twitch streams and download past broadcasts from inside the Twitch app.
//
// Long-press the video (one finger) → Choose Quality → record / download.
// The channel or broadcast is picked up automatically from what's playing.

#import <UIKit/UIKit.h>
#import "DVTwitch.h"
#import "DVDetector.h"
#import "DVSheetController.h"

#pragma mark - Long-press on the player

@interface DVGestureHandler : NSObject <UIGestureRecognizerDelegate>
@end

static BOOL DVLooksLikePlayer(UIView *v) {
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ keys = @[@"player", @"video", @"stream", @"ivs", @"media"]; });
    for (UIView *cur = v; cur; cur = cur.superview) {
        NSString *n = NSStringFromClass(cur.class).lowercaseString;
        for (NSString *k in keys) if ([n containsString:k]) return YES;
        NSString *ln = NSStringFromClass(cur.layer.class).lowercaseString;
        if ([ln containsString:@"player"]) return YES;
    }
    return NO;
}

@implementation DVGestureHandler

- (void)fired:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan || [DVSheetController isShowing]) return;

    UIWindow *w = (UIWindow *)g.view;
    CGPoint p = [g locationInView:w];
    UIView *hit = [w hitTest:p withEvent:nil];
    BOOL landscape = w.bounds.size.width > w.bounds.size.height;
    BOOL topArea = p.y < w.bounds.size.height * 0.42; // portrait player sits at the top
    if (!DVLooksLikePlayer(hit) && !landscape && !topArea) return;

    DVKind kind;
    NSString *ident = nil;
    BOOL known = [DVDetector current:&kind ident:&ident];
    if (!known && !DVLooksLikePlayer(hit)) return;

    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    if (known) [DVSheetController presentWithKind:kind ident:ident];
    else [DVSheetController presentWithLink:nil];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    // Don't steal long-presses from our own sheet or from text fields/controls.
    UIView *v = touch.view;
    if ([v isKindOfClass:UIControl.class] || [v isKindOfClass:UITextView.class]) return NO;
    return ![DVSheetController isShowing];
}

@end

static DVGestureHandler *gHandler;

static void DVInstallGesture(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (!w.isKeyWindow) continue;
            for (UIGestureRecognizer *g in w.gestureRecognizers) {
                if ([g.name isEqualToString:@"DVGesture"]) return;
            }
            UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:gHandler action:@selector(fired:)];
            lp.name = @"DVGesture";
            lp.numberOfTouchesRequired = 1;
            lp.minimumPressDuration = 0.6;
            lp.cancelsTouchesInView = NO;
            lp.delaysTouchesBegan = NO;
            lp.delegate = gHandler;
            [w addGestureRecognizer:lp];
            return;
        }
    }
}

#pragma mark - Share-sheet action (bonus way in)

@interface DVActivity : UIActivity
@property (nonatomic, copy) NSString *link;
@end

static NSString *DVLinkFromItems(NSArray *items) {
    for (id item in items) {
        NSString *s = nil;
        if ([item isKindOfClass:NSURL.class]) s = [(NSURL *)item absoluteString];
        else if ([item isKindOfClass:NSString.class]) s = item;
        else if ([item isKindOfClass:NSAttributedString.class]) s = [(NSAttributedString *)item string];
        NSString *l = [DVTwitch findLinkInString:s];
        DVKind k;
        NSString *ident = nil;
        if (l && [DVTwitch parseLink:l kind:&k ident:&ident]) return l;
    }
    return nil;
}

@implementation DVActivity
+ (UIActivityCategory)activityCategory { return UIActivityCategoryAction; }
- (UIActivityType)activityType { return @"com.dvnloader.download"; }
- (NSString *)activityTitle { return @"Dvnloader"; }
- (UIImage *)activityImage { return [UIImage systemImageNamed:@"arrow.down.circle"]; }
- (BOOL)canPerformWithActivityItems:(NSArray *)activityItems { return DVLinkFromItems(activityItems) != nil; }
- (void)prepareWithActivityItems:(NSArray *)activityItems { self.link = DVLinkFromItems(activityItems); }
- (void)performActivity {
    NSString *link = self.link;
    [self activityDidFinish:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [DVSheetController presentWithLink:link];
    });
}
@end

%hook UIActivityViewController

- (instancetype)initWithActivityItems:(NSArray *)activityItems applicationActivities:(NSArray *)applicationActivities {
    BOOL ownFile = activityItems.count == 1 && [activityItems.firstObject isKindOfClass:NSURL.class] && [(NSURL *)activityItems.firstObject isFileURL];
    if (!ownFile) {
        NSMutableArray *acts = applicationActivities ? [applicationActivities mutableCopy] : [NSMutableArray array];
        [acts insertObject:[DVActivity new] atIndex:0];
        applicationActivities = acts;
    }
    return %orig(activityItems, applicationActivities);
}

%end

%ctor {
    [DVDetector install];
    gHandler = [DVGestureHandler new];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *n) { DVInstallGesture(); }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                      object:nil
                                                       queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *n) { DVInstallGesture(); }];
}

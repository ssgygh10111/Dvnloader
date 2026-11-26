// Dvnloader — record live Twitch streams and download past broadcasts from inside the Twitch app.
//
// Two ways in:
//   1. Share button on any stream / past broadcast  ->  "Dvnloader" in the share sheet.
//   2. Two-finger long-press anywhere in the app    ->  sheet that takes a link or channel name.

#import <UIKit/UIKit.h>
#import "DVTwitch.h"
#import "DVSheetController.h"

#pragma mark - Share-sheet action

@interface DVActivity : UIActivity
@property (nonatomic, copy) NSString *link;
@end

static NSString *DVLinkFromItem(id item) {
    if ([item isKindOfClass:NSURL.class]) return [DVTwitch findLinkInString:[(NSURL *)item absoluteString]];
    if ([item isKindOfClass:NSString.class]) return [DVTwitch findLinkInString:item];
    if ([item isKindOfClass:NSAttributedString.class]) return [DVTwitch findLinkInString:[(NSAttributedString *)item string]];
    return nil;
}

// The system hands UIActivity the *resolved* share items (item sources already asked),
// so the link is read here instead of poking Twitch's own item-source objects.
static NSString *DVLinkFromItems(NSArray *items) {
    for (id item in items) {
        NSString *l = DVLinkFromItem(item);
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
    // Wait for the share sheet to finish dismissing before presenting ours.
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

#pragma mark - Two-finger long-press fallback

@interface DVGestureHandler : NSObject <UIGestureRecognizerDelegate>
@end

@implementation DVGestureHandler
- (void)fired:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UINotificationFeedbackGenerator *h = [UINotificationFeedbackGenerator new];
    [h notificationOccurred:UINotificationFeedbackTypeSuccess];
    [DVSheetController presentWithLink:nil];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
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
            lp.numberOfTouchesRequired = 2;
            lp.minimumPressDuration = 0.8;
            lp.cancelsTouchesInView = NO;
            lp.delegate = gHandler;
            [w addGestureRecognizer:lp];
            return;
        }
    }
}

%ctor {
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

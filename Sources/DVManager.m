#import "DVManager.h"
#import "DVDownloadTask.h"
#import "DVTwitch.h"
#import "DVSheetController.h"
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>

#define DVPurple [UIColor colorWithRed:0x91/255.0 green:0x47/255.0 blue:0xFF/255.0 alpha:1]

#pragma mark - Pass-through window (only the bar takes touches)

@interface DVBarWindow : UIWindow
@property (nonatomic, weak) UIView *bar;
@end

@implementation DVBarWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (!self.bar || self.bar.hidden) return nil;
    return [v isDescendantOfView:self.bar] ? v : nil;
}
@end

@interface DVBarController : UIViewController
@end
@implementation DVBarController
- (BOOL)prefersStatusBarHidden { return NO; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
@end

#pragma mark - Manager

@interface DVManager ()
@property (nonatomic, strong) DVDownloadTask *task;
@property (nonatomic, strong) DVBarWindow *window;
@property (nonatomic, strong) UIView *bar, *fill;
@property (nonatomic, strong) NSLayoutConstraint *fillWidth;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, strong) UIImageView *doneIcon;
@property (nonatomic, strong) UILabel *centerLabel, *rightLabel;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSURL *result;
@property (nonatomic, copy) NSString *errorText;
@property (nonatomic) UIBackgroundTaskIdentifier bgTask;
@property (nonatomic, strong) AVAudioPlayer *keepAlive;
@end

@implementation DVManager

+ (instancetype)shared {
    static DVManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = [DVManager new];
        m.bgTask = UIBackgroundTaskInvalid;
        [[NSNotificationCenter defaultCenter] addObserver:m selector:@selector(didEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:m selector:@selector(willEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    });
    return m;
}

- (BOOL)busy {
    return self.task != nil;
}

#pragma mark Start / stop

- (DVDownloadTask *)makeTask {
    self.result = nil;
    self.errorText = nil;
    DVDownloadTask *t = [DVDownloadTask new];
    __weak typeof(self) ws = self;
    t.onFinish = ^(NSURL *file, NSError *error) { [ws finished:file error:error]; };
    self.task = t;
    [self showBar];
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    [self refresh];
    return t;
}

- (void)startLive:(NSURL *)url ident:(NSString *)ident quality:(NSString *)quality maxDuration:(double)secs fileName:(NSString *)name {
    if (self.task) return;
    DVDownloadTask *t = [self makeTask];
    t.liveIdent = ident;
    t.liveQuality = quality;
    [t startLive:url maxDuration:secs fileName:name];
}

- (void)startVOD:(NSURL *)url from:(double)start to:(double)end fileName:(NSString *)name {
    if (self.task) return;
    DVDownloadTask *t = [self makeTask];
    [t startVOD:url from:start to:end fileName:name];
}

- (void)stop {
    [self.task cancel];
}

- (void)stopTapped {
    if (!self.task) { [self hideBar]; return; }
    BOOL live = self.task.live;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:live ? @"Stop recording?" : @"Cancel download?"
                                                               message:live ? @"What's been recorded so far will be saved." : nil
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:live ? @"Stop & save" : @"Cancel download" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [self stop];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Keep going" style:UIAlertActionStyleCancel handler:nil]];
    [[DVSheetController topViewController] presentViewController:a animated:YES completion:nil];
}

#pragma mark Finish

- (void)finished:(NSURL *)file error:(NSError *)error {
    self.task = nil;
    [self.timer invalidate];
    self.timer = nil;
    [self endBackgroundSupport];
    if (!file) {
        [self showMessage:error.localizedDescription ?: @"Something went wrong" icon:@"exclamationmark.triangle.fill" color:UIColor.systemYellowColor percent:@""];
        self.errorText = error.localizedDescription;
        [self hideBarAfter:8];
        return;
    }
    self.result = file;
    if (UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(file.path)) {
        [self showMessage:@"Saving to Photos…" icon:@"photo.on.rectangle" color:UIColor.whiteColor percent:@""];
        [self saveToPhotos:file];
    } else {
        [self showMessage:@"Saved in Files › Twitch › Dvnloader" icon:@"checkmark.circle.fill" color:UIColor.systemGreenColor percent:@"Share"];
        [self hideBarAfter:10];
    }
}

- (void)saveToPhotos:(NSURL *)file {
    void (^save)(void) = ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:file];
        } completionHandler:^(BOOL ok, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ok) [self showMessage:@"Saved to Photos" icon:@"checkmark.circle.fill" color:UIColor.systemGreenColor percent:@"Share"];
                else [self showMessage:@"Couldn't save to Photos — tap to share" icon:@"exclamationmark.triangle.fill" color:UIColor.systemYellowColor percent:@"Share"];
                [self hideBarAfter:10];
            });
        }];
    };
    if (@available(iOS 14, *)) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus st) {
            if (st == PHAuthorizationStatusAuthorized || st == PHAuthorizationStatusLimited) save();
            else dispatch_async(dispatch_get_main_queue(), ^{
                [self showMessage:@"Allow Photos access in Settings — tap to share" icon:@"exclamationmark.triangle.fill" color:UIColor.systemYellowColor percent:@"Share"];
                [self hideBarAfter:10];
            });
        }];
    } else {
        save();
    }
}

- (void)barTapped {
    if (self.task) return;
    if (self.result) {
        UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:@[self.result] applicationActivities:nil];
        a.popoverPresentationController.sourceView = self.bar;
        a.popoverPresentationController.sourceRect = self.bar.bounds;
        [[DVSheetController topViewController] presentViewController:a animated:YES completion:nil];
        [self hideBar];
    } else if (self.errorText) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Dvnloader" message:self.errorText preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [[DVSheetController topViewController] presentViewController:a animated:YES completion:nil];
        [self hideBar];
    }
}

#pragma mark Bar UI

static NSString *DVMB(unsigned long long b) {
    double mb = b / 1000000.0;
    return mb >= 1000 ? [NSString stringWithFormat:@"%.2f GB", mb / 1000.0] : [NSString stringWithFormat:@"%.1f MB", mb];
}

- (void)refresh {
    DVDownloadTask *t = self.task;
    if (!t) return;
    double frac = -1;
    NSString *center;
    unsigned long long b = t.bytesWritten;
    if (t.note && ([t.note hasPrefix:@"Converting"] || [t.note hasPrefix:@"Skipping"] || [t.note hasPrefix:@"Parts"])) {
        center = t.live && ![t.note hasPrefix:@"Converting"] ? [NSString stringWithFormat:@"%@  %@", t.note, DVMB(b)] : t.note;
        if ([t.note hasPrefix:@"Converting"]) frac = 1;
    } else if (t.live) {
        if (t.maxDuration > 0) {
            frac = MIN(1, t.recordedSeconds / t.maxDuration);
            double estimate = t.recordedSeconds > 2 ? b / t.recordedSeconds * t.maxDuration : 0;
            center = estimate > 0 ? [NSString stringWithFormat:@"%@ / %@", DVMB(b), DVMB(estimate)]
                                  : [NSString stringWithFormat:@"%@", DVMB(b)];
        } else {
            center = [NSString stringWithFormat:@"REC %@  •  %@", DVFormatTime(t.recordedSeconds), DVMB(b)];
        }
    } else {
        NSInteger total = t.segmentsTotal, done = t.segmentsDone;
        if (total > 0) {
            frac = (double)done / total;
            double estimate = done > 0 ? (double)b / done * total : 0;
            center = estimate > 0 ? [NSString stringWithFormat:@"%@ / %@", DVMB(b), DVMB(estimate)] : @"Starting…";
        } else {
            center = @"Starting…";
        }
    }
    self.centerLabel.text = center;
    self.rightLabel.text = frac >= 0 ? [NSString stringWithFormat:@"%d%%", (int)floor(frac * 100)] : (t.live ? @"LIVE" : @"");
    self.rightLabel.textColor = (frac < 0 && t.live) ? UIColor.systemRedColor : UIColor.whiteColor;
    [self setFill:frac < 0 ? 0 : frac];
}

- (void)setFill:(double)f {
    self.fillWidth.active = NO;
    self.fillWidth = [self.fill.widthAnchor constraintEqualToAnchor:self.bar.widthAnchor multiplier:MAX(0.0001, MIN(1, f))];
    self.fillWidth.active = YES;
    [UIView animateWithDuration:0.3 animations:^{ [self.bar layoutIfNeeded]; }];
}

- (void)showMessage:(NSString *)text icon:(NSString *)symbol color:(UIColor *)color percent:(NSString *)right {
    [self showBar];
    self.stopButton.hidden = YES;
    self.doneIcon.hidden = NO;
    self.doneIcon.image = [UIImage systemImageNamed:symbol];
    self.doneIcon.tintColor = color;
    self.centerLabel.text = text;
    self.rightLabel.text = right;
    self.rightLabel.textColor = DVPurple;
    [self setFill:0];
}

- (void)buildWindow {
    UIWindowScene *scene = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if ([sc isKindOfClass:UIWindowScene.class] && sc.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)sc; break; }
    }
    if (!scene) {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) if ([sc isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)sc; break; }
    }
    if (!scene) return;

    DVBarWindow *w = [[DVBarWindow alloc] initWithWindowScene:scene];
    w.windowLevel = UIWindowLevelStatusBar - 1;
    w.backgroundColor = UIColor.clearColor;
    DVBarController *vc = [DVBarController new];
    vc.view.backgroundColor = UIColor.clearColor;
    w.rootViewController = vc;

    UIView *bar = [UIView new];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = [UIColor colorWithRed:0.16 green:0.16 blue:0.19 alpha:0.97];
    bar.layer.cornerRadius = 22;
    bar.clipsToBounds = YES;
    bar.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    [vc.view addSubview:bar];

    UIView *fill = [UIView new];
    fill.translatesAutoresizingMaskIntoConstraints = NO;
    fill.backgroundColor = [DVPurple colorWithAlphaComponent:0.55];
    fill.userInteractionEnabled = NO;
    [bar addSubview:fill];

    UIButton *stop = [UIButton buttonWithType:UIButtonTypeSystem];
    stop.translatesAutoresizingMaskIntoConstraints = NO;
    [stop setImage:[UIImage systemImageNamed:@"stop.circle" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22]] forState:UIControlStateNormal];
    stop.tintColor = UIColor.whiteColor;
    [stop addTarget:self action:@selector(stopTapped) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:stop];

    UIImageView *icon = [UIImageView new];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.hidden = YES;
    [bar addSubview:icon];

    UILabel *center = [UILabel new];
    center.translatesAutoresizingMaskIntoConstraints = NO;
    center.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
    center.textColor = UIColor.whiteColor;
    center.textAlignment = NSTextAlignmentCenter;
    center.adjustsFontSizeToFitWidth = YES;
    center.minimumScaleFactor = 0.7;
    [bar addSubview:center];

    UILabel *right = [UILabel new];
    right.translatesAutoresizingMaskIntoConstraints = NO;
    right.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightBold];
    right.textColor = UIColor.whiteColor;
    right.textAlignment = NSTextAlignmentRight;
    [bar addSubview:right];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(barTapped)];
    [bar addGestureRecognizer:tap];

    UILayoutGuide *g = vc.view.safeAreaLayoutGuide;
    self.fillWidth = [fill.widthAnchor constraintEqualToAnchor:bar.widthAnchor multiplier:0.0001];
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [bar.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [bar.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-6],
        [bar.heightAnchor constraintEqualToConstant:44],
        [fill.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [fill.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [fill.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
        self.fillWidth,
        [stop.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:6],
        [stop.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [stop.widthAnchor constraintEqualToConstant:36],
        [stop.heightAnchor constraintEqualToConstant:36],
        [icon.centerXAnchor constraintEqualToAnchor:stop.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:22],
        [icon.heightAnchor constraintEqualToConstant:22],
        [right.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-16],
        [right.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [right.widthAnchor constraintEqualToConstant:52],
        [center.leadingAnchor constraintEqualToAnchor:stop.trailingAnchor constant:4],
        [center.trailingAnchor constraintEqualToAnchor:right.leadingAnchor constant:-4],
        [center.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
    ]];

    w.bar = bar;
    self.window = w;
    self.bar = bar;
    self.fill = fill;
    self.stopButton = stop;
    self.doneIcon = icon;
    self.centerLabel = center;
    self.rightLabel = right;
}

- (void)showBar {
    if (!self.window) [self buildWindow];
    self.stopButton.hidden = NO;
    self.doneIcon.hidden = YES;
    self.window.hidden = NO;
    self.bar.hidden = NO;
    self.bar.alpha = 1;
}

- (void)hideBar {
    [UIView animateWithDuration:0.25 animations:^{ self.bar.alpha = 0; } completion:^(BOOL f) {
        if (self.task) { self.bar.alpha = 1; return; }
        self.window.hidden = YES;
        self.result = nil;
        self.errorText = nil;
    }];
}

- (void)hideBarAfter:(NSTimeInterval)s {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.task) [self hideBar];
    });
}

#pragma mark Keep running in the background

// A silent looping sound keeps the app alive (Twitch already has background audio),
// so recordings and downloads continue after leaving the app.
- (void)didEnterBackground {
    if (!self.task) return;
    self.bgTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Dvnloader" expirationHandler:^{
        [UIApplication.sharedApplication endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
    }];
    if (!self.keepAlive) {
        NSMutableData *wav = [NSMutableData data];
        uint32_t rate = 8000, samples = 8000, dataLen = samples * 2, riffLen = 36 + dataLen, fmtLen = 16, byteRate = rate * 2;
        uint16_t pcm = 1, ch = 1, align = 2, bits = 16;
        [wav appendBytes:"RIFF" length:4]; [wav appendBytes:&riffLen length:4]; [wav appendBytes:"WAVEfmt " length:8];
        [wav appendBytes:&fmtLen length:4]; [wav appendBytes:&pcm length:2]; [wav appendBytes:&ch length:2];
        [wav appendBytes:&rate length:4]; [wav appendBytes:&byteRate length:4]; [wav appendBytes:&align length:2];
        [wav appendBytes:&bits length:2]; [wav appendBytes:"data" length:4]; [wav appendBytes:&dataLen length:4];
        [wav increaseLengthBy:dataLen];
        self.keepAlive = [[AVAudioPlayer alloc] initWithData:wav error:nil];
        self.keepAlive.numberOfLoops = -1;
        self.keepAlive.volume = 0;
    }
    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [session setActive:YES error:nil];
    [self.keepAlive play];
}

- (void)willEnterForeground {
    [self.keepAlive stop];
    if (self.bgTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
    }
}

- (void)endBackgroundSupport {
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) {
        [self.keepAlive stop];
    }
    if (self.bgTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
    }
}

@end

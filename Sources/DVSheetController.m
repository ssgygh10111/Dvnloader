#import "DVSheetController.h"
#import "DVDownloadTask.h"
#import "DVRangeSlider.h"

#define DVPurple [UIColor colorWithRed:0x91/255.0 green:0x47/255.0 blue:0xFF/255.0 alpha:1]
#define DVBackground [UIColor colorWithRed:0x1F/255.0 green:0x1F/255.0 blue:0x23/255.0 alpha:1]
#define DVCard [UIColor colorWithRed:0x2C/255.0 green:0x2C/255.0 blue:0x33/255.0 alpha:1]
#define DVDim(a) [UIColor colorWithWhite:1 alpha:(a)]

static __weak UIViewController *gCurrent;

@interface DVSheetController () <UIPickerViewDataSource, UIPickerViewDelegate, UITextFieldDelegate>
@property (nonatomic, copy) NSString *link;
@property (nonatomic) BOOL hasTarget;
@property (nonatomic) DVKind kind;
@property (nonatomic, copy) NSString *ident;

@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, strong) UITextField *field;

@property (nonatomic, strong) NSArray<DVVariant *> *variants;
@property (nonatomic, strong) DVVariant *selected;
@property (nonatomic, strong) UIButton *qualityButton;

@property (nonatomic, strong) UIPickerView *picker;
@property (nonatomic) double vodDuration;
@property (nonatomic, strong) DVRangeSlider *slider;
@property (nonatomic, strong) UILabel *fromLabel, *toLabel, *rangeLabel;

@property (nonatomic, strong) DVDownloadTask *task;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSURL *resultFile;
@end

@implementation DVSheetController

#pragma mark - Presenting

+ (UIViewController *)topViewController {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { window = w; break; }
        }
        if (window) break;
    }
    if (!window) window = UIApplication.sharedApplication.windows.firstObject;
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc = vc.presentedViewController;
    return vc;
}

+ (BOOL)isShowing {
    return gCurrent != nil;
}

+ (void)show:(DVSheetController *)c {
    if (gCurrent) return;
    c.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        c.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
        c.sheetPresentationController.prefersGrabberVisible = YES;
    }
    gCurrent = c;
    [[self topViewController] presentViewController:c animated:YES completion:nil];
}

+ (void)presentWithKind:(DVKind)kind ident:(NSString *)ident {
    DVSheetController *c = [DVSheetController new];
    c.hasTarget = YES;
    c.kind = kind;
    c.ident = ident;
    [self show:c];
}

+ (void)presentWithLink:(NSString *)link {
    DVSheetController *c = [DVSheetController new];
    DVKind kind;
    NSString *ident = nil;
    if ([DVTwitch parseLink:link kind:&kind ident:&ident]) {
        c.hasTarget = YES;
        c.kind = kind;
        c.ident = ident;
    }
    [self show:c];
}

#pragma mark - Building blocks

- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color ?: UIColor.whiteColor;
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 0;
    return l;
}

- (UIButton *)button:(NSString *)title primary:(BOOL)primary action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    b.backgroundColor = primary ? DVPurple : DVCard;
    b.layer.cornerRadius = 8;
    [b.heightAnchor constraintEqualToConstant:primary ? 44 : 46].active = YES;
    if (action) [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UILabel *)orLabel {
    return [self label:@"OR" size:15 weight:UIFontWeightSemibold color:DVDim(0.45)];
}

- (UIView *)spacer:(CGFloat)h {
    UIView *v = [UIView new];
    [v.heightAnchor constraintEqualToConstant:h].active = YES;
    return v;
}

- (void)reset {
    self.actionButton.hidden = YES;
    for (UIView *v in self.stack.arrangedSubviews) {
        [self.stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
}

- (void)setAction:(NSString *)symbol selector:(SEL)sel {
    [self.actionButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular];
    [self.actionButton setImage:[UIImage systemImageNamed:symbol withConfiguration:cfg] forState:UIControlStateNormal];
    [self.actionButton addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    self.actionButton.hidden = NO;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = DVBackground;
    self.view.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;

    UILabel *title = [self label:@"Dvnloader" size:17 weight:UIFontWeightSemibold color:nil];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20]] forState:UIControlStateNormal];
    self.closeButton.tintColor = UIColor.whiteColor;
    self.closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.closeButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.closeButton];

    self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.actionButton.tintColor = UIColor.whiteColor;
    self.actionButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.actionButton.hidden = YES;
    [self.view addSubview:self.actionButton];

    self.stack = [UIStackView new];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 14;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.stack];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:g.topAnchor constant:22],
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.closeButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [self.closeButton.leftAnchor constraintEqualToAnchor:g.leftAnchor constant:14],
        [self.closeButton.widthAnchor constraintEqualToConstant:44],
        [self.closeButton.heightAnchor constraintEqualToConstant:44],
        [self.actionButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [self.actionButton.rightAnchor constraintEqualToAnchor:g.rightAnchor constant:-14],
        [self.actionButton.widthAnchor constraintEqualToConstant:44],
        [self.actionButton.heightAnchor constraintEqualToConstant:44],
        [self.stack.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:40],
        [self.stack.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:36],
        [self.stack.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-36],
    ]];

    if (self.hasTarget) [self load];
    else [self showInput:nil];
}

- (void)close {
    [self.task cancel];
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Manual link (fallback)

- (void)showInput:(NSString *)error {
    [self reset];
    [self.stack addArrangedSubview:[self label:@"Paste a channel or past broadcast link" size:16 weight:UIFontWeightSemibold color:nil]];

    self.field = [UITextField new];
    self.field.placeholder = @"twitch.tv/… or channel name";
    self.field.textColor = UIColor.whiteColor;
    self.field.backgroundColor = DVCard;
    self.field.layer.cornerRadius = 8;
    self.field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.field.autocorrectionType = UITextAutocorrectionTypeNo;
    self.field.keyboardType = UIKeyboardTypeURL;
    self.field.returnKeyType = UIReturnKeyGo;
    self.field.delegate = self;
    self.field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 1)];
    self.field.leftViewMode = UITextFieldViewModeAlways;
    [self.field.heightAnchor constraintEqualToConstant:46].active = YES;
    [self.stack addArrangedSubview:self.field];

    if (error) [self.stack addArrangedSubview:[self label:error size:14 weight:UIFontWeightRegular color:UIColor.systemRedColor]];
    [self.stack addArrangedSubview:[self button:@"Paste" primary:NO action:@selector(paste)]];
    [self.stack addArrangedSubview:[self button:@"Continue" primary:YES action:@selector(submitLink)]];
    [self.stack addArrangedSubview:[self label:@"Tip: open a stream or past broadcast, then long-press the video."
                                          size:13 weight:UIFontWeightRegular color:DVDim(0.5)]];
}

- (void)paste {
    NSString *s = UIPasteboard.generalPasteboard.string;
    if (s) self.field.text = [DVTwitch findLinkInString:s] ?: s;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self submitLink];
    return NO;
}

- (void)submitLink {
    [self.field resignFirstResponder];
    DVKind kind;
    NSString *ident = nil;
    if (![DVTwitch parseLink:self.field.text kind:&kind ident:&ident]) {
        [self showInput:@"That doesn't look like a channel or broadcast link"];
        return;
    }
    self.kind = kind;
    self.ident = ident;
    [self load];
}

#pragma mark - Loading + quality

- (void)showLoading {
    [self reset];
    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spin.color = UIColor.whiteColor;
    [spin startAnimating];
    [self.stack addArrangedSubview:[self spacer:60]];
    [self.stack addArrangedSubview:spin];
}

- (void)showError:(NSString *)msg {
    [self reset];
    [self.stack addArrangedSubview:[self spacer:30]];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"exclamationmark.triangle.fill"]];
    icon.tintColor = UIColor.systemYellowColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon.heightAnchor constraintEqualToConstant:44].active = YES;
    [self.stack addArrangedSubview:icon];
    [self.stack addArrangedSubview:[self label:msg size:15 weight:UIFontWeightMedium color:nil]];
    [self.stack addArrangedSubview:[self spacer:10]];
    [self.stack addArrangedSubview:[self button:@"Try again" primary:YES action:@selector(load)]];
    [self.stack addArrangedSubview:[self button:@"Enter a link" primary:NO action:@selector(backToInput)]];
}

- (void)backToInput {
    [self showInput:nil];
}

- (void)load {
    [self showLoading];
    __weak typeof(self) ws = self;
    [DVTwitch fetchVariantsForKind:self.kind ident:self.ident completion:^(NSArray<DVVariant *> *variants, NSError *err) {
        if (!ws) return;
        if (!variants) {
            [ws showError:err.localizedDescription ?: @"Something went wrong"];
            return;
        }
        ws.variants = variants;
        [ws chooseQuality];
    }];
}

- (void)chooseQuality {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Choose Quality" message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) ws = self;
    for (DVVariant *v in self.variants) {
        [a addAction:[UIAlertAction actionWithTitle:v.name style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            ws.selected = v;
            [ws qualityChosen];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) {
        if (!ws.selected) [ws close];
    }]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)qualityChosen {
    if (self.kind == DVKindLive) {
        [self showLive];
        return;
    }
    [self showLoading];
    __weak typeof(self) ws = self;
    [DVTwitch fetchMediaPlaylist:self.selected.url completion:^(DVMediaPlaylist *pl, NSError *e) {
        if (!ws) return;
        if (!pl) {
            [ws showError:e.localizedDescription ?: @"Something went wrong"];
            return;
        }
        ws.vodDuration = pl.total;
        [ws showVOD];
    }];
}

- (UIView *)infoLine {
    NSString *who = self.kind == DVKindLive ? self.ident : [@"Video " stringByAppendingString:self.ident];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:[NSString stringWithFormat:@"%@  •  %@  ▾", who, self.selected.name] forState:UIControlStateNormal];
    [b setTitleColor:DVDim(0.55) forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [b addTarget:self action:@selector(chooseQuality) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - Live

- (void)showLive {
    [self reset];
    [self setAction:@"record.circle" selector:@selector(recordTimed)];
    [self.stack addArrangedSubview:[self label:@"Select recording duration" size:15 weight:UIFontWeightSemibold color:nil]];

    self.picker = [UIPickerView new];
    self.picker.dataSource = self;
    self.picker.delegate = self;
    [self.picker.heightAnchor constraintEqualToConstant:190].active = YES;
    [self.picker selectRow:1 inComponent:1 animated:NO];
    [self.stack addArrangedSubview:self.picker];

    [self.stack addArrangedSubview:[self spacer:20]];
    [self.stack addArrangedSubview:[self orLabel]];
    [self.stack addArrangedSubview:[self spacer:8]];
    [self.stack addArrangedSubview:[self button:@"Record until end" primary:YES action:@selector(recordUntilEnd)]];
    [self.stack addArrangedSubview:[self spacer:4]];
    [self.stack addArrangedSubview:[self infoLine]];
}

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView { return 2; }

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return component == 0 ? 24 : 60;
}

- (NSAttributedString *)pickerView:(UIPickerView *)pickerView attributedTitleForRow:(NSInteger)row forComponent:(NSInteger)component {
    NSString *s = [NSString stringWithFormat:@"%ld %@", (long)row, component == 0 ? (row == 1 ? @"hour" : @"hours") : @"min"];
    return [[NSAttributedString alloc] initWithString:s attributes:@{NSForegroundColorAttributeName: UIColor.whiteColor}];
}

- (NSString *)fileBase {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyyMMdd-HHmm";
    NSString *who = self.kind == DVKindLive ? self.ident : [@"vod" stringByAppendingString:self.ident];
    return [NSString stringWithFormat:@"%@_%@", who, [f stringFromDate:NSDate.date]];
}

- (void)recordTimed {
    double secs = [self.picker selectedRowInComponent:0] * 3600.0 + [self.picker selectedRowInComponent:1] * 60.0;
    if (secs <= 0) return;
    [self startLive:secs];
}

- (void)recordUntilEnd {
    [self startLive:0];
}

- (void)startLive:(double)secs {
    DVDownloadTask *t = [self newTask];
    NSString *ident = self.ident, *qname = self.selected.name;
    t.refreshLiveURL = ^NSURL *{
        NSArray<DVVariant *> *vs = [DVTwitch variantsSyncForKind:DVKindLive ident:ident error:nil];
        for (DVVariant *v in vs) if ([v.name isEqualToString:qname]) return v.url;
        return vs.firstObject.url;
    };
    [self showProgress:YES];
    [t startLive:self.selected.url maxDuration:secs fileName:[self fileBase]];
}

#pragma mark - Past broadcast

- (void)showVOD {
    [self reset];
    [self setAction:@"square.and.arrow.down" selector:@selector(downloadRange)];

    UIStackView *head = [UIStackView new];
    head.spacing = 8;
    head.alignment = UIStackViewAlignmentCenter;
    UILabel *t = [self label:@"Specify the duration for downloading" size:15 weight:UIFontWeightSemibold color:nil];
    UIButton *info = [UIButton buttonWithType:UIButtonTypeInfoLight];
    info.tintColor = DVDim(0.8);
    [info addTarget:self action:@selector(showRangeInfo) forControlEvents:UIControlEventTouchUpInside];
    [info setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [head addArrangedSubview:t];
    [head addArrangedSubview:info];
    [self.stack addArrangedSubview:head];
    [self.stack addArrangedSubview:[self spacer:10]];

    self.fromLabel = [self label:@"" size:12 weight:UIFontWeightMedium color:DVDim(0.85)];
    self.toLabel = [self label:@"" size:12 weight:UIFontWeightMedium color:DVDim(0.85)];
    self.fromLabel.textAlignment = NSTextAlignmentLeft;
    self.toLabel.textAlignment = NSTextAlignmentRight;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[self.fromLabel, self.toLabel]];
    row.distribution = UIStackViewDistributionFillEqually;
    [self.stack addArrangedSubview:row];

    self.slider = [DVRangeSlider new];
    self.slider.maximumValue = self.vodDuration;
    self.slider.lowerValue = 0;
    self.slider.upperValue = self.vodDuration;
    [self.slider addTarget:self action:@selector(rangeChanged) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:self.slider];

    self.rangeLabel = [self label:@"" size:12 weight:UIFontWeightRegular color:DVDim(0.45)];
    [self.stack addArrangedSubview:self.rangeLabel];
    [self rangeChanged];

    [self.stack addArrangedSubview:[self spacer:20]];
    [self.stack addArrangedSubview:[self orLabel]];
    [self.stack addArrangedSubview:[self spacer:8]];
    [self.stack addArrangedSubview:[self button:@"Download full" primary:YES action:@selector(downloadFull)]];
    [self.stack addArrangedSubview:[self spacer:4]];
    [self.stack addArrangedSubview:[self infoLine]];
}

- (void)showRangeInfo {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Pick a part"
        message:@"Drag the two handles to choose where the clip starts and ends, then tap the download icon at the top right."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)rangeChanged {
    self.fromLabel.text = DVFormatTime(self.slider.lowerValue);
    self.toLabel.text = DVFormatTime(self.slider.upperValue);
    self.rangeLabel.text = [NSString stringWithFormat:@"Length: %@", DVFormatTime(self.slider.upperValue - self.slider.lowerValue)];
}

- (void)downloadRange {
    if (self.slider.upperValue - self.slider.lowerValue < 1) return;
    [self startVODFrom:self.slider.lowerValue to:self.slider.upperValue];
}

- (void)downloadFull {
    [self startVODFrom:0 to:0];
}

- (void)startVODFrom:(double)a to:(double)b {
    DVDownloadTask *t = [self newTask];
    [self showProgress:NO];
    [t startVOD:self.selected.url from:a to:b fileName:[self fileBase]];
}

#pragma mark - Progress / result

- (DVDownloadTask *)newTask {
    DVDownloadTask *t = [DVDownloadTask new];
    __weak typeof(self) ws = self;
    t.onProgress = ^(NSString *status, double fraction) {
        ws.statusLabel.text = status;
        ws.progressView.hidden = fraction < 0;
        if (fraction >= 0) [ws.progressView setProgress:fraction animated:YES];
    };
    t.onFinish = ^(NSURL *file, NSError *error) {
        ws.task = nil;
        ws.modalInPresentation = NO;
        ws.closeButton.hidden = NO;
        if (file) [ws showDone:file];
        else [ws showError:error.localizedDescription ?: @"Something went wrong"];
    };
    self.task = t;
    return t;
}

- (void)showProgress:(BOOL)live {
    [self reset];
    self.modalInPresentation = YES;
    self.closeButton.hidden = YES;
    [self.stack addArrangedSubview:[self spacer:30]];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:live ? @"record.circle" : @"arrow.down.circle"]];
    icon.tintColor = live ? UIColor.systemRedColor : DVPurple;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon.heightAnchor constraintEqualToConstant:50].active = YES;
    [self.stack addArrangedSubview:icon];
    self.statusLabel = [self label:@"Preparing…" size:15 weight:UIFontWeightMedium color:nil];
    [self.stack addArrangedSubview:self.statusLabel];
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.progressTintColor = DVPurple;
    self.progressView.hidden = YES;
    [self.stack addArrangedSubview:self.progressView];
    [self.stack addArrangedSubview:[self label:@"Keep Twitch open until it finishes" size:13 weight:UIFontWeightRegular color:DVDim(0.5)]];
    [self.stack addArrangedSubview:[self spacer:10]];
    [self.stack addArrangedSubview:[self button:live ? @"Stop & save" : @"Cancel" primary:NO action:@selector(stopTask)]];
}

- (void)stopTask {
    self.statusLabel.text = @"Stopping…";
    [self.task cancel];
}

- (void)showDone:(NSURL *)file {
    self.resultFile = file;
    [self reset];
    NSNumber *size = nil;
    [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    [self.stack addArrangedSubview:[self spacer:30]];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
    icon.tintColor = UIColor.systemGreenColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon.heightAnchor constraintEqualToConstant:50].active = YES;
    [self.stack addArrangedSubview:icon];
    [self.stack addArrangedSubview:[self label:@"Done!" size:20 weight:UIFontWeightBold color:nil]];
    NSString *info = [NSString stringWithFormat:@"%@\n%@", file.lastPathComponent,
                      [NSByteCountFormatter stringFromByteCount:size.longLongValue countStyle:NSByteCountFormatterCountStyleFile]];
    [self.stack addArrangedSubview:[self label:info size:13 weight:UIFontWeightRegular color:DVDim(0.6)]];
    [self.stack addArrangedSubview:[self spacer:10]];
    [self.stack addArrangedSubview:[self button:@"Save / Share" primary:YES action:@selector(shareResult:)]];
    [self.stack addArrangedSubview:[self button:@"Close" primary:NO action:@selector(close)]];
    [self.stack addArrangedSubview:[self label:@"Also saved in Files › On My iPhone › Twitch › Dvnloader"
                                          size:12 weight:UIFontWeightRegular color:DVDim(0.45)]];
}

- (void)shareResult:(UIButton *)sender {
    if (!self.resultFile) return;
    UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:@[self.resultFile] applicationActivities:nil];
    a.popoverPresentationController.sourceView = sender;
    a.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:a animated:YES completion:nil];
}

@end

#import "DVSheetController.h"
#import "DVTwitch.h"
#import "DVDownloadTask.h"
#import "DVRangeSlider.h"

#define DVPurple [UIColor colorWithRed:0x91/255.0 green:0x47/255.0 blue:0xFF/255.0 alpha:1]
#define DVBackground [UIColor colorWithRed:0x18/255.0 green:0x18/255.0 blue:0x1B/255.0 alpha:1]
#define DVCard [UIColor colorWithRed:0x26/255.0 green:0x26/255.0 blue:0x2C/255.0 alpha:1]

static __weak DVSheetController *gCurrent;

@interface DVSheetController () <UIPickerViewDataSource, UIPickerViewDelegate, UITextFieldDelegate>
@property (nonatomic, copy) NSString *link;
@property (nonatomic) DVKind kind;
@property (nonatomic, copy) NSString *ident;

@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UIButton *closeButton;
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

+ (void)presentWithLink:(NSString *)link {
    if (gCurrent) return;
    DVSheetController *c = [DVSheetController new];
    c.link = link;
    c.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        c.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
        c.sheetPresentationController.prefersGrabberVisible = YES;
    }
    gCurrent = c;
    [[self topViewController] presentViewController:c animated:YES completion:nil];
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
    [b setTitleColor:[UIColor colorWithWhite:1 alpha:0.4] forState:UIControlStateDisabled];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    b.backgroundColor = primary ? DVPurple : DVCard;
    b.layer.cornerRadius = 12;
    [b.heightAnchor constraintEqualToConstant:50].active = YES;
    if (action) [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UILabel *)orLabel {
    return [self label:@"أو" size:15 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:1 alpha:0.45]];
}

- (UIView *)spacer:(CGFloat)h {
    UIView *v = [UIView new];
    [v.heightAnchor constraintEqualToConstant:h].active = YES;
    return v;
}

- (void)reset {
    for (UIView *v in self.stack.arrangedSubviews) {
        [self.stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = DVBackground;

    UILabel *title = [self label:@"Dvnloader" size:18 weight:UIFontWeightBold color:nil];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    self.closeButton.tintColor = UIColor.whiteColor;
    self.closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.closeButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.closeButton];

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
        [self.closeButton.leftAnchor constraintEqualToAnchor:g.leftAnchor constant:16],
        [self.closeButton.widthAnchor constraintEqualToConstant:44],
        [self.closeButton.heightAnchor constraintEqualToConstant:44],
        [self.stack.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:28],
        [self.stack.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:24],
        [self.stack.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-24],
    ]];

    DVKind kind;
    NSString *ident = nil;
    if ([DVTwitch parseLink:self.link kind:&kind ident:&ident]) {
        self.kind = kind;
        self.ident = ident;
        [self load];
    } else {
        [self showInput:nil];
    }
}

- (void)close {
    [self.task cancel];
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Link input

- (void)showInput:(NSString *)error {
    [self reset];
    [self.stack addArrangedSubview:[self label:@"حط رابط القناة أو رابط البث القديم" size:16 weight:UIFontWeightSemibold color:nil]];

    self.field = [UITextField new];
    self.field.placeholder = @"twitch.tv/... أو اسم القناة";
    self.field.textColor = UIColor.whiteColor;
    self.field.backgroundColor = DVCard;
    self.field.layer.cornerRadius = 12;
    self.field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.field.autocorrectionType = UITextAutocorrectionTypeNo;
    self.field.keyboardType = UIKeyboardTypeURL;
    self.field.returnKeyType = UIReturnKeyGo;
    self.field.textAlignment = NSTextAlignmentLeft;
    self.field.delegate = self;
    self.field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 1)];
    self.field.leftViewMode = UITextFieldViewModeAlways;
    [self.field.heightAnchor constraintEqualToConstant:50].active = YES;
    [self.stack addArrangedSubview:self.field];

    if (error) [self.stack addArrangedSubview:[self label:error size:14 weight:UIFontWeightRegular color:UIColor.systemRedColor]];
    [self.stack addArrangedSubview:[self button:@"لصق من الحافظة" primary:NO action:@selector(paste)]];
    [self.stack addArrangedSubview:[self button:@"كمّل" primary:YES action:@selector(submitLink)]];
    [self.stack addArrangedSubview:[self label:@"💡 أسهل طريقة: اضغط زر المشاركة على البث واختار Dvnloader"
                                          size:13 weight:UIFontWeightRegular color:[UIColor colorWithWhite:1 alpha:0.5]]];
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
        [self showInput:@"الرابط مو واضح، جرّب رابط قناة أو رابط بث قديم"];
        return;
    }
    self.kind = kind;
    self.ident = ident;
    [self load];
}

#pragma mark - Loading

- (void)showLoading:(NSString *)text {
    [self reset];
    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spin.color = UIColor.whiteColor;
    [spin startAnimating];
    [self.stack addArrangedSubview:[self spacer:40]];
    [self.stack addArrangedSubview:spin];
    [self.stack addArrangedSubview:[self label:text size:15 weight:UIFontWeightRegular color:[UIColor colorWithWhite:1 alpha:0.7]]];
}

- (void)showError:(NSString *)msg {
    [self reset];
    [self.stack addArrangedSubview:[self spacer:30]];
    [self.stack addArrangedSubview:[self label:@"⚠️" size:44 weight:UIFontWeightRegular color:nil]];
    [self.stack addArrangedSubview:[self label:msg size:16 weight:UIFontWeightSemibold color:nil]];
    [self.stack addArrangedSubview:[self spacer:10]];
    [self.stack addArrangedSubview:[self button:@"جرّب مرة ثانية" primary:YES action:@selector(load)]];
    [self.stack addArrangedSubview:[self button:@"رابط ثاني" primary:NO action:@selector(backToInput)]];
}

- (void)backToInput {
    [self showInput:nil];
}

- (void)load {
    [self showLoading:self.kind == DVKindLive ? @"يجيب البث المباشر…" : @"يجيب البث القديم…"];
    __weak typeof(self) ws = self;
    [DVTwitch fetchVariantsForKind:self.kind ident:self.ident completion:^(NSArray<DVVariant *> *variants, NSError *err) {
        if (!ws) return;
        if (!variants) return [ws showError:err.localizedDescription ?: @"صار خطأ"];
        ws.variants = variants;
        ws.selected = variants.firstObject;
        if (ws.kind == DVKindLive) return [ws showLive];
        [DVTwitch fetchMediaPlaylist:ws.selected.url completion:^(DVMediaPlaylist *pl, NSError *e2) {
            if (!ws) return;
            if (!pl) return [ws showError:e2.localizedDescription ?: @"صار خطأ"];
            ws.vodDuration = pl.total;
            [ws showVOD];
        }];
    }];
}

#pragma mark - Quality

- (UIButton *)makeQualityButton {
    UIButton *b = [self button:@"" primary:NO action:NULL];
    b.showsMenuAsPrimaryAction = YES;
    self.qualityButton = b;
    [self refreshQualityMenu];
    return b;
}

- (void)refreshQualityMenu {
    [self.qualityButton setTitle:[NSString stringWithFormat:@"الجودة: %@  ▾", self.selected.name] forState:UIControlStateNormal];
    NSMutableArray *actions = [NSMutableArray array];
    __weak typeof(self) ws = self;
    for (DVVariant *v in self.variants) {
        UIAction *a = [UIAction actionWithTitle:v.name image:nil identifier:nil handler:^(__kindof UIAction *action) {
            ws.selected = v;
            [ws refreshQualityMenu];
        }];
        a.state = v == self.selected ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:a];
    }
    self.qualityButton.menu = [UIMenu menuWithTitle:@"اختار الجودة" children:actions];
}

#pragma mark - Live

- (void)showLive {
    [self reset];
    [self.stack addArrangedSubview:[self label:[NSString stringWithFormat:@"🔴 لايف الحين • %@", self.ident]
                                          size:15 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:1 alpha:0.85]]];
    [self.stack addArrangedSubview:[self makeQualityButton]];
    [self.stack addArrangedSubview:[self spacer:6]];
    [self.stack addArrangedSubview:[self label:@"حدد مدة التسجيل" size:16 weight:UIFontWeightSemibold color:nil]];

    self.picker = [UIPickerView new];
    self.picker.dataSource = self;
    self.picker.delegate = self;
    self.picker.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    [self.picker.heightAnchor constraintEqualToConstant:160].active = YES;
    [self.picker selectRow:30 inComponent:1 animated:NO];
    [self.stack addArrangedSubview:self.picker];

    [self.stack addArrangedSubview:[self button:@"سجّل المدة المحددة" primary:YES action:@selector(recordTimed)]];
    [self.stack addArrangedSubview:[self orLabel]];
    [self.stack addArrangedSubview:[self button:@"سجّل لين ما يخلص البث" primary:YES action:@selector(recordUntilEnd)]];
}

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView { return 2; }

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return component == 0 ? 24 : 60;
}

- (NSAttributedString *)pickerView:(UIPickerView *)pickerView attributedTitleForRow:(NSInteger)row forComponent:(NSInteger)component {
    NSString *s = [NSString stringWithFormat:@"%ld %@", (long)row, component == 0 ? @"ساعة" : @"دقيقة"];
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

#pragma mark - VOD

- (void)showVOD {
    [self reset];
    [self.stack addArrangedSubview:[self label:[NSString stringWithFormat:@"بث قديم • المدة %@", DVFormatTime(self.vodDuration)]
                                          size:15 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:1 alpha:0.85]]];
    [self.stack addArrangedSubview:[self makeQualityButton]];
    [self.stack addArrangedSubview:[self spacer:6]];
    [self.stack addArrangedSubview:[self label:@"حدد الجزء اللي تبي تنزّله" size:16 weight:UIFontWeightSemibold color:nil]];

    self.fromLabel = [self label:@"" size:13 weight:UIFontWeightMedium color:[UIColor colorWithWhite:1 alpha:0.75]];
    self.toLabel = [self label:@"" size:13 weight:UIFontWeightMedium color:[UIColor colorWithWhite:1 alpha:0.75]];
    self.fromLabel.textAlignment = NSTextAlignmentLeft;
    self.toLabel.textAlignment = NSTextAlignmentRight;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[self.fromLabel, self.toLabel]];
    row.distribution = UIStackViewDistributionFillEqually;
    row.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    [self.stack addArrangedSubview:row];

    self.slider = [DVRangeSlider new];
    self.slider.maximumValue = self.vodDuration;
    self.slider.lowerValue = 0;
    self.slider.upperValue = self.vodDuration;
    [self.slider addTarget:self action:@selector(rangeChanged) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:self.slider];

    self.rangeLabel = [self label:@"" size:13 weight:UIFontWeightRegular color:[UIColor colorWithWhite:1 alpha:0.5]];
    [self.stack addArrangedSubview:self.rangeLabel];
    [self rangeChanged];

    [self.stack addArrangedSubview:[self button:@"نزّل الجزء المحدد" primary:YES action:@selector(downloadRange)]];
    [self.stack addArrangedSubview:[self orLabel]];
    [self.stack addArrangedSubview:[self button:@"نزّل البث كامل" primary:YES action:@selector(downloadFull)]];
}

- (void)rangeChanged {
    self.fromLabel.text = DVFormatTime(self.slider.lowerValue);
    self.toLabel.text = DVFormatTime(self.slider.upperValue);
    self.rangeLabel.text = [NSString stringWithFormat:@"طول الجزء: %@", DVFormatTime(self.slider.upperValue - self.slider.lowerValue)];
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
        else [ws showError:error.localizedDescription ?: @"صار خطأ"];
    };
    self.task = t;
    return t;
}

- (void)showProgress:(BOOL)live {
    [self reset];
    self.modalInPresentation = YES;
    self.closeButton.hidden = YES;
    [self.stack addArrangedSubview:[self spacer:30]];
    [self.stack addArrangedSubview:[self label:live ? @"🔴" : @"⬇️" size:44 weight:UIFontWeightRegular color:nil]];
    self.statusLabel = [self label:@"يجهّز…" size:15 weight:UIFontWeightMedium color:nil];
    [self.stack addArrangedSubview:self.statusLabel];
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.progressTintColor = DVPurple;
    self.progressView.hidden = YES;
    [self.stack addArrangedSubview:self.progressView];
    [self.stack addArrangedSubview:[self label:@"خل التطبيق مفتوح لين يخلص" size:13 weight:UIFontWeightRegular color:[UIColor colorWithWhite:1 alpha:0.5]]];
    [self.stack addArrangedSubview:[self spacer:10]];
    [self.stack addArrangedSubview:[self button:live ? @"وقّف واحفظ اللي تسجّل" : @"إلغاء" primary:NO action:@selector(stopTask)]];
}

- (void)stopTask {
    self.statusLabel.text = @"يوقّف…";
    [self.task cancel];
}

- (void)showDone:(NSURL *)file {
    self.resultFile = file;
    [self reset];
    NSNumber *size = nil;
    [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    [self.stack addArrangedSubview:[self spacer:30]];
    [self.stack addArrangedSubview:[self label:@"✅" size:44 weight:UIFontWeightRegular color:nil]];
    [self.stack addArrangedSubview:[self label:@"خلص!" size:20 weight:UIFontWeightBold color:nil]];
    NSString *info = [NSString stringWithFormat:@"%@\n%@", file.lastPathComponent,
                      [NSByteCountFormatter stringFromByteCount:size.longLongValue countStyle:NSByteCountFormatterCountStyleFile]];
    [self.stack addArrangedSubview:[self label:info size:13 weight:UIFontWeightRegular color:[UIColor colorWithWhite:1 alpha:0.6]]];
    [self.stack addArrangedSubview:[self spacer:10]];
    [self.stack addArrangedSubview:[self button:@"احفظ / شارك" primary:YES action:@selector(shareResult:)]];
    [self.stack addArrangedSubview:[self button:@"تم" primary:NO action:@selector(close)]];
    [self.stack addArrangedSubview:[self label:@"الملف موجود بعد في تطبيق الملفات ← على الآيفون ← Twitch ← Dvnloader"
                                          size:12 weight:UIFontWeightRegular color:[UIColor colorWithWhite:1 alpha:0.45]]];
}

- (void)shareResult:(UIButton *)sender {
    if (!self.resultFile) return;
    UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:@[self.resultFile] applicationActivities:nil];
    a.popoverPresentationController.sourceView = sender;
    a.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:a animated:YES completion:nil];
}

@end

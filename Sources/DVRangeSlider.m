#import "DVRangeSlider.h"

static const CGFloat kThumb = 28;

@implementation DVRangeSlider {
    UIView *_track, *_fill, *_lower, *_upper;
    NSInteger _active; // 0 lower, 1 upper
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _maximumValue = 1;
        _upperValue = 1;
        _fillColor = [UIColor colorWithRed:0.57 green:0.28 blue:1 alpha:1];
        self.semanticContentAttribute =UISemanticContentAttributeForceLeftToRight;
        _track = [UIView new];
        _track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
        _track.layer.cornerRadius = 2;
        _track.userInteractionEnabled = NO;
        _fill = [UIView new];
        _fill.layer.cornerRadius = 2;
        _fill.userInteractionEnabled = NO;
        [self addSubview:_track];
        [self addSubview:_fill];
        _lower = [self makeThumb];
        _upper = [self makeThumb];
    }
    return self;
}

- (UIView *)makeThumb {
    UIView *t = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kThumb, kThumb)];
    t.backgroundColor = UIColor.whiteColor;
    t.layer.cornerRadius = kThumb / 2;
    t.layer.shadowColor = UIColor.blackColor.CGColor;
    t.layer.shadowOpacity = 0.3;
    t.layer.shadowRadius = 3;
    t.layer.shadowOffset = CGSizeMake(0, 1);
    t.userInteractionEnabled = NO;
    [self addSubview:t];
    return t;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, 44);
}

- (CGFloat)xFor:(double)v {
    CGFloat pad = kThumb / 2, w = self.bounds.size.width - kThumb;
    return pad + (self.maximumValue > 0 ? (CGFloat)(v / self.maximumValue) : 0) * w;
}

- (double)valueFor:(CGFloat)x {
    CGFloat pad = kThumb / 2, w = MAX(1, self.bounds.size.width - kThumb);
    double v = (x - pad) / w * self.maximumValue;
    return MIN(self.maximumValue, MAX(0, v));
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat midY = self.bounds.size.height / 2;
    CGFloat lx = [self xFor:self.lowerValue], ux = [self xFor:self.upperValue];
    _track.frame = CGRectMake(kThumb / 2, midY - 2, self.bounds.size.width - kThumb, 4);
    _fill.backgroundColor = self.fillColor;
    _fill.frame = CGRectMake(lx, midY - 2, MAX(0, ux - lx), 4);
    _lower.center = CGPointMake(lx, midY);
    _upper.center = CGPointMake(ux, midY);
}

- (void)setMaximumValue:(double)m { _maximumValue = MAX(m, 0.001); [self setNeedsLayout]; }
- (void)setLowerValue:(double)v  { _lowerValue = v; [self setNeedsLayout]; }
- (void)setUpperValue:(double)v  { _upperValue = v; [self setNeedsLayout]; }

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    CGFloat x = [touch locationInView:self].x;
    CGFloat dl = fabs(x - [self xFor:self.lowerValue]), du = fabs(x - [self xFor:self.upperValue]);
    if (dl == du) _active = x < [self xFor:self.lowerValue] ? 0 : 1;
    else _active = dl < du ? 0 : 1;
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    double v = [self valueFor:[touch locationInView:self].x];
    if (_active == 0) self.lowerValue = MIN(v, self.upperValue);
    else self.upperValue = MAX(v, self.lowerValue);
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    return YES;
}

@end

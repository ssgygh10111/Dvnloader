#import <UIKit/UIKit.h>

// Two-thumb slider. Sends UIControlEventValueChanged while dragging.
@interface DVRangeSlider : UIControl
@property (nonatomic) double maximumValue;
@property (nonatomic) double lowerValue;
@property (nonatomic) double upperValue;
@property (nonatomic, strong) UIColor *fillColor;
@end

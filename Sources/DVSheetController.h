#import <UIKit/UIKit.h>

@interface DVSheetController : UIViewController
// link may be nil: the sheet then asks for a channel / VOD link.
+ (void)presentWithLink:(NSString *)link;
+ (UIViewController *)topViewController;
@end

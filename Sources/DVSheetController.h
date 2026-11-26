#import <UIKit/UIKit.h>
#import "DVTwitch.h"

@interface DVSheetController : UIViewController
// Opens straight on a known live channel / past broadcast.
+ (void)presentWithKind:(DVKind)kind ident:(NSString *)ident;
// link may be nil: the sheet then asks for a channel / VOD link.
+ (void)presentWithLink:(NSString *)link;
+ (UIViewController *)topViewController;
+ (BOOL)isShowing;
@end

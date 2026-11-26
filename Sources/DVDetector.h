#import <Foundation/Foundation.h>
#import "DVTwitch.h"

// Watches the Twitch app's own network traffic to know which live channel / past
// broadcast is currently playing, so the user never has to copy a link.
@interface DVDetector : NSObject
+ (void)install;
+ (BOOL)current:(DVKind *)kind ident:(NSString **)ident;
@end

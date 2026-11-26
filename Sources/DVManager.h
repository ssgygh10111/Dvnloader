#import <UIKit/UIKit.h>

// Runs one download/recording at a time in the background and shows a small
// progress bar at the bottom of the screen, so you can keep watching.
@interface DVManager : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL busy;
- (void)startLive:(NSURL *)url ident:(NSString *)ident quality:(NSString *)quality maxDuration:(double)secs fileName:(NSString *)name;
- (void)startVOD:(NSURL *)url from:(double)start to:(double)end fileName:(NSString *)name;
- (void)stop;
@end

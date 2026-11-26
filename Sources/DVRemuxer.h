#import <Foundation/Foundation.h>

// Rewraps an MPEG-TS file (H.264 + AAC, as Twitch sends it) into a normal MP4
// without re-encoding, so Photos / WhatsApp accept it.
@interface DVRemuxer : NSObject
+ (BOOL)remuxTS:(NSURL *)src to:(NSURL *)dst error:(NSError **)error;
@end

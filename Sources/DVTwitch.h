#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, DVKind) {
    DVKindLive = 0,
    DVKindVOD  = 1,
};

@interface DVVariant : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSURL *url;
@end

@interface DVSegment : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) NSString *title;
@property (nonatomic) double duration;
@property (nonatomic) double start;
@property (nonatomic) NSInteger seq;
@end

@interface DVMediaPlaylist : NSObject
@property (nonatomic, strong) NSArray<DVSegment *> *segments;
@property (nonatomic) BOOL ended;
@property (nonatomic) double total;
@property (nonatomic, strong) NSURL *mapURL; // fMP4 init segment (EXT-X-MAP)
+ (instancetype)parse:(NSString *)text base:(NSURL *)base;
@end

@interface DVTwitch : NSObject
// Parses a twitch link (channel or /videos/ID). Returns NO if not recognised.
+ (BOOL)parseLink:(NSString *)link kind:(DVKind *)kind ident:(NSString **)ident;
// Finds the first twitch link inside arbitrary text.
+ (NSString *)findLinkInString:(NSString *)s;

// Blocking network helpers — call off the main thread only.
+ (NSData *)fetch:(NSURLRequest *)req error:(NSError **)err;
+ (NSArray<DVVariant *> *)variantsSyncForKind:(DVKind)kind ident:(NSString *)ident error:(NSError **)err;
+ (DVMediaPlaylist *)mediaPlaylistSync:(NSURL *)url error:(NSError **)err;

// Async wrappers — completion on main thread.
+ (void)fetchVariantsForKind:(DVKind)kind ident:(NSString *)ident
                  completion:(void (^)(NSArray<DVVariant *> *variants, NSError *err))completion;
+ (void)fetchMediaPlaylist:(NSURL *)url completion:(void (^)(DVMediaPlaylist *pl, NSError *err))completion;
@end

NSString *DVFormatTime(double seconds);
NSError *DVError(NSString *message);

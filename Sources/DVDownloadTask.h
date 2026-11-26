#import <Foundation/Foundation.h>

@interface DVDownloadTask : NSObject

// Both called on the main thread.
@property (nonatomic, copy) void (^onProgress)(NSString *status, double fraction); // fraction < 0 = indeterminate
@property (nonatomic, copy) void (^onFinish)(NSURL *file, NSError *error);

// Called on a background thread when a live playlist stops answering;
// return a fresh media-playlist URL for the same quality, or nil if the stream is offline.
@property (nonatomic, copy) NSURL *(^refreshLiveURL)(void);

- (void)startVOD:(NSURL *)mediaURL from:(double)start to:(double)end fileName:(NSString *)name;
- (void)startLive:(NSURL *)mediaURL maxDuration:(double)seconds fileName:(NSString *)name; // seconds <= 0: until stream ends

// Set before startLive so the task can re-request the stream (token expiry, ad-free player types).
@property (nonatomic, copy) NSString *liveIdent;
@property (nonatomic, copy) NSString *liveQuality;
- (void)cancel;

+ (NSURL *)outputDirectory;

// Live stats for the progress bar (read from the main thread).
@property (atomic, readonly) unsigned long long bytesWritten;
@property (atomic, readonly) double recordedSeconds;
@property (atomic, readonly) double maxDuration;     // live: 0 = until end
@property (atomic, readonly) BOOL live;
@property (atomic, readonly) NSInteger segmentsDone;
@property (atomic, readonly) NSInteger segmentsTotal;
@property (atomic, readonly, copy) NSString *note;   // "Skipping ads…", "Converting…"

@end

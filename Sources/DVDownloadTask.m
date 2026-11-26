#import <UIKit/UIKit.h>
#import "DVDownloadTask.h"
#import "DVTwitch.h"

static const NSInteger kParallel = 6;

@interface DVDownloadTask ()
@property (atomic) BOOL cancelled;
@property (nonatomic, strong) NSFileHandle *handle;
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic) unsigned long long bytes;
@end

@implementation DVDownloadTask

+ (NSURL *)outputDirectory {
    NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [docs URLByAppendingPathComponent:@"Dvnloader" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (void)cancel {
    self.cancelled = YES;
}

#pragma mark - Helpers

- (void)progress:(NSString *)status fraction:(double)f {
    void (^cb)(NSString *, double) = self.onProgress;
    if (!cb) return;
    dispatch_async(dispatch_get_main_queue(), ^{ cb(status, f); });
}

- (void)finish:(NSError *)error {
    [self.handle closeFile];
    self.handle = nil;
    NSURL *file = self.fileURL;
    if (error || self.bytes == 0) {
        [NSFileManager.defaultManager removeItemAtURL:file error:nil];
        file = nil;
        if (!error) error = DVError(self.cancelled ? @"انلغى" : @"ما انحفظ شي");
    }
    void (^cb)(NSURL *, NSError *) = self.onFinish;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication setIdleTimerDisabled:NO];
        if (cb) cb(file, error);
    });
}

- (BOOL)openFile:(NSString *)name extension:(NSString *)ext {
    NSURL *url = [[DVDownloadTask outputDirectory] URLByAppendingPathComponent:[name stringByAppendingPathExtension:ext]];
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    if (![NSFileManager.defaultManager createFileAtPath:url.path contents:nil attributes:nil]) return NO;
    self.fileURL = url;
    self.handle = [NSFileHandle fileHandleForWritingAtPath:url.path];
    self.bytes = 0;
    return self.handle != nil;
}

- (void)write:(NSData *)data {
    [self.handle writeData:data];
    self.bytes += data.length;
}

- (NSData *)get:(NSURL *)url {
    for (int attempt = 0; attempt < 3 && !self.cancelled; attempt++) {
        NSError *e = nil;
        NSData *d = [DVTwitch fetch:[NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30] error:&e];
        if (d) return d;
        if (e.code == 403 || e.code == 404) return nil; // not worth retrying
        [NSThread sleepForTimeInterval:0.6 * (attempt + 1)];
    }
    return nil;
}

// Twitch marks muted VOD parts as "-unmuted.ts"; those 403, the "-muted.ts" copy works.
- (NSData *)getSegment:(DVSegment *)seg {
    NSData *d = [self get:seg.url];
    if (!d && [seg.url.absoluteString containsString:@"-unmuted"]) {
        NSURL *alt = [NSURL URLWithString:[seg.url.absoluteString stringByReplacingOccurrencesOfString:@"-unmuted" withString:@"-muted"]];
        d = [self get:alt];
    }
    return d;
}

static NSString *DVSize(unsigned long long b) {
    return [NSByteCountFormatter stringFromByteCount:(long long)b countStyle:NSByteCountFormatterCountStyleFile];
}

#pragma mark - VOD

- (void)startVOD:(NSURL *)mediaURL from:(double)start to:(double)end fileName:(NSString *)name {
    [UIApplication.sharedApplication setIdleTimerDisabled:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self runVOD:mediaURL from:start to:end name:name];
    });
}

- (void)runVOD:(NSURL *)mediaURL from:(double)start to:(double)end name:(NSString *)name {
    [self progress:@"يجهّز…" fraction:-1];
    NSError *e = nil;
    DVMediaPlaylist *pl = [DVTwitch mediaPlaylistSync:mediaURL error:&e];
    if (!pl) return [self finish:e];
    if (end <= 0 || end > pl.total) end = pl.total;

    NSMutableArray<DVSegment *> *segs = [NSMutableArray array];
    for (DVSegment *s in pl.segments) {
        if (s.start + s.duration > start && s.start < end) [segs addObject:s];
    }
    if (!segs.count) return [self finish:DVError(@"المدة المختارة فاضية")];
    if (![self openFile:name extension:pl.mapURL ? @"mp4" : @"ts"]) return [self finish:DVError(@"ما قدرت أسوي الملف")];

    if (pl.mapURL) {
        NSData *init = [self get:pl.mapURL];
        if (!init) return [self finish:DVError(@"فشل تحميل بداية الفيديو")];
        [self write:init];
    }

    NSInteger n = segs.count;
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    for (NSInteger i = 0; i < n; i += kParallel) {
        if (self.cancelled) return [self finish:DVError(@"انلغى")];
        NSInteger count = MIN(kParallel, n - i);
        NSMutableArray *results = [NSMutableArray arrayWithCapacity:count];
        for (NSInteger j = 0; j < count; j++) [results addObject:NSNull.null];
        dispatch_group_t g = dispatch_group_create();
        for (NSInteger j = 0; j < count; j++) {
            DVSegment *seg = segs[i + j];
            dispatch_group_async(g, q, ^{
                NSData *d = [self getSegment:seg];
                @synchronized (results) { results[j] = d ?: NSNull.null; }
            });
        }
        dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
        for (id d in results) {
            if (d == NSNull.null) {
                if (self.cancelled) return [self finish:DVError(@"انلغى")];
                return [self finish:DVError(@"انقطع التحميل، جرّب مرة ثانية")];
            }
            [self write:d];
        }
        NSInteger done = i + count;
        [self progress:[NSString stringWithFormat:@"ينزّل… %ld / %ld  •  %@", (long)done, (long)n, DVSize(self.bytes)]
              fraction:(double)done / n];
    }
    [self finish:nil];
}

#pragma mark - Live

- (void)startLive:(NSURL *)mediaURL maxDuration:(double)seconds fileName:(NSString *)name {
    [UIApplication.sharedApplication setIdleTimerDisabled:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self runLive:mediaURL max:seconds name:name];
    });
}

- (void)runLive:(NSURL *)url max:(double)maxDur name:(NSString *)name {
    [self progress:@"يبدأ التسجيل…" fraction:-1];
    NSInteger lastSeq = -1;
    double recorded = 0;
    int fails = 0;
    BOOL opened = NO, wroteMap = NO;

    while (!self.cancelled) {
        NSError *e = nil;
        DVMediaPlaylist *pl = [DVTwitch mediaPlaylistSync:url error:&e];
        if (!pl) {
            fails++;
            if (fails % 3 == 0 && self.refreshLiveURL) {
                NSURL *fresh = self.refreshLiveURL();
                if (!fresh) break; // stream went offline
                url = fresh;
            }
            if (fails >= 9) break;
            [NSThread sleepForTimeInterval:2];
            continue;
        }
        fails = 0;

        if (!opened) {
            if (![self openFile:name extension:pl.mapURL ? @"mp4" : @"ts"]) return [self finish:DVError(@"ما قدرت أسوي الملف")];
            opened = YES;
        }
        if (pl.mapURL && !wroteMap) {
            NSData *init = [self get:pl.mapURL];
            if (init) { [self write:init]; wroteMap = YES; }
        }

        for (DVSegment *s in pl.segments) {
            if (self.cancelled) break;
            if (s.seq <= lastSeq) continue;
            lastSeq = s.seq;
            // Real stream parts are titled "live"; anything else is a stitched ad.
            if (s.title.length && ![s.title.lowercaseString containsString:@"live"]) continue;
            NSData *d = [self getSegment:s];
            if (!d) continue;
            [self write:d];
            recorded += s.duration;
            if (maxDur > 0 && recorded >= maxDur) break;
        }

        if (maxDur > 0) {
            [self progress:[NSString stringWithFormat:@"يسجّل… %@ من %@  •  %@", DVFormatTime(recorded), DVFormatTime(maxDur), DVSize(self.bytes)]
                  fraction:MIN(1.0, recorded / maxDur)];
            if (recorded >= maxDur) break;
        } else {
            [self progress:[NSString stringWithFormat:@"يسجّل لين ما يخلص البث… %@  •  %@", DVFormatTime(recorded), DVSize(self.bytes)]
                  fraction:-1];
        }
        if (pl.ended) break;
        [NSThread sleepForTimeInterval:1.5];
    }

    if (!opened) return [self finish:DVError(@"ما قدرت أوصل للبث")];
    [self finish:nil]; // cancelling a live recording keeps what was recorded
}

@end

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "DVDownloadTask.h"
#import "DVTwitch.h"
#import "DVRemuxer.h"

static const NSInteger kParallel = 6;

@interface DVDownloadTask ()
@property (atomic) BOOL cancelled;
@property (nonatomic, strong) NSFileHandle *handle;
@property (nonatomic, strong) NSURL *fileURL;
@property (atomic) unsigned long long bytes;
@property (atomic, readwrite) double recordedSeconds;
@property (atomic, readwrite) double maxDuration;
@property (atomic, readwrite) BOOL live;
@property (atomic, readwrite) NSInteger segmentsDone;
@property (atomic, readwrite) NSInteger segmentsTotal;
@property (atomic, readwrite, copy) NSString *note;
@end

@implementation DVDownloadTask

+ (NSURL *)outputDirectory {
    NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [docs URLByAppendingPathComponent:@"Dvnloader" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (unsigned long long)bytesWritten { return self.bytes; }

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
        if (!error) error = DVError(self.cancelled ? @"Cancelled" : @"Nothing was saved");
    }
    if (file) {
        self.note = @"Converting…";
        [self progress:@"Converting…" fraction:-1];
        if ([file.pathExtension isEqualToString:@"mp4"]) {
            file = [self remux:file];
        } else if ([file.pathExtension isEqualToString:@"ts"]) {
            NSURL *mp4 = [[file URLByDeletingPathExtension] URLByAppendingPathExtension:@"mp4"];
            if ([DVRemuxer remuxTS:file to:mp4 error:nil]) {
                [NSFileManager.defaultManager removeItemAtURL:file error:nil];
                file = mp4;
            }
        }
    }
    void (^cb)(NSURL *, NSError *) = self.onFinish;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication setIdleTimerDisabled:NO];
        if (cb) cb(file, error);
    });
}

// Twitch sends fragmented MP4; rewrite it as a regular MP4 so Photos / WhatsApp accept it.
- (NSURL *)remux:(NSURL *)src {
    [self progress:@"Finishing…" fraction:-1];
    NSURL *tmp = [[src URLByDeletingPathExtension] URLByAppendingPathExtension:@"tmp.mp4"];
    [NSFileManager.defaultManager removeItemAtURL:tmp error:nil];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:src options:nil];
    AVAssetExportSession *ex = [AVAssetExportSession exportSessionWithAsset:asset presetName:AVAssetExportPresetPassthrough];
    if (!ex || ![ex.supportedFileTypes containsObject:AVFileTypeMPEG4]) return src;
    ex.outputURL = tmp;
    ex.outputFileType = AVFileTypeMPEG4;
    ex.shouldOptimizeForNetworkUse = YES;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [ex exportAsynchronouslyWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (ex.status != AVAssetExportSessionStatusCompleted) {
        [NSFileManager.defaultManager removeItemAtURL:tmp error:nil];
        return src;
    }
    [NSFileManager.defaultManager removeItemAtURL:src error:nil];
    [NSFileManager.defaultManager moveItemAtURL:tmp toURL:src error:nil];
    return src;
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
    [self progress:@"Preparing…" fraction:-1];
    NSError *e = nil;
    DVMediaPlaylist *pl = [DVTwitch mediaPlaylistSync:mediaURL error:&e];
    if (!pl) return [self finish:e];
    if (end <= 0 || end > pl.total) end = pl.total;

    NSMutableArray<DVSegment *> *segs = [NSMutableArray array];
    for (DVSegment *s in pl.segments) {
        if (s.start + s.duration > start && s.start < end) [segs addObject:s];
    }
    if (!segs.count) return [self finish:DVError(@"Selected range is empty")];
    if (![self openFile:name extension:pl.mapURL ? @"mp4" : @"ts"]) return [self finish:DVError(@"Couldn't create file")];

    if (pl.mapURL) {
        NSData *init = [self get:pl.mapURL];
        if (!init) return [self finish:DVError(@"Failed to load video header")];
        [self write:init];
    }

    NSInteger n = segs.count;
    self.segmentsTotal = n;
    self.segmentsDone = 0;
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    for (NSInteger i = 0; i < n; i += kParallel) {
        if (self.cancelled) return [self finish:DVError(@"Cancelled")];
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
                if (self.cancelled) return [self finish:DVError(@"Cancelled")];
                return [self finish:DVError(@"Download interrupted, try again")];
            }
            [self write:d];
        }
        NSInteger done = i + count;
        self.segmentsDone = done;
        [self progress:[NSString stringWithFormat:@"Downloading… %ld / %ld  •  %@", (long)done, (long)n, DVSize(self.bytes)]
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

// Twitch stitches ads into new viewing sessions. Other player types often get the clean stream.
static NSArray *DVPlayerTypes(void) {
    return @[@"site", @"embed", @"popout", @"autoplay", @"picture-by-picture", @"frontpage"];
}

- (NSURL *)liveURLForPlayerType:(NSString *)pt {
    if (!self.liveIdent) return nil;
    NSArray<DVVariant *> *vs = [DVTwitch variantsSyncForKind:DVKindLive ident:self.liveIdent playerType:pt error:nil];
    for (DVVariant *v in vs) if ([v.name isEqualToString:self.liveQuality]) return v.url;
    return vs.firstObject.url;
}

static BOOL DVIsAd(DVSegment *s) {
    return s.title.length && ![s.title.lowercaseString containsString:@"live"];
}

// Looks for a player type whose playlist currently ends in real stream parts.
- (NSURL *)findAdFreeURL:(NSString **)usedType {
    for (NSString *pt in DVPlayerTypes()) {
        if (self.cancelled) return nil;
        [self progress:[NSString stringWithFormat:@"Skipping ads… (trying %@)", pt] fraction:-1];
        NSURL *u = [self liveURLForPlayerType:pt];
        if (!u) continue;
        DVMediaPlaylist *pl = [DVTwitch mediaPlaylistSync:u error:nil];
        DVSegment *last = pl.segments.lastObject;
        if (last && !DVIsAd(last)) { *usedType = pt; return u; }
    }
    return nil;
}

- (void)runLive:(NSURL *)url max:(double)maxDur name:(NSString *)name {
    self.live = YES;
    self.maxDuration = maxDur;
    [self progress:@"Starting recording…" fraction:-1];
    NSInteger lastSeq = -1;
    double recorded = 0;
    int fails = 0, adPolls = 0, segFails = 0, adsSkipped = 0;
    NSString *lastErr = nil, *playerType = @"site";
    NSMutableSet *triedSwitch = [NSMutableSet set];
    BOOL opened = NO, wroteMap = NO;

    while (!self.cancelled) {
        NSError *e = nil;
        DVMediaPlaylist *pl = [DVTwitch mediaPlaylistSync:url error:&e];
        if (!pl) {
            fails++;
            if (fails % 3 == 0) {
                NSURL *fresh = [self liveURLForPlayerType:playerType];
                if (!fresh) break; // stream went offline
                url = fresh;
            }
            if (fails >= 9) break;
            [NSThread sleepForTimeInterval:2];
            continue;
        }
        fails = 0;

        if (!opened) {
            if (![self openFile:name extension:pl.mapURL ? @"mp4" : @"ts"]) return [self finish:DVError(@"Couldn't create file")];
            opened = YES;
        }
        if (pl.mapURL && !wroteMap) {
            NSData *init = [self get:pl.mapURL];
            if (init) { [self write:init]; wroteMap = YES; }
        }

        BOOL sawAd = NO, sawLive = NO;
        for (DVSegment *s in pl.segments) {
            if (self.cancelled) break;
            if (s.seq <= lastSeq) continue;
            lastSeq = s.seq;
            if (DVIsAd(s)) { sawAd = YES; adsSkipped++; continue; }
            sawLive = YES;
            NSData *d = [self getSegment:s];
            if (!d) { segFails++; lastErr = @"segment download failed"; continue; }
            [self write:d];
            recorded += s.duration;
            self.recordedSeconds = recorded;
            if (maxDur > 0 && recorded >= maxDur) break;
        }

        // Stuck behind ads → hop to a player type that serves the live stream.
        adPolls = (sawAd && !sawLive) ? adPolls + 1 : 0;
        if (adPolls >= 2 && ![triedSwitch containsObject:playerType]) {
            [triedSwitch addObject:playerType];
            NSString *pt = nil;
            NSURL *clean = [self findAdFreeURL:&pt];
            if (clean) {
                url = clean;
                playerType = pt;
                if (recorded == 0) lastSeq = -1;
            }
            adPolls = 0;
            continue;
        }

        NSString *extra = @"";
        self.note = adPolls > 0 ? @"Skipping ads…" : (segFails > 0 && recorded == 0 ? @"Parts failing…" : nil);
        if (adPolls > 0) extra = @"\nSkipping ads…";
        else if (segFails > 0 && recorded == 0) extra = [NSString stringWithFormat:@"\n(%d parts failed: %@)", segFails, lastErr];

        if (maxDur > 0) {
            [self progress:[NSString stringWithFormat:@"Recording… %@ of %@  •  %@%@", DVFormatTime(recorded), DVFormatTime(maxDur), DVSize(self.bytes), extra]
                  fraction:MIN(1.0, recorded / maxDur)];
            if (recorded >= maxDur) break;
        } else {
            [self progress:[NSString stringWithFormat:@"Recording until end… %@  •  %@%@", DVFormatTime(recorded), DVSize(self.bytes), extra]
                  fraction:-1];
        }
        if (pl.ended) break;
        [NSThread sleepForTimeInterval:1.5];
    }

    if (!opened) return [self finish:DVError(@"Couldn't reach the stream")];
    if (recorded == 0) {
        NSString *why = adsSkipped ? @"Only ads were received, nothing from the stream yet. Try again in a minute."
                                   : [NSString stringWithFormat:@"Nothing was recorded (%d parts failed)", segFails];
        return [self finish:DVError(why)];
    }
    [self finish:nil]; // cancelling a live recording keeps what was recorded
}

@end

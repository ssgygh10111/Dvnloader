#import "DVRemuxer.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

static NSError *DVRErr(NSString *m) {
    return [NSError errorWithDomain:@"DVRemuxer" code:1 userInfo:@{NSLocalizedDescriptionKey: m}];
}

static int64_t DVReadTS(const uint8_t *b) {
    return ((int64_t)((b[0] >> 1) & 0x07) << 30) | ((int64_t)b[1] << 22) | ((int64_t)(b[2] >> 1) << 15) |
           ((int64_t)b[3] << 7) | ((int64_t)b[4] >> 1);
}

static const int kAACRates[] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350, 0, 0, 0};

@interface DVRemuxState : NSObject {
@public
    BOOL scanning;
    int pmtPID, videoPID, audioPID;
    BOOL hevc;
    NSMutableData *vPES, *aPES;

    // scan results
    NSData *sps, *pps;
    int aacObj, aacSFI, aacCh;
    int64_t firstPTS;

    // writing
    CMVideoFormatDescriptionRef vFmt;
    CMAudioFormatDescriptionRef aFmt;
    AVAssetWriter *writer;
    AVAssetWriterInput *vIn, *aIn;
    NSMutableArray *vQ, *aQ;
    int64_t offset, lastVDTS, lastAPTS;
    BOOL haveV, haveA;
    NSUInteger vCount, aCount;
}
@end
@implementation DVRemuxState
@end

#pragma mark - Sample buffers

static CMSampleBufferRef DVMakeSample(NSData *data, CMFormatDescriptionRef fmt, CMTime pts, CMTime dts, CMTime dur, BOOL sync) {
    CMBlockBufferRef bb = NULL;
    size_t len = data.length;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, len, kCFAllocatorDefault, NULL, 0, len, 0, &bb) != noErr) return NULL;
    CMBlockBufferReplaceDataBytes(data.bytes, bb, 0, len);
    CMSampleTimingInfo t = {dur, pts, dts};
    CMSampleBufferRef sb = NULL;
    OSStatus st = CMSampleBufferCreateReady(kCFAllocatorDefault, bb, fmt, 1, 1, &t, 1, &len, &sb);
    CFRelease(bb);
    if (st != noErr) return NULL;
    if (!sync) {
        CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, YES);
        if (att && CFArrayGetCount(att)) {
            CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(att, 0);
            CFDictionarySetValue(d, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
        }
    }
    return sb;
}

// Feeds queued samples to whichever input can take them. If `wait`, keeps going until queues are empty.
static BOOL DVDrain(DVRemuxState *s, BOOL wait) {
    int idle = 0;
    while (1) {
        BOOL progressed = NO;
        while (s->vQ.count && s->vIn.readyForMoreMediaData) {
            CMSampleBufferRef sb = (__bridge CMSampleBufferRef)s->vQ.firstObject;
            if (![s->vIn appendSampleBuffer:sb]) return NO;
            [s->vQ removeObjectAtIndex:0];
            progressed = YES;
        }
        while (s->aQ.count && s->aIn.readyForMoreMediaData) {
            CMSampleBufferRef sb = (__bridge CMSampleBufferRef)s->aQ.firstObject;
            if (![s->aIn appendSampleBuffer:sb]) return NO;
            [s->aQ removeObjectAtIndex:0];
            progressed = YES;
        }
        if (s->writer.status == AVAssetWriterStatusFailed) return NO;
        BOOL empty = !s->vQ.count && !s->aQ.count;
        if (empty) return YES;
        if (!wait) {
            // Only block when both queues hold data (otherwise more parsing is needed to unblock the writer).
            BOOL bothFull = s->vQ.count > 0 && (s->aQ.count > 0 || !s->aIn);
            if (!bothFull && s->vQ.count < 600 && s->aQ.count < 1200) return YES;
        } else if (!progressed) {
            // At the end, an input with nothing left must not hold the other one back.
            if (!s->vQ.count && s->vIn) { [s->vIn markAsFinished]; s->vIn = nil; }
            if (!s->aQ.count && s->aIn) { [s->aIn markAsFinished]; s->aIn = nil; }
        }
        if (progressed) idle = 0;
        else if (++idle > 5000) return NO; // ~10s with no progress: give up
        if (!progressed) usleep(2000);
    }
}

#pragma mark - Elementary streams

static size_t DVNextStart(const uint8_t *p, size_t len, size_t from) {
    for (size_t i = from; i + 3 <= len; i++) {
        if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1) return i;
    }
    return len;
}

static void DVVideoAU(DVRemuxState *s, const uint8_t *p, size_t len, int64_t pts, int64_t dts) {
    NSMutableData *avcc = [NSMutableData data];
    BOOL key = NO;
    size_t pos = DVNextStart(p, len, 0);
    while (pos < len) {
        size_t start = pos + 3;
        size_t next = DVNextStart(p, len, start);
        const uint8_t *nal = p + start;
        size_t nlen = next > start ? next - start : 0;
        while (nlen && nal[nlen - 1] == 0) nlen--; // drop the leading 0 of a 4-byte start code
        if (nlen) {
            int type = nal[0] & 0x1F;
            if (type == 7) { if (s->scanning && !s->sps) s->sps = [NSData dataWithBytes:nal length:nlen]; }
            else if (type == 8) { if (s->scanning && !s->pps) s->pps = [NSData dataWithBytes:nal length:nlen]; }
            else if (type != 9) {
                if (type == 5) key = YES;
                uint32_t be = CFSwapInt32HostToBig((uint32_t)nlen);
                [avcc appendBytes:&be length:4];
                [avcc appendBytes:nal length:nlen];
            }
        }
        pos = next;
    }

    if (s->scanning) {
        if (s->firstPTS < 0 || pts < s->firstPTS) s->firstPTS = pts;
        return;
    }
    if (!avcc.length || !s->vIn) return;
    if (!s->haveV && !key) return; // start on a keyframe

    // Glue discontinuities (ad gaps, timestamp resets) into one continuous timeline.
    int64_t adts = dts + s->offset;
    if (s->haveV && (adts < s->lastVDTS - 90000 || adts > s->lastVDTS + 90000 * 20)) {
        s->offset += (s->lastVDTS + 3000) - adts;
        adts = dts + s->offset;
    }
    if (s->haveV && adts <= s->lastVDTS) adts = s->lastVDTS + 1;
    int64_t apts = pts + s->offset;
    if (apts < adts) apts = adts;
    s->lastVDTS = adts;
    s->haveV = YES;

    CMSampleBufferRef sb = DVMakeSample(avcc, s->vFmt, CMTimeMake(apts, 90000), CMTimeMake(adts, 90000), kCMTimeInvalid, key);
    if (sb) { [s->vQ addObject:(__bridge_transfer id)sb]; s->vCount++; }
}

static void DVAudioPES(DVRemuxState *s, const uint8_t *p, size_t len, int64_t pts) {
    size_t i = 0;
    int k = 0;
    while (i + 7 <= len) {
        if (p[i] != 0xFF || (p[i + 1] & 0xF0) != 0xF0) { i++; continue; }
        int protAbsent = p[i + 1] & 1;
        int obj = ((p[i + 2] >> 6) & 3) + 1;
        int sfi = (p[i + 2] >> 2) & 0xF;
        int ch = ((p[i + 2] & 1) << 2) | (p[i + 3] >> 6);
        size_t flen = ((size_t)(p[i + 3] & 3) << 11) | ((size_t)p[i + 4] << 3) | (p[i + 5] >> 5);
        size_t hdr = protAbsent ? 7 : 9;
        if (flen < hdr || i + flen > len) break;
        if (s->scanning) {
            if (!s->aacObj) { s->aacObj = obj; s->aacSFI = sfi; s->aacCh = ch; }
            if (s->firstPTS < 0 || pts < s->firstPTS) s->firstPTS = pts;
            return;
        }
        int rate = kAACRates[s->aacSFI] ?: 48000;
        if (s->aIn && s->haveV) {
            int64_t t90 = pts + s->offset + (int64_t)k * 1024 * 90000 / rate;
            if (t90 > s->lastAPTS) {
                s->lastAPTS = t90;
                NSData *raw = [NSData dataWithBytes:p + i + hdr length:flen - hdr];
                CMTime t = CMTimeMake(t90, 90000);
                CMSampleBufferRef sb = DVMakeSample(raw, s->aFmt, t, t, CMTimeMake(1024, rate), YES);
                if (sb) { [s->aQ addObject:(__bridge_transfer id)sb]; s->aCount++; }
            }
        }
        k++;
        i += flen;
    }
}

static void DVFlushPES(DVRemuxState *s, NSMutableData *pes, BOOL video) {
    if (pes.length < 9) { pes.length = 0; return; }
    const uint8_t *b = pes.bytes;
    if (!(b[0] == 0 && b[1] == 0 && b[2] == 1)) { pes.length = 0; return; }
    int flags = b[7];
    size_t hlen = b[8];
    if (9 + hlen > pes.length) { pes.length = 0; return; }
    int64_t pts = -1, dts = -1;
    if ((flags & 0x80) && hlen >= 5) pts = DVReadTS(b + 9);
    if ((flags & 0x40) && hlen >= 10) dts = DVReadTS(b + 14);
    if (dts < 0) dts = pts;
    if (pts >= 0) {
        const uint8_t *es = b + 9 + hlen;
        size_t elen = pes.length - 9 - hlen;
        if (video) DVVideoAU(s, es, elen, pts, dts);
        else DVAudioPES(s, es, elen, pts);
    }
    pes.length = 0;
}

#pragma mark - Transport stream

static void DVParsePacket(DVRemuxState *s, const uint8_t *pk) {
    if (pk[0] != 0x47) return;
    int pid = ((pk[1] & 0x1F) << 8) | pk[2];
    BOOL pusi = (pk[1] & 0x40) != 0;
    int afc = (pk[3] >> 4) & 3;
    size_t off = 4;
    if (afc & 2) off += 1 + pk[4];
    if (!(afc & 1) || off >= 188) return;
    const uint8_t *pl = pk + off;
    size_t plen = 188 - off;

    if (pid == 0 && pusi) {
        size_t ptr = pl[0];
        if (1 + ptr + 8 > plen) return;
        const uint8_t *t = pl + 1 + ptr;
        size_t slen = ((t[1] & 0x0F) << 8) | t[2];
        size_t end = MIN(3 + slen - 4, plen - 1 - ptr);
        for (size_t i = 8; i + 4 <= end; i += 4) {
            int prog = (t[i] << 8) | t[i + 1];
            if (prog != 0) { s->pmtPID = ((t[i + 2] & 0x1F) << 8) | t[i + 3]; break; }
        }
        return;
    }
    if (pid == s->pmtPID && pusi) {
        size_t ptr = pl[0];
        if (1 + ptr + 12 > plen) return;
        const uint8_t *t = pl + 1 + ptr;
        size_t slen = ((t[1] & 0x0F) << 8) | t[2];
        size_t pil = ((t[10] & 0x0F) << 8) | t[11];
        size_t end = MIN(3 + slen - 4, plen - 1 - ptr);
        for (size_t i = 12 + pil; i + 5 <= end;) {
            int st = t[i];
            int epid = ((t[i + 1] & 0x1F) << 8) | t[i + 2];
            size_t esil = ((t[i + 3] & 0x0F) << 8) | t[i + 4];
            if (st == 0x1B && s->videoPID < 0) s->videoPID = epid;
            if (st == 0x24 && s->videoPID < 0) { s->videoPID = epid; s->hevc = YES; }
            if (st == 0x0F && s->audioPID < 0) s->audioPID = epid;
            i += 5 + esil;
        }
        return;
    }
    if (pid == s->videoPID) {
        if (pusi) DVFlushPES(s, s->vPES, YES);
        [s->vPES appendBytes:pl length:plen];
    } else if (pid == s->audioPID) {
        if (pusi) DVFlushPES(s, s->aPES, NO);
        [s->aPES appendBytes:pl length:plen];
    }
}

static BOOL DVRunPass(DVRemuxState *s, NSURL *src, unsigned long long limit) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:src error:nil];
    if (!fh) return NO;
    s->vPES = [NSMutableData data];
    s->aPES = [NSMutableData data];
    unsigned long long readTotal = 0;
    NSMutableData *carry = [NSMutableData data];
    while (1) {
        @autoreleasepool {
            NSData *chunk = [fh readDataOfLength:188 * 4096];
            if (!chunk.length) break;
            readTotal += chunk.length;
            [carry appendData:chunk];
            const uint8_t *b = carry.bytes;
            size_t n = carry.length, i = 0;
            while (i + 188 <= n) {
                if (b[i] != 0x47) { i++; continue; } // resync
                DVParsePacket(s, b + i);
                i += 188;
            }
            [carry replaceBytesInRange:NSMakeRange(0, i) withBytes:NULL length:0];
            if (!s->scanning && !DVDrain(s, NO)) { [fh closeFile]; return NO; }
            if (s->scanning && s->sps && s->pps && (s->aacObj || s->audioPID < 0) && s->firstPTS >= 0 && readTotal > 4 * 1024 * 1024) break;
            if (limit && readTotal >= limit) break;
        }
    }
    [fh closeFile];
    DVFlushPES(s, s->vPES, YES);
    DVFlushPES(s, s->aPES, NO);
    return YES;
}

static NSData *DVEsdsCookie(int obj, int sfi, int ch) {
    uint16_t asc = (uint16_t)((obj << 11) | (sfi << 7) | (ch << 3));
    uint8_t d[] = {
        0x03, 25, 0x00, 0x00, 0x00,                // ES_Descriptor, ES_ID, flags
        0x04, 17, 0x40, 0x15, 0, 0, 0,             // DecoderConfig: AAC, audio stream, bufferSize
        0, 0, 0, 0, 0, 0, 0, 0,                    // max / avg bitrate
        0x05, 2, (uint8_t)(asc >> 8), (uint8_t)asc, // AudioSpecificConfig
        0x06, 1, 0x02,                             // SLConfig
    };
    return [NSData dataWithBytes:d length:sizeof(d)];
}

@implementation DVRemuxer

+ (BOOL)remuxTS:(NSURL *)src to:(NSURL *)dst error:(NSError **)error {
    DVRemuxState *s = [DVRemuxState new];
    s->pmtPID = s->videoPID = s->audioPID = -1;
    s->firstPTS = -1;

    // Pass 1: learn codec parameters.
    s->scanning = YES;
    if (!DVRunPass(s, src, 40ull * 1024 * 1024)) { if (error) *error = DVRErr(@"Couldn't read file"); return NO; }
    if (s->hevc) { if (error) *error = DVRErr(@"HEVC streams aren't supported"); return NO; }
    if (!s->sps || !s->pps) { if (error) *error = DVRErr(@"No video found"); return NO; }

    const uint8_t *ps[2] = {s->sps.bytes, s->pps.bytes};
    size_t psz[2] = {s->sps.length, s->pps.length};
    CMVideoFormatDescriptionRef vf = NULL;
    if (CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, ps, psz, 4, &vf) != noErr) {
        if (error) *error = DVRErr(@"Unsupported video format");
        return NO;
    }
    s->vFmt = vf;

    if (s->aacObj) {
        int rate = kAACRates[s->aacSFI] ?: 48000;
        AudioStreamBasicDescription asbd = {0};
        asbd.mSampleRate = rate;
        asbd.mFormatID = kAudioFormatMPEG4AAC;
        asbd.mFormatFlags = s->aacObj;
        asbd.mFramesPerPacket = 1024;
        asbd.mChannelsPerFrame = s->aacCh ?: 2;
        NSData *cookie = DVEsdsCookie(s->aacObj, s->aacSFI, s->aacCh ?: 2);
        CMAudioFormatDescriptionRef af = NULL;
        if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, cookie.length, cookie.bytes, NULL, &af) == noErr) s->aFmt = af;
    }

    // Pass 2: write.
    [NSFileManager.defaultManager removeItemAtURL:dst error:nil];
    NSError *we = nil;
    s->writer = [AVAssetWriter assetWriterWithURL:dst fileType:AVFileTypeMPEG4 error:&we];
    if (!s->writer) { if (error) *error = we; CFRelease(vf); if (s->aFmt) CFRelease(s->aFmt); return NO; }
    s->writer.shouldOptimizeForNetworkUse = YES;
    s->vIn = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:nil sourceFormatHint:vf];
    s->vIn.expectsMediaDataInRealTime = NO;
    [s->writer addInput:s->vIn];
    if (s->aFmt) {
        s->aIn = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:nil sourceFormatHint:s->aFmt];
        s->aIn.expectsMediaDataInRealTime = NO;
        if ([s->writer canAddInput:s->aIn]) [s->writer addInput:s->aIn];
        else s->aIn = nil;
    }
    if (![s->writer startWriting]) {
        if (error) *error = s->writer.error ?: DVRErr(@"Writer failed to start");
        CFRelease(vf); if (s->aFmt) CFRelease(s->aFmt);
        return NO;
    }
    [s->writer startSessionAtSourceTime:CMTimeMake(s->firstPTS, 90000)];

    s->scanning = NO;
    s->vQ = [NSMutableArray array];
    s->aQ = [NSMutableArray array];
    s->lastAPTS = INT64_MIN;
    s->pmtPID = s->videoPID = s->audioPID = -1;
    BOOL ok = DVRunPass(s, src, 0) && DVDrain(s, YES);

    if (s->vIn) [s->vIn markAsFinished];
    if (s->aIn) [s->aIn markAsFinished];
    if (ok && s->vCount > 0) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [s->writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        ok = s->writer.status == AVAssetWriterStatusCompleted;
    } else {
        [s->writer cancelWriting];
        ok = NO;
    }
    if (!ok && error) *error = s->writer.error ?: DVRErr(@"Conversion failed");
    CFRelease(vf);
    if (s->aFmt) CFRelease(s->aFmt);
    if (!ok) [NSFileManager.defaultManager removeItemAtURL:dst error:nil];
    return ok;
}

@end

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "DVRemuxer.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        NSURL *src = [NSURL fileURLWithPath:@(argv[1])], *dst = [NSURL fileURLWithPath:@(argv[2])];
        NSDate *t0 = NSDate.date;
        NSError *e = nil;
        BOOL ok = [DVRemuxer remuxTS:src to:dst error:&e];
        printf("remux=%d err=%s time=%.1fs\n", ok, e.localizedDescription.UTF8String ?: "-", -t0.timeIntervalSinceNow);
        if (!ok) return 1;
        AVURLAsset *a = [AVURLAsset URLAssetWithURL:dst options:nil];
        printf("playable=%d duration=%.2f\n", a.isPlayable, CMTimeGetSeconds(a.duration));
        for (AVAssetTrack *tr in a.tracks) printf("track %s %.2fs frames=%.1f size=%.0fx%.0f\n", tr.mediaType.UTF8String, CMTimeGetSeconds(tr.timeRange.duration), tr.nominalFrameRate, tr.naturalSize.width, tr.naturalSize.height);
        AVAssetImageGenerator *g = [AVAssetImageGenerator assetImageGeneratorWithAsset:a];
        NSError *ie = nil;
        CGImageRef img = [g copyCGImageAtTime:CMTimeMake(3, 1) actualTime:NULL error:&ie];
        printf("frame@3s=%s %s\n", img ? "ok" : "FAIL", ie.localizedDescription.UTF8String ?: "");
        AVAssetTrack *vt = [a tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (vt) {
            AVAssetReader *r = [AVAssetReader assetReaderWithAsset:a error:nil];
            AVAssetReaderTrackOutput *o = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:vt outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
            [r addOutput:o]; [r startReading];
            int n = 0; CMSampleBufferRef sb;
            while ((sb = [o copyNextSampleBuffer])) { n++; CFRelease(sb); }
            printf("video decoded frames=%d status=%ld err=%s\n", n, (long)r.status, r.error.localizedDescription.UTF8String ?: "-");
        }
        // decode audio to be sure the AAC track is valid
        AVAssetTrack *at = [a tracksWithMediaType:AVMediaTypeAudio].firstObject;
        if (at) {
            AVAssetReader *r = [AVAssetReader assetReaderWithAsset:a error:nil];
            AVAssetReaderTrackOutput *o = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:at outputSettings:@{AVFormatIDKey: @(kAudioFormatLinearPCM)}];
            [r addOutput:o]; [r startReading];
            int n = 0; CMSampleBufferRef sb;
            while ((sb = [o copyNextSampleBuffer])) { n++; CFRelease(sb); }
            printf("audio decoded buffers=%d status=%ld err=%s\n", n, (long)r.status, r.error.localizedDescription.UTF8String ?: "-");
        }
        // passthrough export check (what Photos-compat needs)
        AVAssetExportSession *ex = [AVAssetExportSession exportSessionWithAsset:a presetName:AVAssetExportPresetPassthrough];
        printf("export filetypes mp4=%d\n", [ex.supportedFileTypes containsObject:AVFileTypeMPEG4]);
        return 0;
    }
}

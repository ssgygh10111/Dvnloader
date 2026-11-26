#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        NSURL *src = [NSURL fileURLWithPath:@(argv[1])], *dst = [NSURL fileURLWithPath:@(argv[2])];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:src options:nil];
        printf("src playable=%d dur=%.2f tracks=%lu\n", asset.isPlayable, CMTimeGetSeconds(asset.duration), (unsigned long)asset.tracks.count);
        AVAssetExportSession *ex = [AVAssetExportSession exportSessionWithAsset:asset presetName:AVAssetExportPresetPassthrough];
        ex.outputURL = dst; ex.outputFileType = AVFileTypeMPEG4; ex.shouldOptimizeForNetworkUse = YES;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [ex exportAsynchronouslyWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        printf("export status=%ld err=%s\n", (long)ex.status, ex.error.localizedDescription.UTF8String ?: "-");
        AVURLAsset *o = [AVURLAsset URLAssetWithURL:dst options:nil];
        printf("out dur=%.2f tracks=%lu\n", CMTimeGetSeconds(o.duration), (unsigned long)o.tracks.count);
    }
}

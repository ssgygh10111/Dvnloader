#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        AVURLAsset *a = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(argv[1])] options:nil];
        AVAssetTrack *vt = [a tracksWithMediaType:AVMediaTypeVideo].firstObject;
        AVAssetReader *r = [AVAssetReader assetReaderWithAsset:a error:nil];
        AVAssetReaderTrackOutput *o = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:vt outputSettings:nil];
        [r addOutput:o]; [r startReading];
        for (int f = 0; f < 7; f++) {
            CMSampleBufferRef sb = [o copyNextSampleBuffer]; if (!sb) break;
            CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
            size_t len = CMBlockBufferGetDataLength(bb);
            NSMutableData *d = [NSMutableData dataWithLength:len];
            CMBlockBufferCopyDataBytes(bb, 0, len, d.mutableBytes);
            const uint8_t *p = d.bytes; size_t i = 0;
            printf("frame %d len %zu:", f, len);
            while (i + 4 <= len) { uint32_t n = (p[i]<<24)|(p[i+1]<<16)|(p[i+2]<<8)|p[i+3]; printf(" [t%d %u ..%02x%02x]", p[i+4]&0x1f, n, p[i+4+n-2], p[i+4+n-1]); i += 4 + n; }
            printf("\n");
            CFRelease(sb);
        }
    }
}

#import <ReplayKit/ReplayKit.h>
#import <CoreVideo/CoreVideo.h>
#import <Accelerate/Accelerate.h>
#import "Shared.h"

/* ReplayKit 广播上传扩展：把系统广播出来的画面缩到 480 宽，
 * 写进主 App 也能读的共享目录，然后发一条 Darwin 通知。 */
@interface SampleHandler : RPBroadcastSampleHandler
@end

@implementation SampleHandler {
    double _lastWrite;
}

- (void)broadcastStartedWithSetupInfo:(NSDictionary<NSString *, NSObject *> *)setupInfo {
    NSLog(@"[XQ] broadcast started, dir=%@", XQSharedDir());
}

- (void)broadcastPaused  { NSLog(@"[XQ] broadcast paused"); }
- (void)broadcastResumed { NSLog(@"[XQ] broadcast resumed"); }
- (void)broadcastFinished{ NSLog(@"[XQ] broadcast finished"); }

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer withType:(RPSampleBufferType)bufferType {
    if (bufferType != RPSampleBufferTypeVideo) return;

    double now = [[NSDate date] timeIntervalSince1970];
    if (now - _lastWrite < 0.2) return;          /* ≤5 fps 就够 */
    _lastWrite = now;

    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pb) return;

    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    size_t w = CVPixelBufferGetWidth(pb);
    size_t h = CVPixelBufferGetHeight(pb);
    void  *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr  = CVPixelBufferGetBytesPerRow(pb);

    if (!base || w < 64 || h < 64) {
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        return;
    }

    int ow = 480;
    int oh = (int)((double)h * ow / (double)w);
    if (oh < 1) oh = 1;

    void *dst = calloc((size_t)ow * oh, 4);
    if (!dst) {
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        return;
    }

    vImage_Buffer src = { base, (vImagePixelCount)h, (vImagePixelCount)w, bpr };
    vImage_Buffer d   = { dst,  (vImagePixelCount)oh, (vImagePixelCount)ow, (size_t)ow * 4 };
    vImageScale_ARGB8888(&src, &d, NULL, kvImageHighQualityResampling);

    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);

    if (!XQSendFrameTCP(dst, ow, oh, ow * 4)) {
        if (XQWriteFrame(dst, ow, oh, ow * 4)) XQPostFrameNotification();
    }
    free(dst);
}

@end

#import <Foundation/Foundation.h>

#define XQ_NOTIF_NAME  "com.yg.xiangqilink.frame"
#define XQ_FRAME_NAME  "frame.bin"
#define XQ_FRAME_MAGIC 0x52465158u   /* 'XQFR' */
#define XQ_TCP_PORT    51234

typedef struct {
    uint32_t magic;
    int32_t  width;
    int32_t  height;
    int32_t  stride;
    double   timestamp;
} XQFrameHeader;

/* ---- 跨进程取帧：本地 TCP（沙盒不拦） ---- */

/* 主 App：起一个 127.0.0.1:51234 监听，收到帧就更新内存里的最新帧 */
void XQStartFrameServer(void);
/* 主 App：取最新一帧（malloc，调用方 free） */
BOOL XQTakeLatestFrame(void **outPtr, int *w, int *h, int *stride, double *ts);

/* 扩展：把帧发给主 App；失败返回 NO */
BOOL XQSendFrameTCP(const void *bgra, int w, int h, int stride);

/* ---- 兜底：共享文件（同沙盒时可用） ---- */
NSString *XQSharedDir(void);
BOOL      XQWriteFrame(const void *bgra, int w, int h, int stride);
BOOL      XQReadFrame(void **outPtr, int *w, int *h, int *stride, double *ts);
void      XQPostFrameNotification(void);

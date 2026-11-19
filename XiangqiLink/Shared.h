#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>

#define XQ_NOTIF_NAME  "com.yg.xiangqilink.frame"
#define XQ_FRAME_NAME  "frame.bin"
#define XQ_CAL_NAME    "cal.plist"
#define XQ_FRAME_MAGIC 0x52465158u   /* 'XQFR' */

typedef struct {
    uint32_t magic;
    int32_t  width;
    int32_t  height;
    int32_t  stride;
    double   timestamp;
} XQFrameHeader;

/* 主 App 与广播扩展共享的目录；两边都能读写 */
NSString *XQSharedDir(void);
BOOL      XQWriteFrame(const void *bgra, int w, int h, int stride);
/* 返回 malloc 的缓冲区，调用方 free */
BOOL      XQReadFrame(void **outPtr, int *w, int *h, int *stride, double *ts);
void      XQPostFrameNotification(void);

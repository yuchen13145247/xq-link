#import "Shared.h"
#include <sys/stat.h>
#include <unistd.h>

static NSString *g_dir = nil;

static BOOL EnsureDir(NSString *p) {
    if (!p) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:p isDirectory:&isDir]) return isDir;
    NSError *err = nil;
    return [fm createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:&err];
}

NSString *XQSharedDir(void) {
    if (g_dir) return g_dir;

    NSMutableArray<NSString *> *cands = [NSMutableArray array];

    /* 1) App Group（TrollStore 下一般也生效） */
    NSURL *g = [[NSFileManager defaultManager]
                containerURLForSecurityApplicationGroupIdentifier:@"group.com.yg.xiangqilink"];
    if (g) [cands addObject:g.path];

    /* 2) 无沙盒时可直接写这个目录 */
    [cands addObject:@"/var/mobile/Library/Caches/com.yg.xiangqilink"];

    /* 3) 兜底：各自的 Caches（同进程可用，跨进程不共享） */
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (paths.count) [cands addObject:[paths[0] stringByAppendingPathComponent:@"xqlink"]];

    for (NSString *p in cands) {
        if (EnsureDir(p) && access([p fileSystemRepresentation], W_OK) == 0) {
            g_dir = p;
            NSLog(@"[XQ] shared dir = %@", p);
            return g_dir;
        }
    }
    g_dir = NSTemporaryDirectory();
    NSLog(@"[XQ] shared dir fallback tmp = %@", g_dir);
    return g_dir;
}

BOOL XQWriteFrame(const void *bgra, int w, int h, int stride) {
    @autoreleasepool {
        NSString *path = [XQSharedDir() stringByAppendingPathComponent:@XQ_FRAME_NAME];
        NSString *tmp  = [path stringByAppendingString:@".tmp"];
        int fd = open([tmp fileSystemRepresentation], O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) return NO;

        XQFrameHeader hdr;
        hdr.magic = XQ_FRAME_MAGIC;
        hdr.width = w;
        hdr.height = h;
        hdr.stride = stride;
        hdr.timestamp = [[NSDate date] timeIntervalSince1970];

        ssize_t n1 = write(fd, &hdr, sizeof(hdr));
        ssize_t n2 = write(fd, bgra, (size_t)stride * (size_t)h);
        close(fd);
        if (n1 != (ssize_t)sizeof(hdr) || n2 != (ssize_t)((size_t)stride * (size_t)h)) {
            unlink([tmp fileSystemRepresentation]);
            return NO;
        }
        return rename([tmp fileSystemRepresentation], [path fileSystemRepresentation]) == 0;
    }
}

BOOL XQReadFrame(void **outPtr, int *w, int *h, int *stride, double *ts) {
    @autoreleasepool {
        NSString *path = [XQSharedDir() stringByAppendingPathComponent:@XQ_FRAME_NAME];
        int fd = open([path fileSystemRepresentation], O_RDONLY);
        if (fd < 0) return NO;

        XQFrameHeader hdr;
        if (read(fd, &hdr, sizeof(hdr)) != (ssize_t)sizeof(hdr) || hdr.magic != XQ_FRAME_MAGIC) {
            close(fd);
            return NO;
        }
        size_t need = (size_t)hdr.stride * (size_t)hdr.height;
        if (need == 0 || need > 64u * 1024u * 1024u) { close(fd); return NO; }

        void *buf = malloc(need);
        if (!buf) { close(fd); return NO; }
        ssize_t got = read(fd, buf, need);
        close(fd);
        if (got != (ssize_t)need) { free(buf); return NO; }

        *outPtr = buf;
        *w = hdr.width;
        *h = hdr.height;
        *stride = hdr.stride;
        if (ts) *ts = hdr.timestamp;
        return YES;
    }
}

void XQPostFrameNotification(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR(XQ_NOTIF_NAME), NULL, NULL, true);
}

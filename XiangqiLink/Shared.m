#import "Shared.h"
#include <sys/stat.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <sys/time.h>
#include <string.h>

#pragma mark - 跨进程 TCP 取帧

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static void  *g_frame = NULL;
static int    g_w = 0, g_h = 0, g_stride = 0;
static double g_ts = 0;
static BOOL   g_serverStarted = NO;

void XQPostFrameNotification(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR(XQ_NOTIF_NAME), NULL, NULL, true);
}

static void *server_thread(void *arg) {
    (void)arg;
    int ls = socket(AF_INET, SOCK_STREAM, 0);
    if (ls < 0) return NULL;
    int on = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(XQ_TCP_PORT);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(ls, (struct sockaddr *)&a, sizeof(a)) < 0) {
        NSLog(@"[XQ] bind %d failed", XQ_TCP_PORT);
        close(ls);
        return NULL;
    }
    listen(ls, 4);
    NSLog(@"[XQ] frame server on 127.0.0.1:%d", XQ_TCP_PORT);

    for (;;) {
        int c = accept(ls, NULL, NULL);
        if (c < 0) continue;

        struct timeval tv = {1, 0};
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        XQFrameHeader h;
        ssize_t n = recv(c, &h, sizeof(h), MSG_WAITALL);
        if (n == (ssize_t)sizeof(h) && h.magic == XQ_FRAME_MAGIC) {
            size_t need = (size_t)h.stride * (size_t)h.height;
            if (need > 0 && need < 64u * 1024u * 1024u) {
                void *buf = malloc(need);
                if (buf && recv(c, buf, need, MSG_WAITALL) == (ssize_t)need) {
                    pthread_mutex_lock(&g_lock);
                    free(g_frame);
                    g_frame = buf;
                    g_w = h.width; g_h = h.height; g_stride = h.stride; g_ts = h.timestamp;
                    pthread_mutex_unlock(&g_lock);
                    XQPostFrameNotification();
                } else {
                    free(buf);
                }
            }
        }
        close(c);
    }
    return NULL;
}

void XQStartFrameServer(void) {
    if (g_serverStarted) return;
    g_serverStarted = YES;
    pthread_t th;
    if (pthread_create(&th, NULL, server_thread, NULL) == 0) pthread_detach(th);
}

BOOL XQTakeLatestFrame(void **outPtr, int *w, int *h, int *stride, double *ts) {
    pthread_mutex_lock(&g_lock);
    if (!g_frame) { pthread_mutex_unlock(&g_lock); return NO; }
    size_t need = (size_t)g_stride * (size_t)g_h;
    void *copy = malloc(need);
    if (!copy) { pthread_mutex_unlock(&g_lock); return NO; }
    memcpy(copy, g_frame, need);
    *outPtr = copy; *w = g_w; *h = g_h; *stride = g_stride;
    if (ts) *ts = g_ts;
    pthread_mutex_unlock(&g_lock);
    return YES;
}

BOOL XQSendFrameTCP(const void *bgra, int w, int h, int stride) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return NO;

    struct timeval tv = {0, 300000};   /* 300ms 写超时 */
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    int on = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));

    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(XQ_TCP_PORT);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(s, (struct sockaddr *)&a, sizeof(a)) < 0) {
        close(s);
        return NO;
    }

    XQFrameHeader hh;
    hh.magic = XQ_FRAME_MAGIC;
    hh.width = w; hh.height = h; hh.stride = stride;
    hh.timestamp = [[NSDate date] timeIntervalSince1970];

    size_t need = (size_t)stride * (size_t)h;
    ssize_t r1 = send(s, &hh, sizeof(hh), 0);
    ssize_t r2 = send(s, bgra, need, 0);
    close(s);

    return r1 == (ssize_t)sizeof(hh) && r2 == (ssize_t)need;
}

#pragma mark - 共享目录（兜底）

static NSString *g_dir = nil;

static BOOL EnsureDir(NSString *p) {
    if (!p) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:p isDirectory:&isDir]) return isDir;
    return [fm createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
}

NSString *XQSharedDir(void) {
    if (g_dir) return g_dir;

    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    NSURL *g = [[NSFileManager defaultManager]
                containerURLForSecurityApplicationGroupIdentifier:@"group.com.yg.xiangqilink"];
    if (g) [cands addObject:g.path];
    [cands addObject:@"/var/mobile/Library/Caches/com.yg.xiangqilink"];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (paths.count) [cands addObject:[paths[0] stringByAppendingPathComponent:@"xqlink"]];

    for (NSString *p in cands) {
        if (EnsureDir(p) && access([p fileSystemRepresentation], W_OK) == 0) {
            g_dir = p;
            return g_dir;
        }
    }
    g_dir = NSTemporaryDirectory();
    return g_dir;
}

BOOL XQWriteFrame(const void *bgra, int w, int h, int stride) {
    @autoreleasepool {
        NSString *path = [XQSharedDir() stringByAppendingPathComponent:@XQ_FRAME_NAME];
        NSString *tmp  = [path stringByAppendingString:@".tmp"];
        int fd = open([tmp fileSystemRepresentation], O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) return NO;

        XQFrameHeader hdr;
        hdr.magic = XQ_FRAME_MAGIC; hdr.width = w; hdr.height = h; hdr.stride = stride;
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

        *outPtr = buf; *w = hdr.width; *h = hdr.height; *stride = hdr.stride;
        if (ts) *ts = hdr.timestamp;
        return YES;
    }
}

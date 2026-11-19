#import "EngineBridge.h"
#include "Engine/engine_shim.h"

static void xq_line_cb_impl(const char *line, void *ctx) {
    @autoreleasepool {
        if (!line) return;
        NSString *s = [NSString stringWithUTF8String:line];
        if (s.length) [[XQEngine shared] performSelectorOnMainThread:@selector(handleLine:)
                                                          withObject:s
                                                       waitUntilDone:NO];
    }
}

@interface XQEngine ()
@property (nonatomic, readwrite) BOOL ready;
@property (nonatomic, assign) BOOL started;
- (void)handleLine:(NSString *)line;
@end

@implementation XQEngine

+ (instancetype)shared {
    static XQEngine *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[XQEngine alloc] init]; });
    return inst;
}

- (BOOL)startWithNNUE:(NSString *)nnuePath {
    if (self.started) return YES;
    xq_set_cb(xq_line_cb_impl, NULL);
    int rc = xq_start(nnuePath.UTF8String, 2, 64);
    NSLog(@"[XQ] engine start rc=%d nnue=%@", rc, nnuePath);
    self.started = (rc == 0);
    return self.started;
}

- (void)goFen:(NSString *)fen depth:(int)depth {
    if (!self.started) return;
    xq_go(fen.UTF8String, depth, 0);
}

- (void)stop { xq_stop(); }

- (void)handleLine:(NSString *)line {
    if ([line isEqualToString:@"readyok"]) {
        self.ready = YES;
        return;
    }
    if ([line hasPrefix:@"bestmove"]) {
        NSArray *p = [line componentsSeparatedByString:@" "];
        if (p.count >= 2 && self.onBestMove) self.onBestMove(p[1]);
        return;
    }
    if ([line hasPrefix:@"info"] && [line rangeOfString:@"score"].location != NSNotFound) {
        if (self.onInfo) self.onInfo(line);
    }
}

@end

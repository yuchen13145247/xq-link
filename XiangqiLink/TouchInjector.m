#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

typedef void *(*XQCreateEventFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                 uint32_t, double, double, double, double, double,
                                 uint32_t, uint32_t, uint32_t);
typedef void *(*XQClientCreateFn)(CFAllocatorRef);
typedef void (*XQClientScheduleFn)(void *, CFRunLoopRef, CFStringRef);
typedef void (*XQClientDispatchFn)(void *, void *);

@interface XQInjector : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL available;
- (BOOL)tapX:(CGFloat)x y:(CGFloat)y;
@end

@implementation XQInjector {
    XQCreateEventFn _createEvent;
    XQClientDispatchFn _dispatch;
    void *_client;
}

+ (instancetype)shared {
    static XQInjector *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[XQInjector alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!iokit) {
        NSLog(@"[XQ] dlopen IOKit failed: %s", dlerror());
        return self;
    }

    _createEvent = (XQCreateEventFn)dlsym(iokit, "IOHIDEventCreateDigitizerEvent");
    _dispatch = (XQClientDispatchFn)dlsym(iokit, "IOHIDEventSystemClientDispatchEvent");
    XQClientCreateFn createClient = (XQClientCreateFn)dlsym(iokit, "IOHIDEventSystemClientCreate");
    XQClientScheduleFn schedule = (XQClientScheduleFn)dlsym(iokit, "IOHIDEventSystemClientScheduleWithRunLoop");

    if (createClient) _client = createClient(kCFAllocatorDefault);
    if (_client && schedule) schedule(_client, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    NSLog(@"[XQ] injector available=%d", self.available ? 1 : 0);
    return self;
}

- (BOOL)available {
    return _createEvent != NULL && _dispatch != NULL && _client != NULL;
}

- (void *)eventWithX:(double)x y:(double)y down:(BOOL)down {
    if (!_createEvent) return NULL;
    uint32_t mask = (1u << 0) | (1u << 1);          // Range | Touch
    return _createEvent(kCFAllocatorDefault,
                        mach_absolute_time(),
                        3,                       // kIOHIDDigitizerTransducerTypeHand
                        0, 0, mask,
                        x, y, 0.0, 0.0, 0.0,
                        down ? 1u : 0u,
                        down ? 1u : 0u,
                        0);
}

- (BOOL)tapX:(CGFloat)x y:(CGFloat)y {
    if (!self.available) return NO;
    void *down = [self eventWithX:x y:y down:YES];
    if (down) _dispatch(_client, down);
    usleep(40000);
    void *up = [self eventWithX:x y:y down:NO];
    if (up) _dispatch(_client, up);
    return YES;
}

@end

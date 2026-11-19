import Foundation
import UIKit
import Darwin

/// 往「别的 App」注入点击。需要 entitlements：
///   com.apple.private.hid.client.event-dispatch
///   com.apple.private.hid.client.event-filter
///   platform-application / no-sandbox（TrollStore 签名时给）
/// 走私有 IOHIDEventSystemClient，全部 dlsym 拿符号，不引私有头文件。
final class TouchInjector {

    static let shared = TouchInjector()

    private typealias CreateDigitizerEventFn = @convention(c)
        (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32,
         Double, Double, Double, Double, Double, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?

    private typealias ClientCreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias ClientScheduleFn = @convention(c)
        (UnsafeMutableRawPointer?, CFRunLoop?, CFString?) -> Void
    private typealias ClientDispatchFn = @convention(c)
        (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

    private var createEvent: CreateDigitizerEventFn?
    private var dispatchEvent: ClientDispatchFn?
    private var client: UnsafeMutableRawPointer?

    private init() {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            NSLog("[XQ] dlopen IOKit failed: %@", String(cString: dlerror()))
            return
        }

        if let s = dlsym(iokit, "IOHIDEventCreateDigitizerEvent") {
            createEvent = unsafeBitCast(s, to: CreateDigitizerEventFn.self)
        }
        if let s = dlsym(iokit, "IOHIDEventSystemClientDispatchEvent") {
            dispatchEvent = unsafeBitCast(s, to: ClientDispatchFn.self)
        }
        if let s = dlsym(iokit, "IOHIDEventSystemClientCreate"),
           let createClient = Optional(unsafeBitCast(s, to: ClientCreateFn.self)) {
            client = createClient(kCFAllocatorDefault)
        }
        if let c = client,
           let s = dlsym(iokit, "IOHIDEventSystemClientScheduleWithRunLoop") {
            let schedule = unsafeBitCast(s, to: ClientScheduleFn.self)
            schedule(c, CFRunLoopGetMain(), kCFRunLoopDefaultMode as CFString)
        }

        NSLog("[XQ] injector available=%d", available ? 1 : 0)
    }

    var available: Bool { createEvent != nil && dispatchEvent != nil && client != nil }

    /// 造一个手指事件；down=true 按下，false 抬起
    private func makeEvent(x: Double, y: Double, down: Bool) -> UnsafeMutableRawPointer? {
        guard let createEvent else { return nil }
        let mask: UInt32 = (1 << 0) | (1 << 1)   // Range | Touch
        return createEvent(kCFAllocatorDefault,
                           mach_absolute_time(),
                           3,                     // kIOHIDDigitizerTransducerTypeHand
                           0,
                           0,
                           mask,
                           x, y, 0.0, 0.0, 0.0,
                           down ? 1 : 0,          // range
                           down ? 1 : 0,          // touch
                           0)                     // options
    }

    /// 单点点击（屏幕坐标，单位 point）
    @discardableResult
    func tap(x: CGFloat, y: CGFloat) -> Bool {
        guard available, let dispatchEvent, let client else { return false }

        if let down = makeEvent(x: Double(x), y: Double(y), down: true) {
            dispatchEvent(client, down)
        }
        usleep(40_000)
        if let up = makeEvent(x: Double(x), y: Double(y), down: false) {
            dispatchEvent(client, up)
        }
        return true
    }
}

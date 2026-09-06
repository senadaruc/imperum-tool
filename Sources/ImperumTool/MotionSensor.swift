import Foundation
import IOKit
import ImperumCore

/// Streams the Sensor Processing Unit's accelerometer (g) and gyroscope
/// (rad/s) at ~100 Hz via the private IOHIDEventSystemClient API — the only
/// way a user process gets these on Apple Silicon (the public IOHIDManager
/// opens the device but never delivers reports). Symbols are resolved with
/// dlsym so a missing symbol degrades to `isAvailable == false`, never a
/// link failure.
final class MotionSensor {
    /// Called on the sensor thread. `isGyro` false = accelerometer.
    var handler: ((_ isGyro: Bool, _ sample: MotionSample) -> Void)?

    private(set) var isAvailable = false
    private(set) var unavailableReason = ""

    private typealias CreateTypeFn = @convention(c) (CFAllocator?, Int32, CFDictionary?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFArray) -> Void
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias ServiceSetPropFn = @convention(c) (AnyObject, CFString, CFTypeRef) -> Bool
    private typealias EventCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, AnyObject) -> Void
    private typealias RegisterFn = @convention(c) (AnyObject, EventCallback, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias ScheduleFn = @convention(c) (AnyObject, CFRunLoop, CFString) -> Void
    private typealias GetTypeFn = @convention(c) (AnyObject) -> Int32
    private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

    private struct API {
        let createWithType: CreateTypeFn
        let setMatchingMultiple: SetMatchingFn
        let copyServices: CopyServicesFn
        let serviceSetProperty: ServiceSetPropFn
        let register: RegisterFn
        let schedule: ScheduleFn
        let unschedule: ScheduleFn
        let eventType: GetTypeFn
        let eventFloat: GetFloatFn
    }
    private let api: API?

    private static let appleVendorPage = 0xFF00
    private static let accelUsage = 3, gyroUsage = 9
    private static let accelEventType: Int32 = 13, gyroEventType: Int32 = 20
    private static let clientTypeMonitor: Int32 = 1
    private static let reportIntervalMicros = 10_000   // 100 Hz

    private var thread: Thread?
    private var running = false
    private let lock = NSLock()

    init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            api = nil; unavailableReason = "IOKit unavailable"; return
        }
        func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(h, name).map { unsafeBitCast($0, to: T.self) } }
        guard let create = sym("IOHIDEventSystemClientCreateWithType", CreateTypeFn.self),
              let match = sym("IOHIDEventSystemClientSetMatchingMultiple", SetMatchingFn.self),
              let copy = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let setProp = sym("IOHIDServiceClientSetProperty", ServiceSetPropFn.self),
              let reg = sym("IOHIDEventSystemClientRegisterEventCallback", RegisterFn.self),
              let sched = sym("IOHIDEventSystemClientScheduleWithRunLoop", ScheduleFn.self),
              let unsched = sym("IOHIDEventSystemClientUnscheduleWithRunLoop", ScheduleFn.self),
              let type = sym("IOHIDEventGetType", GetTypeFn.self),
              let flt = sym("IOHIDEventGetFloatValue", GetFloatFn.self) else {
            api = nil; unavailableReason = "Motion sensor API not present on this macOS"; return
        }
        api = API(createWithType: create, setMatchingMultiple: match, copyServices: copy,
                  serviceSetProperty: setProp, register: reg, schedule: sched, unschedule: unsched,
                  eventType: type, eventFloat: flt)
        // Probe once: is there an accelerometer service at all (Apple Silicon laptops only)?
        if let probe = create(nil, Self.clientTypeMonitor, nil)?.takeRetainedValue() {
            match(probe, Self.matching(usages: [Self.accelUsage]))
            let n = (copy(probe)?.takeRetainedValue() as? [AnyObject])?.count ?? 0
            isAvailable = n > 0
            if !isAvailable { unavailableReason = "No motion sensor found (Apple Silicon MacBooks only)" }
            NSLog("Imperum Tool motion: \(n) accelerometer service(s) found")
        } else {
            unavailableReason = "Could not create sensor client"
        }
    }

    private static func matching(usages: [Int]) -> CFArray {
        usages.map { ["PrimaryUsagePage": appleVendorPage, "PrimaryUsage": $0] as [String: Any] } as CFArray
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard isAvailable, let api, thread == nil else { return }
        running = true
        let t = Thread { [weak self] in
            guard let self, let client = api.createWithType(nil, Self.clientTypeMonitor, nil)?.takeRetainedValue() else {
                NSLog("Imperum Tool motion: could not create sensor client on the sensor thread"); return
            }
            api.setMatchingMultiple(client, Self.matching(usages: [Self.accelUsage, Self.gyroUsage]))
            let services = (api.copyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
            for s in services {
                _ = api.serviceSetProperty(s, "ReportInterval" as CFString, Self.reportIntervalMicros as CFNumber)
            }
            NSLog("Imperum Tool motion: streaming from \(services.count) sensor service(s)")
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            api.register(client, { _, refcon, _, event in
                guard let refcon else { return }
                let me = Unmanaged<MotionSensor>.fromOpaque(refcon).takeUnretainedValue()
                me.deliver(event)
            }, nil, refcon)
            let rl = CFRunLoopGetCurrent()!
            api.schedule(client, rl, CFRunLoopMode.defaultMode.rawValue)
            while self.isRunning { CFRunLoopRunInMode(.defaultMode, 0.5, false) }
            api.unschedule(client, rl, CFRunLoopMode.defaultMode.rawValue)
            NSLog("Imperum Tool motion: sensor thread stopped")
        }
        t.name = "io.imperum.tool.motion"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        lock.lock(); running = false; thread = nil; lock.unlock()
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func deliver(_ event: AnyObject) {
        guard let api, let handler else { return }
        let type = api.eventType(event)
        guard type == Self.accelEventType || type == Self.gyroEventType else { return }
        let base = type << 16
        let s = MotionSample(t: ProcessInfo.processInfo.systemUptime,
                             x: api.eventFloat(event, base), y: api.eventFloat(event, base + 1), z: api.eventFloat(event, base + 2))
        handler(type == Self.gyroEventType, s)
    }
}

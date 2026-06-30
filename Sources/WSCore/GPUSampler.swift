import Foundation
import IOKit

public struct GPUStats: Equatable {
    public var utilization: Double?
    public var rendererUtil: Double?
    public var tilerUtil: Double?
    public var memInUseMB: Double?
    public init(utilization: Double? = nil, rendererUtil: Double? = nil,
                tilerUtil: Double? = nil, memInUseMB: Double? = nil) {
        self.utilization = utilization; self.rendererUtil = rendererUtil
        self.tilerUtil = tilerUtil; self.memInUseMB = memInUseMB
    }
}

public func parseAcceleratorStats(_ perf: [String: Any]) -> GPUStats {
    func num(_ k: String) -> Double? { (perf[k] as? NSNumber)?.doubleValue }
    var s = GPUStats()
    s.utilization = num("Device Utilization %")
    s.rendererUtil = num("Renderer Utilization %")
    s.tilerUtil = num("Tiler Utilization %")
    if let bytes = num("In use system memory") { s.memInUseMB = bytes / 1_048_576.0 }
    return s
}

/// Reads the busiest IOAccelerator's PerformanceStatistics. Sudoless.
public func sampleGPU() -> GPUStats {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return GPUStats() }
    defer { IOObjectRelease(iterator) }
    var best = GPUStats()
    var service = IOIteratorNext(iterator)
    while service != 0 {
        defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let perf = dict["PerformanceStatistics"] as? [String: Any] else { continue }
        let s = parseAcceleratorStats(perf)
        if (s.utilization ?? -1) >= (best.utilization ?? -1) { best = s }
    }
    return best
}

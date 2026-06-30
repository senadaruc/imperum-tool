import Foundation

public struct SpikeConfig {
    public var cpuThreshold: Double
    public var gpuThreshold: Double
    public var cooldown: TimeInterval
    public var topN: Int
    public init(cpuThreshold: Double = 60, gpuThreshold: Double = 80,
                cooldown: TimeInterval = 30, topN: Int = 5) {
        self.cpuThreshold = cpuThreshold; self.gpuThreshold = gpuThreshold
        self.cooldown = cooldown; self.topN = topN
    }
}

public struct SpikeEvent {
    public var ts: Date
    public var wsCPU: Double
    public var gpuUtil: Double?
    public var top: [AppSample]
}

public final class SpikeLog {
    public private(set) var events: [SpikeEvent] = []
    public var config: SpikeConfig          // runtime-adjustable (Settings)
    private let maxEvents = 50
    private var lastTopName: String?

    public init(config: SpikeConfig = SpikeConfig()) { self.config = config }

    public func observe(_ snap: Snapshot) -> SpikeEvent? {
        let gpu = snap.gpu.utilization ?? 0
        let isSpike = snap.wsCPU > config.cpuThreshold || gpu > config.gpuThreshold
        guard isSpike else { return nil }
        let topName = snap.apps.first?.name
        if let last = events.last {
            let withinCooldown = snap.ts.timeIntervalSince(last.ts) < config.cooldown
            if withinCooldown && topName == lastTopName { return nil }
        }
        let ev = SpikeEvent(ts: snap.ts, wsCPU: snap.wsCPU, gpuUtil: snap.gpu.utilization,
                            top: Array(snap.apps.prefix(config.topN)))
        events.append(ev)
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
        lastTopName = topName
        return ev
    }
}

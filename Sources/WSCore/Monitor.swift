import Foundation

public struct Snapshot {
    public var ts: Date
    public var wsCPU: Double
    public var wsRSS: Double
    public var gpu: GPUStats
    public var apps: [AppSample]   // sorted by heavy desc, WindowServer excluded
    public init(ts: Date, wsCPU: Double, wsRSS: Double, gpu: GPUStats, apps: [AppSample]) {
        self.ts = ts; self.wsCPU = wsCPU; self.wsRSS = wsRSS; self.gpu = gpu; self.apps = apps
    }
}

public func buildSnapshot(winAgg: [Int32: WinAgg],
                          cpu: [Int32: (cpu: Double, rss: Double)],
                          wsPID: Int32?,
                          gpu: GPUStats,
                          now: Date) -> Snapshot {
    var wsCPU = 0.0, wsRSS = 0.0
    if let ws = wsPID, let c = cpu[ws] { wsCPU = c.cpu; wsRSS = c.rss }
    var apps: [AppSample] = []
    let pids = Set(winAgg.keys).union(cpu.keys)
    for pid in pids {
        if pid == wsPID { continue }
        guard let w = winAgg[pid] else { continue }   // suspects must own visible windows
        let c = cpu[pid] ?? (0, 0)
        let h = heavyScore(cpu: c.cpu, area: w.area, windows: w.windows, rss: c.rss)
        apps.append(AppSample(pid: pid, name: w.name, windows: w.windows, area: w.area,
                              perDisplayArea: w.perDisplay, cpu: c.cpu, rss: c.rss, heavy: h))
    }
    apps.sort { $0.heavy > $1.heavy }
    return Snapshot(ts: now, wsCPU: wsCPU, wsRSS: wsRSS, gpu: gpu, apps: apps)
}

public final class Monitor {
    private let cpuSampler = CPUSampler()
    private var wsPIDCache: Int32?
    public init() {}

    public func tick() -> Snapshot {
        let win = sampleWindows()
        if wsPIDCache == nil { wsPIDCache = windowServerPID() }
        var pids = Array(win.keys)
        if let ws = wsPIDCache { pids.append(ws) }
        let cpu = cpuSampler.sample(pids: pids)
        let gpu = sampleGPU()
        return buildSnapshot(winAgg: win, cpu: cpu, wsPID: wsPIDCache, gpu: gpu, now: Date())
    }
}

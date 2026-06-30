import Foundation
import Darwin

/// CPU% = (cpu-time delta in ns) / (wall elapsed in ns) * 100.
public func cpuPercent(prevNs: UInt64, curNs: UInt64, elapsed: TimeInterval) -> Double {
    guard elapsed > 0, curNs >= prevNs else { return 0 }
    let deltaNs = Double(curNs - prevNs)
    return deltaNs / (elapsed * 1_000_000_000.0) * 100.0
}

public final class CPUSampler {
    private var prevCPU: [Int32: UInt64] = [:]
    private var prevTime = Date()

    public init() {}

    /// Returns instantaneous CPU% and RSS(MB) per pid, using proc_pid_rusage deltas.
    public func sample(pids: [Int32]) -> [Int32: (cpu: Double, rss: Double)] {
        let now = Date()
        let elapsed = now.timeIntervalSince(prevTime)
        var out: [Int32: (Double, Double)] = [:]
        var nextPrev: [Int32: UInt64] = [:]
        for pid in pids {
            var info = rusage_info_current()
            let rc = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            guard rc == 0 else { continue }
            let cpuNs = info.ri_user_time + info.ri_system_time   // nanoseconds
            let rssMB = Double(info.ri_resident_size) / 1_048_576.0
            nextPrev[pid] = cpuNs
            if let p = prevCPU[pid] {
                out[pid] = (cpuPercent(prevNs: p, curNs: cpuNs, elapsed: elapsed), rssMB)
            } else {
                out[pid] = (0, rssMB)   // first observation: no delta yet
            }
        }
        prevCPU = nextPrev
        prevTime = now
        return out
    }
}

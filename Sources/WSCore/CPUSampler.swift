import Foundation

/// CPU% = (cpu-time delta in ns) / (wall elapsed in ns) * 100.
public func cpuPercent(prevNs: UInt64, curNs: UInt64, elapsed: TimeInterval) -> Double {
    guard elapsed > 0, curNs >= prevNs else { return 0 }
    let deltaNs = Double(curNs - prevNs)
    return deltaNs / (elapsed * 1_000_000_000.0) * 100.0
}

/// Parses `ps` cumulative CPU time into seconds. Accepts `MM:SS.ss`,
/// `HH:MM:SS.ss`, and an optional `DD-` day prefix (`2-03:04:05.06`).
public func parseCpuTime(_ s: String) -> Double {
    var str = s.trimmingCharacters(in: .whitespaces)
    var days = 0.0
    if let dash = str.firstIndex(of: "-") {
        days = Double(str[str.startIndex..<dash]) ?? 0
        str = String(str[str.index(after: dash)...])
    }
    let parts = str.split(separator: ":").map { Double($0) ?? 0 }
    var seconds = 0.0
    switch parts.count {
    case 3: seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
    case 2: seconds = parts[0] * 60 + parts[1]
    case 1: seconds = parts[0]
    default: seconds = 0
    }
    return days * 86_400 + seconds
}

/// One parsed `ps` row.
public struct PSRow: Equatable {
    public var pid: Int32
    public var cpuSeconds: Double
    public var rssMB: Double
    public init(pid: Int32, cpuSeconds: Double, rssMB: Double) {
        self.pid = pid; self.cpuSeconds = cpuSeconds; self.rssMB = rssMB
    }
}

/// Parses lines of `ps -axro pid=,cputime=,rss=` — three leading columns.
public func parsePSRows(_ text: String) -> [PSRow] {
    var out: [PSRow] = []
    for line in text.split(separator: "\n") {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count >= 3, let pid = Int32(f[0]) else { continue }
        let cpu = parseCpuTime(String(f[1]))
        let rss = (Double(f[2]) ?? 0) / 1024.0   // KB → MB
        out.append(PSRow(pid: pid, cpuSeconds: cpu, rssMB: rss))
    }
    return out
}

public final class CPUSampler {
    private var prevCPU: [Int32: UInt64] = [:]   // cumulative cpu-time ns per pid
    private var prevTime = Date()

    public init() {}

    /// Live: runs `ps`, returns instantaneous CPU% + RSS(MB) per requested pid.
    /// Sudoless and covers WindowServer (libproc rusage is permission-denied on it).
    public func sample(pids: [Int32]) -> [Int32: (cpu: Double, rss: Double)] {
        let rows = runPS()
        return sample(rows: rows, wanted: Set(pids), now: Date())
    }

    /// Pure core: compute deltas from parsed rows. Testable without spawning ps.
    func sample(rows: [PSRow], wanted: Set<Int32>, now: Date) -> [Int32: (cpu: Double, rss: Double)] {
        let elapsed = now.timeIntervalSince(prevTime)
        var out: [Int32: (Double, Double)] = [:]
        var nextPrev: [Int32: UInt64] = [:]
        for r in rows {
            let cpuNs = UInt64(r.cpuSeconds * 1_000_000_000.0)
            nextPrev[r.pid] = cpuNs
            guard wanted.isEmpty || wanted.contains(r.pid) else { continue }
            if let p = prevCPU[r.pid] {
                out[r.pid] = (cpuPercent(prevNs: p, curNs: cpuNs, elapsed: elapsed), r.rssMB)
            } else {
                out[r.pid] = (0, r.rssMB)   // first observation: no delta yet
            }
        }
        prevCPU = nextPrev
        prevTime = now
        return out
    }

    private func runPS() -> [PSRow] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axro", "pid=,cputime=,rss="]
        let pipe = Pipe(); p.standardOutput = pipe
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parsePSRows(String(data: data, encoding: .utf8) ?? "")
    }
}

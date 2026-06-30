import Foundation

public func pearson(_ a: [Double], _ b: [Double]) -> Double {
    let n = min(a.count, b.count)
    guard n >= 2 else { return 0 }
    let ax = Array(a.suffix(n)), bx = Array(b.suffix(n))
    let ma = ax.reduce(0,+) / Double(n), mb = bx.reduce(0,+) / Double(n)
    var num = 0.0, da = 0.0, db = 0.0
    for i in 0..<n {
        let xa = ax[i] - ma, xb = bx[i] - mb
        num += xa * xb; da += xa * xa; db += xb * xb
    }
    let den = (da * db).squareRoot()
    return den == 0 ? 0 : num / den
}

public final class Correlator {
    private let window: Int
    private var wsSeries: [Double] = []
    private var appSeries: [String: [Double]] = [:]
    public init(window: Int = 60) { self.window = window }

    public func record(_ snap: Snapshot) {
        // WS signal = max(wsCPU, gpuUtil) so either kind of spike drives correlation.
        let wsSignal = max(snap.wsCPU, snap.gpu.utilization ?? 0)
        append(&wsSeries, wsSignal)
        let names = Set(snap.apps.map { $0.name })
        for app in snap.apps { append(&appSeries[app.name, default: []], app.cpu) }
        // keep absent apps aligned by padding with 0
        for (name, _) in appSeries where !names.contains(name) {
            append(&appSeries[name, default: []], 0)
        }
    }

    private func append(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > window { arr.removeFirst(arr.count - window) }
    }

    public func ranking() -> [(name: String, score: Double)] {
        appSeries.map { ($0.key, pearson(wsSeries, $0.value)) }
                 .sorted { $0.1 > $1.1 }
                 .map { (name: $0.0, score: $0.1) }
    }
}

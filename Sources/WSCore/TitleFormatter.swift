import Foundation

public func formatTitle(wsCPU: Double, gpu: Double?, top: String?) -> String {
    let g = gpu.map { String(Int($0.rounded())) } ?? "—"
    return "WS \(Int(wsCPU.rounded()))% · GPU \(g)% · \(top ?? "…")"
}

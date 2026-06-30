import Foundation

public struct PMProcess: Equatable {
    public var name: String
    public var pid: Int32
    public var gpuMsPerS: Double?
    public var energyImpact: Double?
    public init(name: String, pid: Int32, gpuMsPerS: Double?, energyImpact: Double?) {
        self.name = name; self.pid = pid; self.gpuMsPerS = gpuMsPerS; self.energyImpact = energyImpact
    }
}

private struct Tok { let text: String; let start: Int; let end: Int }

private func tokens(_ line: String) -> [Tok] {
    var out: [Tok] = []
    var i = 0, startIdx = -1
    var cur = ""
    for ch in line {
        if ch == " " || ch == "\t" {
            if startIdx >= 0 { out.append(Tok(text: cur, start: startIdx, end: i)); cur = ""; startIdx = -1 }
        } else {
            if startIdx < 0 { startIdx = i }
            cur.append(ch)
        }
        i += 1
    }
    if startIdx >= 0 { out.append(Tok(text: cur, start: startIdx, end: i)) }
    return out
}

private func headerCenter(_ header: String, _ key: String) -> Int? {
    guard let r = header.range(of: key) else { return nil }
    let s = header.distance(from: header.startIndex, to: r.lowerBound)
    let e = header.distance(from: header.startIndex, to: r.upperBound)
    return (s + e) / 2
}

/// Parses a powermetrics `--samplers tasks --show-process-gpu --show-process-energy`
/// table. Columns are whitespace-aligned under their headers; values are matched
/// to the column whose header center is nearest the token's center.
public func parsePowerMetrics(_ text: String) -> [PMProcess] {
    let lines = text.components(separatedBy: "\n")
    guard let hIdx = lines.firstIndex(where: {
        $0.contains("Name") && ($0.contains("ID") || $0.contains("PID"))
    }) else { return [] }
    let header = lines[hIdx]
    let gpuC = headerCenter(header, "GPU ms/s")
    let energyC = headerCenter(header, "Energy Impact") ?? headerCenter(header, "Energy")

    func valueNear(_ toks: [Tok], _ center: Int?) -> Double? {
        guard let c = center else { return nil }
        let numeric = toks.filter { Double($0.text) != nil }
        let best = numeric.min { abs(($0.start + $0.end) / 2 - c) < abs(($1.start + $1.end) / 2 - c) }
        return best.flatMap { Double($0.text) }
    }

    var out: [PMProcess] = []
    for raw in lines[(hIdx + 1)...] {
        let line = raw
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("*") || t.hasPrefix("-") || t.hasPrefix("ALL_TASKS") { continue }
        let toks = tokens(line)
        guard let idTok = toks.first(where: { Int32($0.text) != nil }) else { continue }
        let pid = Int32(idTok.text) ?? -1
        let name = toks.prefix { $0.start < idTok.start }.map { $0.text }.joined(separator: " ")
        if name.isEmpty { continue }
        out.append(PMProcess(name: name, pid: pid,
                             gpuMsPerS: valueNear(toks, gpuC),
                             energyImpact: valueNear(toks, energyC)))
    }
    return out
}

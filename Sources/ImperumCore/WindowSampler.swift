import Foundation
import CoreGraphics

public struct RawWindow {
    public var pid: Int32
    public var owner: String
    public var layer: Int
    public var width: Double
    public var height: Double
    public var displayID: UInt32
    public init(pid: Int32, owner: String, layer: Int, width: Double, height: Double, displayID: UInt32) {
        self.pid = pid; self.owner = owner; self.layer = layer
        self.width = width; self.height = height; self.displayID = displayID
    }
}

public struct WinAgg: Equatable {
    public var name: String
    public var windows: Int
    public var area: Int
    public var perDisplay: [UInt32: Int]
    public init(name: String, windows: Int, area: Int, perDisplay: [UInt32: Int]) {
        self.name = name; self.windows = windows; self.area = area; self.perDisplay = perDisplay
    }
}

public let kMinWindowArea = 5000

public func aggregate(windows: [RawWindow]) -> [Int32: WinAgg] {
    var out: [Int32: WinAgg] = [:]
    for w in windows {
        guard w.layer == 0 else { continue }
        let a = Int(w.width * w.height)
        guard a >= kMinWindowArea else { continue }
        var e = out[w.pid] ?? WinAgg(name: w.owner, windows: 0, area: 0, perDisplay: [:])
        e.windows += 1
        e.area += a
        e.perDisplay[w.displayID, default: 0] += a
        out[w.pid] = e
    }
    return out
}

public func sampleWindows() -> [Int32: WinAgg] {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let infos = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [:] }
    var raws: [RawWindow] = []
    for info in infos {
        guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
              let owner = info[kCGWindowOwnerName as String] as? String else { continue }
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        let bounds = info[kCGWindowBounds as String] as? [String: Any]
        let width = bounds?["Width"] as? Double ?? 0
        let height = bounds?["Height"] as? Double ?? 0
        let display = displayID(forBounds: bounds)
        raws.append(RawWindow(pid: pid, owner: owner, layer: layer, width: width, height: height, displayID: display))
    }
    return aggregate(windows: raws)
}

private func displayID(forBounds bounds: [String: Any]?) -> UInt32 {
    guard let b = bounds,
          let x = b["X"] as? Double, let y = b["Y"] as? Double else {
        return CGMainDisplayID()
    }
    let pt = CGPoint(x: x + 1, y: y + 1)
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var count: UInt32 = 0
    if CGGetDisplaysWithPoint(pt, 8, &ids, &count) == .success, count > 0 { return ids[0] }
    return CGMainDisplayID()
}

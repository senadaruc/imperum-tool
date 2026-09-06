import Foundation
import CoreGraphics

public struct DisplayInfo: Equatable {
    public var displayID: UInt32
    public var isMain: Bool
    public var pointW: Int       // "looks like" logical resolution
    public var pointH: Int
    public var pixelW: Int       // actual rendered (backing) pixels
    public var pixelH: Int
    public var refresh: Double    // Hz, 0 if the driver doesn't report it
    public init(displayID: UInt32, isMain: Bool, pointW: Int, pointH: Int,
                pixelW: Int, pixelH: Int, refresh: Double) {
        self.displayID = displayID; self.isMain = isMain
        self.pointW = pointW; self.pointH = pointH
        self.pixelW = pixelW; self.pixelH = pixelH; self.refresh = refresh
    }

    /// Megapixels rendered per frame.
    public var megapixels: Double { Double(pixelW * pixelH) / 1_000_000 }
    /// Per-second compositing cost = rendered pixels × refresh (assume 60 if unknown).
    public var pixelsPerSecond: Double { displayGpxPerSec(pixelW: pixelW, pixelH: pixelH, refresh: refresh) }
    /// True when the backing store is larger than a clean 2× of the logical size
    /// (fractional HiDPI scaling — renders an oversized buffer then downscales).
    public var isScaled: Bool { pixelW != pointW && pixelW != pointW * 2 }
}

/// Rendered pixels per second. Refresh 0 (unknown) is treated as 60.
public func displayGpxPerSec(pixelW: Int, pixelH: Int, refresh: Double) -> Double {
    Double(pixelW * pixelH) * (refresh > 0 ? refresh : 60)
}

/// All active displays via CoreGraphics. Sudoless, fast.
public func sampleDisplays() -> [DisplayInfo] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    let main = CGMainDisplayID()
    var out: [DisplayInfo] = []
    for id in ids {
        guard let mode = CGDisplayCopyDisplayMode(id) else { continue }
        out.append(DisplayInfo(
            displayID: id,
            isMain: id == main,
            pointW: mode.width, pointH: mode.height,
            pixelW: mode.pixelWidth, pixelH: mode.pixelHeight,
            refresh: mode.refreshRate))
    }
    // Main display first, then by descending compositing cost.
    return out.sorted { ($0.isMain ? 1 : 0, $0.pixelsPerSecond) > ($1.isMain ? 1 : 0, $1.pixelsPerSecond) }
}

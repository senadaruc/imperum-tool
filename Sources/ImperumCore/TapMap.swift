import Combine
import Foundation

public struct TapSlot: Codable, Hashable, CaseIterable {
    public var side: TapSide
    public var count: Int
    public init(_ side: TapSide, _ count: Int) { self.side = side; self.count = count }

    public static var allCases: [TapSlot] {
        TapSide.allCases.flatMap { side in (1...3).map { TapSlot(side, $0) } }
    }
    public var key: String { "\(side.rawValue)\(count)" }
    public var title: String { count == 1 ? "1 tap" : "\(count) taps" }
}

/// The six-slot map. Stored as a string-keyed dictionary so JSON stays
/// readable (`"left2": {...}`) and missing slots default to "Do nothing".
public struct TapMap: Codable, Equatable {
    public var slots: [String: TapAction]
    public init(slots: [String: TapAction] = [:]) { self.slots = slots }

    public subscript(slot: TapSlot) -> TapAction {
        get { slots[slot.key] ?? TapAction(.none) }
        set { slots[slot.key] = newValue }
    }
    public func action(side: TapSide, count: Int) -> TapAction { self[TapSlot(side, count)] }

    /// The product-page defaults. "Apple Shortcuts" on RIGHT ×1 is a
    /// Run Shortcut… slot the user fills in.
    public static let productDefault = TapMap(slots: [
        "left1": TapAction(.muteSound),
        "left2": TapAction(.screenshotClipboard),
        "left3": TapAction(.flashlight),
        "right1": TapAction(.runShortcut),
        "right2": TapAction(.playPause),
        "right3": TapAction(.nextTrack),
    ])
}

public struct TapSettings: Codable, Equatable {
    public var enabled: Bool
    public var threshold: Double
    public var map: TapMap
    public var calibration: SideCalibration?
    public init(enabled: Bool = false, threshold: Double = TapDetectorConfig.defaultThreshold,
                map: TapMap = .productDefault, calibration: SideCalibration? = nil) {
        self.enabled = enabled; self.threshold = threshold; self.map = map; self.calibration = calibration
    }
}

/// UserDefaults-backed persistence for tap gestures, injected `defaults`
/// so tests use an isolated suite (same pattern as `VolumeBlockStore`).
public final class TapSettingsStore: ObservableObject {
    @Published public var settings: TapSettings {
        didSet { save() }
    }
    private let defaults: UserDefaults
    private static let key = "imperumTool_tapGestures_v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(TapSettings.self, from: data) {
            settings = decoded
        } else {
            settings = TapSettings()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

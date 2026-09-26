import Combine
import Foundation

public enum ClipboardTrigger: String, Codable, CaseIterable {
    case doubleTap, hotkey, both
    public var usesDoubleTap: Bool { self != .hotkey }
    public var usesHotkey: Bool { self != .doubleTap }
}

/// All user-facing clipboard preferences. Values are clamped on set so the
/// UI, the archive and old JSON can never push the app outside the spec ranges.
public struct ClipboardSettings: Codable, Equatable {
    public static let defaultExcluded = ["com.1password.1password", "com.agilebits.onepassword7",
                                         "com.bitwarden.desktop", "com.apple.keychainaccess"]

    public var enabled = true
    public var trigger: ClipboardTrigger = .doubleTap
    public var doubleTapMs = 300 { didSet { doubleTapMs = min(400, max(200, doubleTapMs)) } }
    public var maxStack = 500 { didSet { maxStack = min(2000, max(20, maxStack)) } }
    public var retentionDays = 30 { didSet { retentionDays = min(365, max(1, retentionDays)) } }
    public var clearOnQuit = false
    public var showBadge = true
    public var showFavicons = false
    public var excludedBundleIDs: [String] = ClipboardSettings.defaultExcluded
    public var paused = false

    public init() {}

    public var limits: ClipLimits { ClipLimits(maxStack: maxStack, retentionDays: retentionDays) }
    public var doubleTapWindow: TimeInterval { TimeInterval(doubleTapMs) / 1000 }

    private enum CodingKeys: String, CodingKey {
        case enabled, trigger, doubleTapMs, maxStack, retentionDays, clearOnQuit, showBadge, showFavicons, excludedBundleIDs, paused
    }

    /// Forward-compatible: keys absent from older saved JSON keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = ClipboardSettings()
        s.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? s.enabled
        s.trigger = try c.decodeIfPresent(ClipboardTrigger.self, forKey: .trigger) ?? s.trigger
        s.doubleTapMs = try c.decodeIfPresent(Int.self, forKey: .doubleTapMs) ?? s.doubleTapMs
        s.maxStack = try c.decodeIfPresent(Int.self, forKey: .maxStack) ?? s.maxStack
        s.retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? s.retentionDays
        s.clearOnQuit = try c.decodeIfPresent(Bool.self, forKey: .clearOnQuit) ?? s.clearOnQuit
        s.showBadge = try c.decodeIfPresent(Bool.self, forKey: .showBadge) ?? s.showBadge
        s.showFavicons = try c.decodeIfPresent(Bool.self, forKey: .showFavicons) ?? s.showFavicons
        s.excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? s.excludedBundleIDs
        s.paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? s.paused
        self = s
    }
}

/// UserDefaults-backed, injected so tests use an isolated suite (same pattern as `TapSettingsStore`).
public final class ClipboardSettingsStore: ObservableObject {
    @Published public var settings: ClipboardSettings { didSet { save() } }
    private let defaults: UserDefaults
    private static let key = "imperumTool_clipboard_v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(ClipboardSettings.self, from: data) {
            settings = decoded
        } else {
            settings = ClipboardSettings()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

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
    /// Optional cap per category, keyed by `ClipCategory.rawValue` (never
    /// "all"). Absent = no cap for that category. Values clamp to
    /// `categoryLimitRange`; unknown keys are dropped.
    public var categoryLimits: [String: Int] = [:] { didSet { categoryLimits = Self.sanitizedCategoryLimits(categoryLimits) } }
    public static let categoryLimitRange = 10...2000
    public static let categoryLimitDefault = 100

    static func sanitizedCategoryLimits(_ raw: [String: Int]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (key, value) in raw {
            guard let c = ClipCategory(rawValue: key), c != .all else { continue }
            out[key] = min(categoryLimitRange.upperBound, max(categoryLimitRange.lowerBound, value))
        }
        return out
    }
    public var clearOnQuit = false
    public var showBadge = true
    public var showFavicons = false
    public var excludedBundleIDs: [String] = ClipboardSettings.defaultExcluded
    /// Normalised bare hostnames (see `HostExclusion.normalize`); each entry
    /// matches the site and all its subdomains.
    public var excludedHosts: [String] = []
    public var paused = false
    public var terminalPicker = true
    public var allowCLI = true
    /// Passed to the cmux CLI as `CMUX_SOCKET_PASSWORD` when non-empty.
    public var cmuxSocketPassword = ""
    /// Key map for the panel and its global hotkey (see `PanelShortcuts`).
    public var shortcuts: PanelShortcuts = .defaults
    /// Watch the macOS and CleanShot X screenshot folders and import new
    /// screenshot files as clips. Copied screenshots are captured regardless.
    public var captureScreenshotFiles = true
    /// Open the Copy Stack as a compact bubble at the text caret of the
    /// focused field (read through Accessibility) instead of centred on
    /// screen. Falls back to centred whenever no caret can be found.
    public var anchorToCaret = true

    public init() {}

    public var limits: ClipLimits {
        var per: [ClipCategory: Int] = [:]
        for (key, value) in categoryLimits { if let c = ClipCategory(rawValue: key) { per[c] = value } }
        return ClipLimits(maxStack: maxStack, retentionDays: retentionDays, perCategory: per)
    }
    public var doubleTapWindow: TimeInterval { TimeInterval(doubleTapMs) / 1000 }

    private enum CodingKeys: String, CodingKey {
        case enabled, trigger, doubleTapMs, maxStack, retentionDays, categoryLimits, clearOnQuit, showBadge, showFavicons, excludedBundleIDs, excludedHosts, paused, terminalPicker, allowCLI, cmuxSocketPassword, shortcuts, captureScreenshotFiles, anchorToCaret
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
        s.categoryLimits = try c.decodeIfPresent([String: Int].self, forKey: .categoryLimits) ?? [:]
        s.clearOnQuit = try c.decodeIfPresent(Bool.self, forKey: .clearOnQuit) ?? s.clearOnQuit
        s.showBadge = try c.decodeIfPresent(Bool.self, forKey: .showBadge) ?? s.showBadge
        s.showFavicons = try c.decodeIfPresent(Bool.self, forKey: .showFavicons) ?? s.showFavicons
        s.excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? s.excludedBundleIDs
        s.excludedHosts = try c.decodeIfPresent([String].self, forKey: .excludedHosts) ?? s.excludedHosts
        s.paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? s.paused
        s.terminalPicker = try c.decodeIfPresent(Bool.self, forKey: .terminalPicker) ?? s.terminalPicker
        s.allowCLI = try c.decodeIfPresent(Bool.self, forKey: .allowCLI) ?? s.allowCLI
        s.cmuxSocketPassword = try c.decodeIfPresent(String.self, forKey: .cmuxSocketPassword) ?? s.cmuxSocketPassword
        // PanelShortcuts decodes leniently on its own; this guards the case
        // where the value isn't even an object.
        let decodedShortcuts: PanelShortcuts? = (try? c.decodeIfPresent(PanelShortcuts.self, forKey: .shortcuts)) ?? nil
        s.shortcuts = decodedShortcuts ?? .defaults
        s.captureScreenshotFiles = try c.decodeIfPresent(Bool.self, forKey: .captureScreenshotFiles) ?? s.captureScreenshotFiles
        s.anchorToCaret = try c.decodeIfPresent(Bool.self, forKey: .anchorToCaret) ?? s.anchorToCaret
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

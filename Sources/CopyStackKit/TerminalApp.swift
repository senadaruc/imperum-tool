import Foundation

/// Terminal applications the copystack picker knows how to talk to.
public enum TerminalApp: String, CaseIterable, Codable {
    case ghostty, cmux, iterm2, kitty, terminal, warp

    public var bundleIDPrefixes: [String] {
        switch self {
        case .ghostty: return ["com.mitchellh.ghostty"]
        case .cmux: return ["com.cmuxterm.app"]
        case .iterm2: return ["com.googlecode.iterm2"]
        case .kitty: return ["net.kovidgoyal.kitty"]
        case .terminal: return ["com.apple.Terminal"]
        case .warp: return ["dev.warp.Warp"]
        }
    }

    public var displayName: String {
        switch self {
        case .ghostty: return "Ghostty"
        case .cmux: return "cmux"
        case .iterm2: return "iTerm2"
        case .kitty: return "Kitty"
        case .terminal: return "Terminal"
        case .warp: return "Warp"
        }
    }

    /// Warp has no scriptable window/session picker.
    public var supportsPicker: Bool { self != .warp }

    /// Matches `bundleID` exactly, or as a prefix followed by a `.` or `-`
    /// boundary (so `com.cmuxterm.app.debug.imperum` and `dev.warp.Warp-Stable`
    /// both match), but never a bare substring like `com.mitchellh.ghosttyx`.
    public static func detect(bundleID: String?) -> TerminalApp? {
        guard let bundleID else { return nil }
        for app in allCases {
            for prefix in app.bundleIDPrefixes {
                if bundleID == prefix { return app }
                if bundleID.hasPrefix(prefix) {
                    let boundaryIndex = bundleID.index(bundleID.startIndex, offsetBy: prefix.count)
                    let boundary = bundleID[boundaryIndex]
                    if boundary == "." || boundary == "-" { return app }
                }
            }
        }
        return nil
    }
}

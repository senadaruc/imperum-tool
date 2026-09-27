import Foundation

/// Everything the Copy Stack panel and its global hotkey can be bound to.
/// Order matters: on a tie between two in-panel bindings, the earlier case
/// wins (see `PanelShortcuts.action(keyCode:modifiers:)`).
public enum PanelAction: String, Codable, CaseIterable {
    case openPanel
    case up, down, previousCategory, nextCategory
    case paste, pin, delete, close

    public var title: String {
        switch self {
        case .openPanel: return "Open the copy stack"
        case .up: return "Move up"
        case .down: return "Move down"
        case .previousCategory: return "Previous category"
        case .nextCategory: return "Next category"
        case .paste: return "Paste"
        case .pin: return "Pin"
        case .delete: return "Delete"
        case .close: return "Close"
        }
    }

    /// The actions the panel's key monitor dispatches (all but the hotkey).
    public static let inPanel: [PanelAction] = allCases.filter { $0 != .openPanel }
}

public enum ShortcutProblem: Equatable {
    /// `openPanel` needs ⌘, ⌃ or ⌥, or an F-key: a bare key can't be a system-wide hotkey.
    case hotkeyNeedsModifier
    /// An in-panel binding on a bare printable key would make that key untypeable in search.
    case printableNeedsModifier

    public var message: String {
        switch self {
        case .hotkeyNeedsModifier: return "Use ⌘, ⌃ or ⌥, or a function key"
        case .printableNeedsModifier: return "Add ⌘, ⌃ or ⌥ so typing in search still works"
        }
    }
}

/// The user's key map for the Copy Stack. Modifiers are raw
/// `NSEvent.ModifierFlags` bits, masked to ⌘ ⇧ ⌥ ⌃ on the way in, so arrow
/// keys (which carry `.function` + `.numericPad` on their own) and F-keys
/// match a binding recorded without noise. Pure: no AppKit.
public struct PanelShortcuts: Codable, Equatable {
    public static let command: UInt = 1 << 20
    public static let shift: UInt = 1 << 17
    public static let option: UInt = 1 << 19
    public static let control: UInt = 1 << 18
    private static let kept: UInt = command | shift | option | control
    /// ⇧ alone doesn't count: ⇧P still types a P.
    private static let realModifiers: UInt = command | option | control

    public static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,   // F1–F12
                                                        105, 107, 113, 106, 64, 79, 80]                            // F13–F19
    /// Keys that never type a character into the search field.
    public static let nonPrintingKeyCodes: Set<UInt16> = functionKeyCodes.union(
        [36, 76, 48, 51, 117, 53, 115, 119, 116, 121, 123, 124, 125, 126])   // ↩ ⌤ ⇥ ⌫ ⌦ ⎋ Home End PgUp PgDn ← → ↓ ↑
    /// Virtual key codes of the digit row 1–9. Quick pick is resolved by key
    /// code, not by the typed character: ⇧ changes what "2" types ("@") and
    /// non-QWERTY layouts type symbols on that row unshifted.
    public static let digitKeyCodes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    public private(set) var bindings: [PanelAction: KeyCombo]
    /// Held with a digit 1–9 to paste that row. The digits are fixed.
    public var quickPickModifiers: UInt { didSet { quickPickModifiers = Self.normalize(quickPickModifiers) } }

    public static let defaults = PanelShortcuts(bindings: [
        .openPanel: KeyCombo(keyCode: 9, modifiers: command | shift, display: "⌘⇧V"),
        .up: KeyCombo(keyCode: 126, modifiers: 0, display: "↑"),
        .down: KeyCombo(keyCode: 125, modifiers: 0, display: "↓"),
        .previousCategory: KeyCombo(keyCode: 123, modifiers: 0, display: "←"),
        .nextCategory: KeyCombo(keyCode: 124, modifiers: 0, display: "→"),
        .paste: KeyCombo(keyCode: 36, modifiers: 0, display: "↩"),
        .pin: KeyCombo(keyCode: 35, modifiers: command, display: "⌘P"),
        .delete: KeyCombo(keyCode: 51, modifiers: 0, display: "⌫"),
        .close: KeyCombo(keyCode: 53, modifiers: 0, display: "⎋"),
    ], quickPickModifiers: command)

    public init(bindings: [PanelAction: KeyCombo], quickPickModifiers: UInt) {
        self.bindings = bindings.mapValues(Self.normalized)
        self.quickPickModifiers = Self.normalize(quickPickModifiers)
    }

    public static func normalize(_ modifiers: UInt) -> UInt { modifiers & kept }
    private static func normalized(_ c: KeyCombo) -> KeyCombo {
        KeyCombo(keyCode: c.keyCode, modifiers: normalize(c.modifiers), display: c.display)
    }

    public func combo(for action: PanelAction) -> KeyCombo { bindings[action] ?? Self.defaults.bindings[action]! }

    /// Stores `combo` (modifiers normalised). Does not validate — callers
    /// run `problem(with:for:)` first and refuse to store on a problem.
    public mutating func set(_ combo: KeyCombo, for action: PanelAction) { bindings[action] = Self.normalized(combo) }

    /// The in-panel action bound to this key, if any. `.openPanel` is never
    /// returned: the hotkey is the Carbon layer's job.
    public func action(keyCode: UInt16, modifiers: UInt) -> PanelAction? {
        let m = Self.normalize(modifiers)
        return PanelAction.inPanel.first { let c = combo(for: $0); return c.keyCode == keyCode && c.modifiers == m }
    }

    public static func problem(with combo: KeyCombo, for action: PanelAction) -> ShortcutProblem? {
        let hasReal = normalize(combo.modifiers) & realModifiers != 0
        if action == .openPanel {
            return hasReal || functionKeyCodes.contains(combo.keyCode) ? nil : .hotkeyNeedsModifier
        }
        return hasReal || nonPrintingKeyCodes.contains(combo.keyCode) ? nil : .printableNeedsModifier
    }

    /// Titles of the other bindings sharing `action`'s combo, plus "Quick
    /// pick" when its key is a digit under `quickPickModifiers`. Empty = unique.
    public func conflicts(for action: PanelAction) -> [String] {
        let c = combo(for: action)
        var out = PanelAction.allCases
            .filter { $0 != action }
            .filter { let o = combo(for: $0); return o.keyCode == c.keyCode && o.modifiers == c.modifiers }
            .map(\.title)
        if Self.digitKeyCodes[c.keyCode] != nil, c.modifiers == quickPickModifiers { out.append("Quick pick") }
        return out
    }

    public var conflictingActions: Set<PanelAction> { Set(PanelAction.allCases.filter { !conflicts(for: $0).isEmpty }) }

    /// The row (1–9) a key event quick-picks, if its key is a digit and its
    /// normalised modifiers equal `quickPickModifiers` exactly.
    public func quickPickDigit(keyCode: UInt16, modifiers: UInt) -> Int? {
        guard Self.normalize(modifiers) == quickPickModifiers else { return nil }
        return Self.digitKeyCodes[keyCode]
    }

    /// Quick-pick modifiers need ⌘, ⌃ or ⌥: ⇧ alone would steal !…( from search.
    public static func quickPickProblem(modifiers: UInt) -> ShortcutProblem? {
        normalize(modifiers) & realModifiers != 0 ? nil : .printableNeedsModifier
    }

    /// True when Delete is a bare ⌫/⌦ and the search field has text: the key
    /// must edit the query, not delete the selected clip.
    public func deleteYieldsToSearchField(queryEmpty: Bool) -> Bool {
        let c = combo(for: .delete)
        return !queryEmpty && c.modifiers == 0 && (c.keyCode == 51 || c.keyCode == 117)
    }

    public static func modifierGlyphs(_ modifiers: UInt) -> String {
        let m = normalize(modifiers)
        var s = ""
        if m & control != 0 { s += "⌃" }
        if m & option != 0 { s += "⌥" }
        if m & shift != 0 { s += "⇧" }
        if m & command != 0 { s += "⌘" }
        return s
    }

    public var quickPickDisplay: String { Self.modifierGlyphs(quickPickModifiers) + "1–9" }

    /// nil on success. -9878 is Carbon's `eventHotKeyExistsErr`.
    public static func hotkeyRegistrationMessage(status: Int32) -> String? {
        switch status {
        case 0: return nil
        case -9878: return "Already used by another app"
        default: return "Could not register (error \(status))"
        }
    }

    // MARK: Codable (lenient)

    private enum CodingKeys: String, CodingKey { case bindings, quickPickModifiers }

    /// A dictionary entry that decodes to nil instead of failing the whole
    /// map, so one junk binding costs only that binding.
    private struct LenientCombo: Decodable {
        let combo: KeyCombo?
        init(from decoder: Decoder) throws { combo = try? KeyCombo(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = ((try? c.decodeIfPresent([String: LenientCombo].self, forKey: .bindings)) ?? nil) ?? [:]
        var b = Self.defaults.bindings
        for (key, entry) in raw {
            guard let a = PanelAction(rawValue: key), let combo = entry.combo,
                  Self.problem(with: combo, for: a) == nil else { continue }
            b[a] = combo
        }
        let q = ((try? c.decodeIfPresent(UInt.self, forKey: .quickPickModifiers)) ?? nil) ?? Self.command
        self.init(bindings: b, quickPickModifiers: Self.quickPickProblem(modifiers: q) == nil ? q : Self.command)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var raw: [String: KeyCombo] = [:]
        for (a, combo) in bindings { raw[a.rawValue] = combo }
        try c.encode(raw, forKey: .bindings)
        try c.encode(quickPickModifiers, forKey: .quickPickModifiers)
    }
}

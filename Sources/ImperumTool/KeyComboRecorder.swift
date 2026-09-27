import AppKit
import SwiftUI
import ImperumCore

/// Records one keyboard shortcut: click, press the keys, done; Esc cancels.
/// Shared by the Tap Gestures and Clipboard settings tabs.
struct KeyComboRecorder: View {
    let combo: KeyCombo?
    /// Drop the fn/🌐 bit so arrows and F-keys record cleanly. On for the
    /// Copy Stack (it compares ⌘⇧⌥⌃ only); off for Tap Gestures, which
    /// replays the recorded flags verbatim.
    var stripFunctionModifier = false
    /// Return a problem to reject the combo: it is then not stored and the
    /// message shows in orange until the next recording.
    var validate: ((KeyCombo) -> ShortcutProblem?)? = nil
    let update: (KeyCombo?) -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: ShortcutProblem?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 8) {
                Text(recording ? "Press the shortcut now… (Esc cancels)" : (combo?.display ?? "No shortcut recorded"))
                    .font(.caption).foregroundStyle(recording ? .primary : .secondary)
                    .frame(minWidth: 90, alignment: .leading)
                Button(recording ? "Cancel" : (combo == nil ? "Record…" : "Change…")) {
                    recording ? stop() : start()
                }.controlSize(.small)
            }
            if let problem { Text(problem.message).font(.caption).foregroundStyle(.orange) }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        problem = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            if ev.keyCode == 53 { stop(); return nil }
            var mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .help])
            if stripFunctionModifier { mods.subtract(.function) }
            let recorded = KeyCombo(keyCode: ev.keyCode, modifiers: mods.rawValue, display: Self.describe(ev, mods))
            if let p = validate?(recorded) { problem = p } else { update(recorded) }
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private static func describe(_ ev: NSEvent, _ mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.function) { s += "🌐" }
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        let special: [UInt16: String] = [49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
                                         115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
                                         123: "←", 124: "→", 125: "↓", 126: "↑",
                                         122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
                                         101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
                                         106: "F16", 64: "F17", 79: "F18", 80: "F19"]
        let key = special[ev.keyCode] ?? (ev.charactersIgnoringModifiers ?? "?").uppercased()
        return s + key
    }
}

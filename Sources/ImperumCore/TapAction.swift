import Foundation

public enum ActionCategory: String, Codable, CaseIterable {
    case screenshotsClipboard = "Screenshots & clipboard"
    case mediaVolume = "Media & volume"
    case inputDisplayFocus = "Input, display & focus"
    case customShortcuts = "Custom shortcuts"
    case windowWorkspace = "Window & workspace"
    case lockSleep = "Lock, sleep & screensaver"
    case connectivity = "Connectivity"
    case systemUtilities = "System status & utilities"
    case other = "Other"
}

/// A recorded keyboard shortcut. `keyCode` is the macOS virtual key code,
/// `modifiers` the raw `NSEvent.ModifierFlags` (device-independent bits).
public struct KeyCombo: Codable, Equatable, Hashable {
    public var keyCode: UInt16
    public var modifiers: UInt
    public var display: String
    public init(keyCode: UInt16, modifiers: UInt, display: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.display = display
    }
}

public struct TapAction: Codable, Equatable, Hashable {
    public enum Kind: String, Codable, CaseIterable {
        case none
        // Screenshots & clipboard
        case screenshotClipboard, screenshotDesktop, screenshotArea
        case copy, paste, pastePlain, undo, redo
        // Media & volume
        case muteSound, volumeUp, volumeDown, playPause, nextTrack, previousTrack
        // Input, display & focus
        case muteMic, brightnessUp, brightnessDown, keyboardBacklightUp, keyboardBacklightDown, toggleFocus
        // Custom shortcuts
        case pressShortcut, openApplication, openURL, runShortcut
        // Window & workspace
        case missionControl, spotlight, quickNote, minimizeWindow, closeWindow
        case windowLeftHalf, windowRightHalf, maximizeWindow, toggleFullScreen
        case hideFrontApp, hideOtherApps, previousSpace, nextSpace
        case switchToPreviousApp, appSwitcherStep, quitFrontApp
        // Lock, sleep & screensaver
        case lockScreen, startScreenSaver, sleepDisplay
        // Connectivity
        case toggleWiFi, toggleBluetooth, ejectExternalDisks
        // System status & utilities
        case emptyTrash, batteryStatus, newEmail, currentWeather
        // Other
        case flashlight

        public var category: ActionCategory {
            switch self {
            case .none, .flashlight: return .other
            case .screenshotClipboard, .screenshotDesktop, .screenshotArea,
                 .copy, .paste, .pastePlain, .undo, .redo: return .screenshotsClipboard
            case .muteSound, .volumeUp, .volumeDown, .playPause, .nextTrack, .previousTrack: return .mediaVolume
            case .muteMic, .brightnessUp, .brightnessDown, .keyboardBacklightUp, .keyboardBacklightDown, .toggleFocus:
                return .inputDisplayFocus
            case .pressShortcut, .openApplication, .openURL, .runShortcut: return .customShortcuts
            case .missionControl, .spotlight, .quickNote, .minimizeWindow, .closeWindow,
                 .windowLeftHalf, .windowRightHalf, .maximizeWindow, .toggleFullScreen,
                 .hideFrontApp, .hideOtherApps, .previousSpace, .nextSpace,
                 .switchToPreviousApp, .appSwitcherStep, .quitFrontApp: return .windowWorkspace
            case .lockScreen, .startScreenSaver, .sleepDisplay: return .lockSleep
            case .toggleWiFi, .toggleBluetooth, .ejectExternalDisks: return .connectivity
            case .emptyTrash, .batteryStatus, .newEmail, .currentWeather: return .systemUtilities
            }
        }

        public var displayName: String {
            switch self {
            case .none: return "Do nothing"
            case .screenshotClipboard: return "Screenshot → Clipboard"
            case .screenshotDesktop: return "Screenshot → Desktop"
            case .screenshotArea: return "Screenshot (select area)"
            case .copy: return "Copy (⌘C)"
            case .paste: return "Paste (⌘V)"
            case .pastePlain: return "Paste without formatting"
            case .undo: return "Undo (⌘Z)"
            case .redo: return "Redo (⇧⌘Z)"
            case .muteSound: return "Mute / unmute sound"
            case .volumeUp: return "Volume up"
            case .volumeDown: return "Volume down"
            case .playPause: return "Play / Pause"
            case .nextTrack: return "Next track"
            case .previousTrack: return "Previous track"
            case .muteMic: return "Mute / unmute microphone"
            case .brightnessUp: return "Brightness up"
            case .brightnessDown: return "Brightness down"
            case .keyboardBacklightUp: return "Keyboard backlight up"
            case .keyboardBacklightDown: return "Keyboard backlight down"
            case .toggleFocus: return "Toggle Focus…"
            case .pressShortcut: return "Press keyboard shortcut…"
            case .openApplication: return "Open application…"
            case .openURL: return "Open URL…"
            case .runShortcut: return "Run Shortcut…"
            case .missionControl: return "Mission Control"
            case .spotlight: return "Spotlight search"
            case .quickNote: return "Quick Note"
            case .minimizeWindow: return "Minimize front window"
            case .closeWindow: return "Close front window"
            case .windowLeftHalf: return "Window → left half"
            case .windowRightHalf: return "Window → right half"
            case .maximizeWindow: return "Maximize window"
            case .toggleFullScreen: return "Toggle full screen"
            case .hideFrontApp: return "Hide front app"
            case .hideOtherApps: return "Hide other apps"
            case .previousSpace: return "Previous Space"
            case .nextSpace: return "Next Space"
            case .switchToPreviousApp: return "Switch to previous app"
            case .appSwitcherStep: return "App switcher (tap to step)"
            case .quitFrontApp: return "Quit front app"
            case .lockScreen: return "Lock screen"
            case .startScreenSaver: return "Start screen saver"
            case .sleepDisplay: return "Sleep display"
            case .toggleWiFi: return "Wi-Fi on / off"
            case .toggleBluetooth: return "Bluetooth on / off"
            case .ejectExternalDisks: return "Eject external disks"
            case .emptyTrash: return "Empty Trash"
            case .batteryStatus: return "Battery status"
            case .newEmail: return "New email"
            case .currentWeather: return "Current weather"
            case .flashlight: return "Flashlight"
            }
        }

        /// What the settings UI must collect for this action.
        public enum Parameter { case none, keyCombo, applicationPath, url, shortcutName }
        public var parameter: Parameter {
            switch self {
            case .pressShortcut: return .keyCombo
            case .openApplication: return .applicationPath
            case .openURL: return .url
            case .runShortcut, .toggleFocus: return .shortcutName
            default: return .none
            }
        }

        public static func inCategory(_ c: ActionCategory) -> [Kind] { allCases.filter { $0.category == c } }
    }

    public var kind: Kind
    /// Free-text parameter: application path, URL, or Shortcut name.
    public var text: String
    public var keyCombo: KeyCombo?

    public init(_ kind: Kind, text: String = "", keyCombo: KeyCombo? = nil) {
        self.kind = kind; self.text = text; self.keyCombo = keyCombo
    }

    /// Human-readable summary incl. the parameter, for the tap map rows.
    public var summary: String {
        switch kind.parameter {
        case .none: return kind.displayName
        case .keyCombo: return keyCombo.map { "Press \($0.display)" } ?? "Press keyboard shortcut (not set)"
        case .applicationPath:
            let name = (text as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            return text.isEmpty ? "Open application (not set)" : "Open \(name)"
        case .url: return text.isEmpty ? "Open URL (not set)" : "Open \(text)"
        case .shortcutName:
            let verb = kind == .toggleFocus ? "Focus via Shortcut" : "Run Shortcut"
            return text.isEmpty ? "\(verb) (not set)" : "\(verb) “\(text)”"
        }
    }

    public var isConfigured: Bool {
        switch kind.parameter {
        case .none: return true
        case .keyCombo: return keyCombo != nil
        case .applicationPath, .url, .shortcutName: return !text.isEmpty
        }
    }
}

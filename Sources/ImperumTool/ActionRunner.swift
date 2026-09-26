import AppKit
import ApplicationServices
import CoreAudio
import CoreWLAN
import Foundation
import IOKit.ps
import ImperumCore

/// Executes a `TapAction`. Everything here is a thin wrapper over a public
/// macOS mechanism (CGEvent keystrokes, NX media keys, the Accessibility API
/// for window tiling, CoreWLAN, CoreAudio, NSWorkspace, `shortcuts run`),
/// except Bluetooth power, which has no public API and uses IOBluetooth's
/// private preference call.
final class ActionRunner {
    /// Set by `ClipboardController` at launch; nil until the clipboard subsystem exists.
    static var showCopyStack: (() -> Void)?

    private var savedMicVolume: Float32?
    private var switcherOpen = false
    private var switcherRelease: DispatchWorkItem?

    // MARK: Entry point

    func run(_ action: TapAction) {
        switch action.kind {
        case .none: break
        // Screenshots & clipboard — the system's own shortcuts, so no Screen Recording permission is needed.
        case .screenshotClipboard: pressKey(20, [.maskControl, .maskShift, .maskCommand])   // ⌃⇧⌘3
        case .screenshotDesktop: pressKey(20, [.maskShift, .maskCommand])                    // ⇧⌘3
        case .screenshotArea: pressKey(21, [.maskShift, .maskCommand])                       // ⇧⌘4
        case .copy: pressKey(8, .maskCommand)
        case .paste: pressKey(9, .maskCommand)
        case .pastePlain: pressKey(9, [.maskAlternate, .maskShift, .maskCommand])
        case .undo: pressKey(6, .maskCommand)
        case .redo: pressKey(6, [.maskShift, .maskCommand])
        case .showCopyStack:
            if let show = Self.showCopyStack { show() } else { notConfigured(action) }
        // Media & volume
        case .muteSound: mediaKey(7)
        case .volumeUp: mediaKey(0)
        case .volumeDown: mediaKey(1)
        case .playPause: mediaKey(16)
        case .nextTrack: mediaKey(17)
        case .previousTrack: mediaKey(18)
        // Input, display & focus
        case .muteMic: toggleMicMute()
        case .brightnessUp: mediaKey(2)
        case .brightnessDown: mediaKey(3)
        case .keyboardBacklightUp: mediaKey(21)
        case .keyboardBacklightDown: mediaKey(22)
        case .toggleFocus: runShortcut(action.text, label: "Focus")
        // Custom
        case .pressShortcut:
            guard let c = action.keyCombo else { return notConfigured(action) }
            pressKey(CGKeyCode(c.keyCode), CGEventFlags(rawValue: UInt64(c.modifiers)))
        case .openApplication:
            guard !action.text.isEmpty else { return notConfigured(action) }
            openApp(path: action.text)
        case .openURL:
            guard let u = URL(string: action.text), !action.text.isEmpty else { return notConfigured(action) }
            NSWorkspace.shared.open(u)
        case .runShortcut: runShortcut(action.text, label: "Shortcut")
        // Window & workspace
        case .missionControl: openApp(path: "/System/Applications/Mission Control.app")
        case .spotlight: pressKey(49, .maskCommand)
        case .quickNote: pressKey(12, .maskSecondaryFn)                                       // fn/Globe + Q
        case .minimizeWindow: pressKey(46, .maskCommand)
        case .closeWindow: pressKey(13, .maskCommand)
        case .windowLeftHalf: tileFrontWindow(.left)
        case .windowRightHalf: tileFrontWindow(.right)
        case .maximizeWindow: tileFrontWindow(.fill)
        case .toggleFullScreen: pressKey(3, [.maskControl, .maskCommand])
        case .hideFrontApp: pressKey(4, .maskCommand)
        case .hideOtherApps: pressKey(4, [.maskAlternate, .maskCommand])
        case .previousSpace: pressKey(123, .maskControl)
        case .nextSpace: pressKey(124, .maskControl)
        case .switchToPreviousApp: switchToPreviousApp()
        case .appSwitcherStep: appSwitcherStep()
        case .quitFrontApp: pressKey(12, .maskCommand)
        // Lock, sleep & screensaver
        case .lockScreen: pressKey(12, [.maskControl, .maskCommand])
        case .startScreenSaver: openApp(path: "/System/Library/CoreServices/ScreenSaverEngine.app")
        case .sleepDisplay: shell("/usr/bin/pmset", ["displaysleepnow"])
        // Connectivity
        case .toggleWiFi: toggleWiFi()
        case .toggleBluetooth: toggleBluetooth()
        case .ejectExternalDisks: ejectExternalDisks()
        // System status & utilities
        case .emptyTrash: emptyTrash()
        case .batteryStatus: batteryStatus()
        case .newEmail: NSWorkspace.shared.open(URL(string: "mailto:")!)
        case .currentWeather: openApp(path: "/System/Applications/Weather.app")
        case .flashlight: Flashlight.shared.toggle()
        }
    }

    private func notConfigured(_ a: TapAction) {
        HUD.shared.show("\(a.kind.displayName) is not configured — open Settings › Tap Gestures", symbol: "exclamationmark.triangle")
    }

    // MARK: Accessibility

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts once (macOS shows its own dialog) and returns whether we may post events.
    @discardableResult
    static func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let ok = AXIsProcessTrustedWithOptions(opts)
        if !ok { HUD.shared.show("Allow Imperum Tool in System Settings › Privacy › Accessibility", symbol: "lock.shield") }
        return ok
    }

    // MARK: Keystrokes

    func pressKey(_ code: CGKeyCode, _ flags: CGEventFlags) {
        guard Self.ensureAccessibility() else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else { return }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// NX system-defined key (volume, brightness, media, keyboard illumination).
    func mediaKey(_ key: Int32) {
        guard Self.ensureAccessibility() else { return }
        func post(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true); post(down: false)
    }

    private static let kVKCommand: CGKeyCode = 55, kVKTab: CGKeyCode = 48

    private func switchToPreviousApp() {
        guard Self.ensureAccessibility() else { return }
        holdCommand(true); pressKey(Self.kVKTab, .maskCommand); holdCommand(false)
    }

    /// Each tap steps the ⌘Tab switcher; ⌘ is released after 1.5 s idle.
    private func appSwitcherStep() {
        guard Self.ensureAccessibility() else { return }
        if !switcherOpen { holdCommand(true); switcherOpen = true }
        pressKey(Self.kVKTab, .maskCommand)
        switcherRelease?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.holdCommand(false); self?.switcherOpen = false }
        switcherRelease = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    private func holdCommand(_ down: Bool) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: Self.kVKCommand, keyDown: down) else { return }
        e.flags = down ? .maskCommand : []
        e.post(tap: .cghidEventTap)
    }

    // MARK: Window tiling (Accessibility API)

    private enum Tile { case left, right, fill }

    private func tileFrontWindow(_ tile: Tile) {
        guard Self.ensureAccessibility() else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return HUD.shared.show("No front app") }
        guard let window = AXWindow.focusedWindow(pid: app.processIdentifier) else {
            return HUD.shared.show("No front window", symbol: "macwindow")
        }

        // AX coordinates: origin top-left of the primary screen, y down.
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let pos = AXWindow.frame(of: window)?.origin ?? .zero
        let cocoaPoint = CGPoint(x: pos.x + 2, y: primaryH - pos.y - 2)
        let screen = NSScreen.screens.first { $0.frame.contains(cocoaPoint) } ?? NSScreen.main ?? NSScreen.screens[0]
        var target = screen.visibleFrame
        switch tile {
        case .left: target.size.width = floor(target.width / 2)
        case .right:
            let half = floor(target.width / 2)
            target.origin.x += target.width - half; target.size.width = half
        case .fill: break
        }
        let origin = CGPoint(x: target.origin.x, y: primaryH - target.origin.y - target.height)
        AXWindow.setFrame(window, CGRect(origin: origin, size: target.size))
    }

    // MARK: Processes / apps / URLs

    @discardableResult
    private func shell(_ path: String, _ args: [String], completion: ((Int32, String) -> Void)? = nil) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { NSLog("Imperum Tool: failed to run \(path): \(error)"); return false }
        if let completion {
            DispatchQueue.global(qos: .userInitiated).async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                DispatchQueue.main.async { completion(p.terminationStatus, text) }
            }
        }
        return true
    }

    private func openApp(path: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()) { _, err in
            if let err { HUD.shared.show("Couldn't open \((path as NSString).lastPathComponent): \(err.localizedDescription)", symbol: "exclamationmark.triangle") }
        }
    }

    private func runShortcut(_ name: String, label: String) {
        guard !name.isEmpty else {
            return HUD.shared.show("\(label): no Shortcut name set — open Settings › Tap Gestures", symbol: "exclamationmark.triangle")
        }
        shell("/usr/bin/shortcuts", ["run", name]) { status, text in
            if status != 0 {
                let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
                HUD.shared.show("Shortcut “\(name)” failed\(msg.isEmpty ? "" : ": \(msg.prefix(60))")", symbol: "exclamationmark.triangle")
            }
        }
    }

    /// Names from `shortcuts list`, for the settings picker.
    static func availableShortcuts(_ completion: @escaping ([String]) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["list"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        DispatchQueue.global(qos: .utility).async {
            do { try p.run() } catch { DispatchQueue.main.async { completion([]) }; return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let names = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            DispatchQueue.main.async { completion(names) }
        }
    }

    // MARK: Microphone

    private func toggleMicMute() {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != 0 else { return HUD.shared.show("No input device", symbol: "mic.slash") }

        // Prefer a real mute switch (main element, then channels 1/2).
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var m = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                               mScope: kAudioDevicePropertyScopeInput, mElement: element)
            guard AudioObjectHasProperty(dev, &m) else { continue }
            var muted: UInt32 = 0; var sz = UInt32(4)
            guard AudioObjectGetPropertyData(dev, &m, 0, nil, &sz, &muted) == noErr else { continue }
            var next: UInt32 = muted == 0 ? 1 : 0
            if AudioObjectSetPropertyData(dev, &m, 0, nil, 4, &next) == noErr {
                return HUD.shared.show(next == 1 ? "Microphone muted" : "Microphone on", symbol: next == 1 ? "mic.slash.fill" : "mic.fill")
            }
        }
        // Fallback: input volume 0 ↔ restore.
        var v = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                           mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var vol: Float32 = 0; var sz = UInt32(4)
        guard AudioObjectGetPropertyData(dev, &v, 0, nil, &sz, &vol) == noErr else {
            return HUD.shared.show("Microphone can't be muted on this device", symbol: "mic.slash")
        }
        var next: Float32
        if vol > 0 { savedMicVolume = vol; next = 0 } else { next = savedMicVolume ?? 1 }
        AudioObjectSetPropertyData(dev, &v, 0, nil, 4, &next)
        HUD.shared.show(next == 0 ? "Microphone muted" : "Microphone on", symbol: next == 0 ? "mic.slash.fill" : "mic.fill")
    }

    // MARK: Connectivity

    private func toggleWiFi() {
        guard let iface = CWWiFiClient.shared().interface() else { return HUD.shared.show("No Wi-Fi interface", symbol: "wifi.slash") }
        let on = iface.powerOn()
        do {
            try iface.setPower(!on)
            HUD.shared.show(on ? "Wi-Fi off" : "Wi-Fi on", symbol: on ? "wifi.slash" : "wifi")
        } catch {
            HUD.shared.show("Wi-Fi: \(error.localizedDescription)", symbol: "wifi.exclamationmark")
        }
    }

    private func toggleBluetooth() {
        typealias GetFn = @convention(c) () -> Int32
        typealias SetFn = @convention(c) (Int32) -> Void
        guard let h = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW),
              let g = dlsym(h, "IOBluetoothPreferenceGetControllerPowerState"),
              let s = dlsym(h, "IOBluetoothPreferenceSetControllerPowerState") else {
            return HUD.shared.show("Bluetooth control unavailable", symbol: "exclamationmark.triangle")
        }
        let get = unsafeBitCast(g, to: GetFn.self), set = unsafeBitCast(s, to: SetFn.self)
        let on = get() != 0
        set(on ? 0 : 1)
        HUD.shared.show(on ? "Bluetooth off" : "Bluetooth on", symbol: "wave.3.right")
    }

    private func ejectExternalDisks() {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeLocalizedNameKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var ejected = 0, failed: [String] = []
        for u in urls {
            guard let rv = try? u.resourceValues(forKeys: Set(keys)), rv.volumeIsInternal == false,
                  (rv.volumeIsRemovable ?? false) || (rv.volumeIsEjectable ?? false) else { continue }
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: u); ejected += 1 }
            catch { failed.append(rv.volumeLocalizedName ?? u.lastPathComponent) }
        }
        if !failed.isEmpty { HUD.shared.show("Couldn't eject \(failed.joined(separator: ", "))", symbol: "externaldrive.badge.xmark") }
        else if ejected == 0 { HUD.shared.show("No external disks to eject", symbol: "externaldrive") }
        else { HUD.shared.show("Ejected \(ejected) disk\(ejected == 1 ? "" : "s")", symbol: "externaldrive.badge.checkmark") }
    }

    // MARK: System

    private func emptyTrash() {
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&err)
        if let err { HUD.shared.show("Empty Trash: \((err[NSAppleScript.errorMessage] as? String) ?? "failed")", symbol: "trash") }
        else { HUD.shared.show("Trash emptied", symbol: "trash") }
    }

    private func batteryStatus() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let desc = IOPSGetPowerSourceDescription(info, first)?.takeUnretainedValue() as? [String: Any] else {
            return HUD.shared.show("No battery", symbol: "powerplug")
        }
        let cap = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let state = desc[kIOPSPowerSourceStateKey] as? String ?? ""
        let mins = desc[kIOPSTimeToEmptyKey] as? Int ?? -1
        var text = "Battery \(cap)%"
        if charging { text += " · charging" }
        else if state == kIOPSACPowerValue { text += " · on power" }
        else if mins > 0 { text += " · \(mins / 60)h \(mins % 60)m left" }
        HUD.shared.show(text, symbol: charging ? "battery.100.bolt" : cap < 20 ? "battery.25" : "battery.100")
    }
}

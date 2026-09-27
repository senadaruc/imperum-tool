// Sources/ImperumTool/CmdVTap.swift
import AppKit
import Carbon.HIToolbox
import ImperumCore

/// Owns the double-tap ⌘V event tap and/or the user's global hotkey
/// (`PanelShortcuts`, default ⌘⇧V) registered through Carbon. Every key
/// this app posts carries `marker` in the event's user-data so the tap passes
/// it through untouched (that includes the paste we post after a pick).
final class CmdVTap {
    static let marker: Int64 = 0xC0C0
    private static let vKey: CGKeyCode = 9

    var onOpenPanel: (() -> Void)?
    var window: TimeInterval = 0.3 { didSet { detector.window = window } }

    /// Why the last hotkey registration failed, nil when it succeeded or
    /// no hotkey was requested. Read by the controller after `start`.
    private(set) var hotkeyError: String?

    private var detector = DoubleTapDetector()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var holdTimer: DispatchWorkItem?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    // MARK: Lifecycle

    /// Returns false when the event tap was requested but could not be created
    /// (no Accessibility trust). The hotkey never needs Accessibility; if it
    /// can't be registered, `hotkeyError` says why and the tap still runs.
    @discardableResult
    func start(doubleTap: Bool, hotkey: KeyCombo?) -> Bool {
        stop()
        var ok = true
        if doubleTap { ok = installTap() }
        if let hotkey { installHotKey(hotkey) }
        return ok
    }

    func stop() {
        hotkeyError = nil
        holdTimer?.cancel(); holdTimer = nil
        detector = DoubleTapDetector(window: window)
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes); runLoopSource = nil }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); tap = nil }
        if let h = hotKeyRef { UnregisterEventHotKey(h); hotKeyRef = nil }
        if let h = hotKeyHandler { RemoveEventHandler(h); hotKeyHandler = nil }
    }

    // MARK: Posting

    static func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        }
    }

    // MARK: Event tap

    private func installTap() -> Bool {
        guard ActionRunner.ensureAccessibility() else { return false }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: CmdVTap.callback, userInfo: refcon) else { return false }
        tap = t
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<CmdVTap>.fromOpaque(refcon).takeUnretainedValue()
        return me.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return Unmanaged.passUnretained(event) }

        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let mods = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        let isCmdV = code == Self.vKey && mods == .maskCommand
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let input: DoubleTapDetector.Input = isCmdV ? .cmdV(at: CACurrentMediaTime(), isRepeat: isRepeat) : .other

        switch detector.feed(input) {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .hold:
            armTimer()
            return nil
        case .pasteNow:
            holdTimer?.cancel(); holdTimer = nil
            Self.postKey(Self.vKey, flags: .maskCommand)
            if isCmdV { return nil }
            // The triggering key (e.g. Enter) is already in flight past the HID insertion
            // point, so simply returning it would let it overtake the ⌘V we just queued
            // behind it. Swallow the original and re-post a marked copy so it lands after
            // the paste, preserving "⌘V then <key>" order.
            if let copy = event.copy() {
                copy.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                copy.post(tap: .cghidEventTap)
            }
            return nil
        case .openPanel:
            holdTimer?.cancel(); holdTimer = nil
            DispatchQueue.main.async { [weak self] in self?.onOpenPanel?() }
            return nil
        }
    }

    private func armTimer() {
        holdTimer?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.holdTimer = nil
            if self.detector.feed(.timerFired) == .pasteNow { Self.postKey(Self.vKey, flags: .maskCommand) }
        }
        holdTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + window, execute: w)
    }

    // MARK: Carbon hotkey

    private static func carbonModifiers(_ raw: UInt) -> UInt32 {
        let m = PanelShortcuts.normalize(raw)
        var out: UInt32 = 0
        if m & PanelShortcuts.command != 0 { out |= UInt32(cmdKey) }
        if m & PanelShortcuts.shift != 0 { out |= UInt32(shiftKey) }
        if m & PanelShortcuts.option != 0 { out |= UInt32(optionKey) }
        if m & PanelShortcuts.control != 0 { out |= UInt32(controlKey) }
        return out
    }

    private func installHotKey(_ combo: KeyCombo) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, refcon in
            guard let refcon else { return noErr }
            let me = Unmanaged<CmdVTap>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { me.onOpenPanel?() }
            return noErr
        }, 1, &spec, refcon, &hotKeyHandler)
        let id = EventHotKeyID(signature: OSType(0x494D5052) /* 'IMPR' */, id: 1)
        let status = RegisterEventHotKey(UInt32(combo.keyCode), Self.carbonModifiers(combo.modifiers), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        hotkeyError = PanelShortcuts.hotkeyRegistrationMessage(status: status)
        if status != noErr { hotKeyRef = nil }
    }
}

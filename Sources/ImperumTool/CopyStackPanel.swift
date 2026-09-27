// Sources/ImperumTool/CopyStackPanel.swift
import AppKit
import SwiftUI
import ImperumCore

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Floating, non-activating panel: appears above the current app without
/// stealing activation, becomes key so typing goes to the search field.
final class CopyStackPanel {
    enum Anchor { case mouseScreen, mainScreen }

    private let model: CopyStackModel
    private var panel: KeyablePanel?
    private var keyMonitor: Any?
    private var notificationObservers: [Any] = []
    private var workspaceObservers: [Any] = []
    private var distributedObservers: [Any] = []

    init(model: CopyStackModel) { self.model = model }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(anchor: Anchor) {
        let p = panel ?? makePanel()
        model.reset()
        let screen: NSScreen = {
            if anchor == .mouseScreen, let s = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) { return s }
            return NSScreen.main ?? NSScreen.screens[0]
        }()
        let f = screen.visibleFrame
        let size = NSSize(width: 640, height: 520)
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height), display: false)
        p.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    func hide() {
        removeMonitors()
        panel?.orderOut(nil)
    }

    private func makePanel() -> KeyablePanel {
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                             styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: CopyStackView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor), host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor), host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        p.contentView = effect
        panel = p
        return p
    }

    // MARK: Keys and dismissal

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel?.isKeyWindow == true else { return e }
            return self.route(e) ? nil : e
        }
        let nc = NotificationCenter.default
        notificationObservers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in self?.model.onClose?() })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            // Imperum Tool activating itself (e.g. when the panel takes key
            // focus) must not close the panel it is showing.
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
            self?.model.onClose?()
        })
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.model.onClose?() })
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        let nc = NotificationCenter.default
        for o in notificationObservers { nc.removeObserver(o) }
        notificationObservers.removeAll()
        let wc = NSWorkspace.shared.notificationCenter
        for o in workspaceObservers { wc.removeObserver(o) }
        workspaceObservers.removeAll()
        let dc = DistributedNotificationCenter.default()
        for o in distributedObservers { dc.removeObserver(o) }
        distributedObservers.removeAll()
    }

    /// True when consumed. Anything else goes to the search field.
    private func route(_ e: NSEvent) -> Bool {
        let shortcuts = model.shortcuts
        let mods = PanelShortcuts.normalize(UInt(e.modifierFlags.rawValue))
        let cmd = e.modifierFlags.contains(.command)

        // 1. The user's bindings, first match wins. Keypad Enter doubles as Return.
        var action = shortcuts.action(keyCode: e.keyCode, modifiers: mods)
        if action == nil, e.keyCode == 76 { action = shortcuts.action(keyCode: 36, modifiers: mods) }
        if let action, let command = Self.command(for: action) {
            if action == .delete, shortcuts.deleteYieldsToSearchField(queryEmpty: model.query.isEmpty) { return false }
            return model.handle(key: command)
        }

        // 2. Quick pick: the configured modifiers plus a digit.
        if mods == shortcuts.quickPickModifiers, let ch = e.charactersIgnoringModifiers,
           let n = Int(ch), (1...9).contains(n) {
            return model.handle(key: .digit(n))
        }

        // 3. Standard editing shortcuts and the swallow list.
        if cmd, let ch = e.charactersIgnoringModifiers {
            // The panel has no Edit menu, so these standard shortcuts would
            // otherwise be swallowed by the local monitor and do nothing in
            // the search field. Route them to the field's editor directly.
            switch ch {
            case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            // Swallow the shortcuts the app's main menu would otherwise act
            // on while this panel is key, so it can never quit, open
            // Settings, or minimize/close a window out from under the user.
            // Matched by character, not key code: on AZERTY and other
            // non-QWERTY layouts the physical key for ⌘Q (key code 12) types
            // a different character, so a key-code match let ⌘Q fall
            // through and quit the app. "0" is safe here — it never reaches
            // this switch for a digit paste, since that's handled by the
            // quick-pick check above.
            case "q", ",", "0", "w": return true // ⌘Q, ⌘, (comma), ⌘0, ⌘W
            default: break
            }
        }
        return false
    }

    private static func command(for action: PanelAction) -> CopyStackModel.KeyCommand? {
        switch action {
        case .up: return .up
        case .down: return .down
        case .previousCategory: return .left
        case .nextCategory: return .right
        case .paste: return .enter
        case .pin: return .pin
        case .delete: return .delete
        case .close: return .escape
        case .openPanel: return nil   // never returned by action(keyCode:modifiers:)
        }
    }
}

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
    private var observers: [Any] = []

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
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in self?.model.onClose?() })
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.model.onClose?() })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.model.onClose?() })
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        for o in observers {
            NotificationCenter.default.removeObserver(o)
            DistributedNotificationCenter.default().removeObserver(o)
        }
        observers.removeAll()
    }

    /// True when consumed. Anything else goes to the search field.
    private func route(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        switch e.keyCode {
        case 126: return model.handle(key: .up)
        case 125: return model.handle(key: .down)
        case 123: return model.handle(key: .left)
        case 124: return model.handle(key: .right)
        case 36, 76: return model.handle(key: .enter)
        case 53: return model.handle(key: .escape)
        case 51 where model.query.isEmpty: return model.handle(key: .delete)
        default: break
        }
        if cmd, let ch = e.charactersIgnoringModifiers {
            if ch == "p" { return model.handle(key: .pin) }
            if let n = Int(ch), (1...9).contains(n) { return model.handle(key: .digit(n)) }
        }
        return false
    }
}

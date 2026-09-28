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
    /// `.caret` is the caret's rect in Cocoa screen coordinates (see
    /// `CaretLocator`); the panel opens as a compact bubble pointing at it,
    /// or centred on the mouse screen when that can't be placed.
    enum Anchor { case mouseScreen, mainScreen, caret(CGRect) }

    static let fullSize = NSSize(width: 640, height: 520)
    static let compactSize = NSSize(width: 520, height: 380)
    static let arrowHeight: CGFloat = 10
    static let compactCornerRadius: CGFloat = 12
    private static let fullCornerRadius: CGFloat = 14

    private let model: CopyStackModel
    private var panel: KeyablePanel?
    private var effect: NSVisualEffectView?
    private var keyMonitor: Any?
    private var notificationObservers: [Any] = []
    private var workspaceObservers: [Any] = []
    private var distributedObservers: [Any] = []

    init(model: CopyStackModel) { self.model = model }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(anchor: Anchor) {
        let p = panel ?? makePanel()
        model.reset()

        let frame: NSRect
        if case .caret(let caret) = anchor,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: caret.midX, y: caret.midY)) }),
           let placement = PanelPlacement.place(caret: caret, panelSize: Self.compactSize, screen: screen.visibleFrame,
                                                arrowHeight: Self.arrowHeight, cornerRadius: Self.compactCornerRadius) {
            frame = placement.frame
            model.layout = .compact(arrowEdge: placement.arrowEdge, arrowX: placement.arrowX)
            applyBubbleStyle(placement)
        } else {
            let screen: NSScreen = {
                if case .mainScreen = anchor { return NSScreen.main ?? NSScreen.screens[0] }
                return NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
            }()
            let f = screen.visibleFrame
            let size = Self.fullSize
            frame = NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height)
            model.layout = .full
            applyFullStyle()
        }

        p.setFrame(frame, display: false)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        p.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 1
        }
        installMonitors()
    }

    func hide() {
        removeMonitors()
        panel?.orderOut(nil)
    }

    private func makePanel() -> KeyablePanel {
        let p = KeyablePanel(contentRect: NSRect(origin: .zero, size: Self.fullSize),
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
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: CopyStackView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor), host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor), host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        p.contentView = effect
        self.effect = effect
        panel = p
        return p
    }

    // MARK: Looks

    /// The centred window: HUD material, plain rounded corners.
    private func applyFullStyle() {
        guard let effect else { return }
        effect.material = .hudWindow
        effect.maskImage = nil
        effect.layer?.cornerRadius = Self.fullCornerRadius
    }

    /// The caret bubble: the system popover material, masked to a rounded
    /// rect with a small arrow on the edge facing the caret. The window
    /// shadow follows the mask, so the arrow gets one too.
    private func applyBubbleStyle(_ placement: PanelPlacement) {
        guard let effect else { return }
        effect.material = .popover
        effect.layer?.cornerRadius = 0
        let size = placement.frame.size
        effect.maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            Self.bubblePath(in: rect, arrowEdge: placement.arrowEdge, arrowX: placement.arrowX).fill()
            return true
        }
    }

    /// Rounded body plus an isosceles arrow, in unflipped (y-up) coordinates.
    static func bubblePath(in rect: NSRect, arrowEdge: PanelPlacement.ArrowEdge, arrowX: CGFloat) -> NSBezierPath {
        let half = PanelPlacement.arrowWidth / 2
        let body: NSRect
        let base: CGFloat, tip: CGFloat
        switch arrowEdge {
        case .top:
            body = NSRect(x: 0, y: 0, width: rect.width, height: rect.height - arrowHeight)
            base = body.maxY; tip = rect.maxY
        case .bottom:
            body = NSRect(x: 0, y: arrowHeight, width: rect.width, height: rect.height - arrowHeight)
            base = body.minY; tip = rect.minY
        }
        let path = NSBezierPath(roundedRect: body, xRadius: compactCornerRadius, yRadius: compactCornerRadius)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: arrowX - half, y: base))
        arrow.line(to: NSPoint(x: arrowX, y: tip))
        arrow.line(to: NSPoint(x: arrowX + half, y: base))
        arrow.close()
        path.append(arrow)
        path.windingRule = .nonZero
        return path
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

        // 2. Quick pick: the configured modifiers plus a digit-row key.
        if let n = shortcuts.quickPickDigit(keyCode: e.keyCode, modifiers: mods) {
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

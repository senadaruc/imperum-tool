// Sources/ImperumTool/ClipboardStatusItem.swift
import AppKit
import Combine
import ImperumCore

/// Second menu-bar item next to the WindowServer gauge: a rounded count badge
/// (template image, dimmed while paused) with the Copy Stack menu.
final class ClipboardStatusItem: NSObject, NSMenuDelegate {
    var onShow: (() -> Void)?
    var onClear: (() -> Void)?
    var onSettings: (() -> Void)?
    var onGrantAccessibility: (() -> Void)?

    /// Set by the controller when the double-tap ⌘V tap could not be
    /// installed for lack of Accessibility trust. Shows a menu item asking
    /// the user to grant it.
    var needsAccessibility = false

    private var item: NSStatusItem?
    private let store: ClipStore
    private let settings: ClipboardSettingsStore
    private var bag = Set<AnyCancellable>()
    private let countLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Capture", action: #selector(togglePause), keyEquivalent: "")
    private let showItem = NSMenuItem(title: "Show Copy Stack", action: #selector(show), keyEquivalent: "")
    private let grantAccessibilityItem = NSMenuItem(title: "Grant Accessibility to enable ⌘V…",
                                                    action: #selector(grantAccessibility), keyEquivalent: "")

    init(store: ClipStore, settings: ClipboardSettingsStore) {
        self.store = store; self.settings = settings
        super.init()
        store.$clips.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.redraw() }.store(in: &bag)
        settings.$settings.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.redraw() }.store(in: &bag)
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            it.menu = makeMenu()
            item = it
            redraw()
        } else if !visible, let it = item {
            NSStatusBar.system.removeStatusItem(it)
            item = nil
        }
    }

    private func makeMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        countLine.isEnabled = false
        m.addItem(countLine)
        m.addItem(.separator())
        showItem.target = self
        m.addItem(showItem)
        grantAccessibilityItem.target = self
        m.addItem(grantAccessibilityItem)
        let clear = NSMenuItem(title: "Clear Stack…", action: #selector(clear), keyEquivalent: ""); clear.target = self
        m.addItem(clear)
        pauseItem.target = self
        m.addItem(pauseItem)
        m.addItem(.separator())
        let s = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","); s.target = self
        m.addItem(s)
        m.addItem(NSMenuItem(title: "Quit Imperum Tool", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let n = store.clips.count
        countLine.title = n == 1 ? "1 clip" : "\(n) clips"
        pauseItem.title = settings.settings.paused ? "Resume Capture" : "Pause Capture"
        showItem.keyEquivalent = settings.settings.trigger.usesHotkey ? "v" : ""
        showItem.keyEquivalentModifierMask = [.command, .shift]
        grantAccessibilityItem.isHidden = !needsAccessibility || ActionRunner.isTrusted
    }

    private func redraw() {
        guard let b = item?.button else { return }
        let n = store.clips.count
        let text = n > 999 ? "999+" : "\(n)"
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let w = max(22, textSize.width + 10), h: CGFloat = 16
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            path.lineWidth = 1.2
            NSColor.black.setStroke(); path.stroke()
            let p = NSPoint(x: (w - textSize.width) / 2, y: (h - textSize.height) / 2)
            (text as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: NSColor.black])
            return true
        }
        img.isTemplate = true
        b.image = img
        b.alphaValue = settings.settings.paused ? 0.45 : 1
        b.toolTip = settings.settings.paused ? "Copy Stack — capture paused" : "Copy Stack — \(text) clips"
    }

    @objc private func show() { onShow?() }
    @objc private func clear() { onClear?() }
    @objc private func openSettings() { onSettings?() }
    @objc private func togglePause() { settings.settings.paused.toggle() }
    @objc private func grantAccessibility() { onGrantAccessibility?() }
}

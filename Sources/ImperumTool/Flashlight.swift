import AppKit

/// "Flashlight": covers every screen with a full-white window above
/// everything. Toggle again (or press Escape on it) to turn it off.
final class Flashlight {
    static let shared = Flashlight()
    private var windows: [NSWindow] = []

    var isOn: Bool { !windows.isEmpty }

    func toggle() {
        DispatchQueue.main.async { self.isOn ? self.off() : self.on() }
    }

    private func on() {
        for screen in NSScreen.screens {
            let w = FlashWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.backgroundColor = .white
            w.isOpaque = true
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.onEscape = { [weak self] in self?.off() }
            w.orderFrontRegardless()
            windows.append(w)
        }
        HUD.shared.show("Flashlight on — tap again or press Esc to turn off", symbol: "flashlight.on.fill")
    }

    private func off() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

private final class FlashWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

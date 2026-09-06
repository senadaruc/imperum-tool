import AppKit
import SwiftUI

/// One-line, non-activating feedback panel near the bottom of the main
/// screen ("Battery 82% · charging"). Auto-hides; never steals focus.
final class HUD {
    static let shared = HUD()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, symbol: String = "hand.tap") {
        DispatchQueue.main.async { self.present(text, symbol) }
    }

    private func present(_ text: String, _ symbol: String) {
        let view = NSHostingView(rootView: HUDView(text: text, symbol: symbol))
        let size = view.fittingSize
        let p = panel ?? makePanel()
        p.contentView = view
        p.setContentSize(size)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 110))
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let p = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.35; p.animator().alphaValue = 0 },
                                                completionHandler: { p.orderOut(nil) })
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: w)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel = p
        return p
    }
}

private struct HUDView: View {
    let text: String
    let symbol: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
            Text(text).font(.system(size: 14, weight: .semibold))
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(8)
    }
}

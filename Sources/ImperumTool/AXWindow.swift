import AppKit
import ApplicationServices
import Foundation

/// Thin wrappers over the Accessibility API for finding and manipulating
/// another process's windows. Extracted from `ActionRunner.tileFrontWindow`
/// so `TerminalHosts` can reuse the same primitives to find and position the
/// window a terminal host just opened.
enum AXWindow {
    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        var winRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let win = winRef else { return nil }
        return (win as! AXUIElement)
    }

    static func windows(pid: pid_t) -> [AXUIElement] {
        let axApp = AXUIElementCreateApplication(pid)
        var winsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement] else { return [] }
        return wins
    }

    static func title(of element: AXUIElement) -> String? {
        var titleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success else { return nil }
        return titleRef as? String
    }

    /// First window of `pid` whose title contains `titleContains`.
    static func find(pid: pid_t, titleContains: String) -> AXUIElement? {
        windows(pid: pid).first { title(of: $0)?.contains(titleContains) == true }
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success, let p = posRef,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success, let s = sizeRef
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pos)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    /// `frame` is in AX coordinates (origin top-left of the primary screen, y down).
    static func setFrame(_ element: AXUIElement, _ frame: CGRect) {
        var origin = frame.origin
        var size = frame.size
        guard let o = AXValueCreate(.cgPoint, &origin), let s = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, o)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s)
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, o)   // some apps clamp size first
    }

    static func raise(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    static func setFrontmost(pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    static func pressClose(_ element: AXUIElement) {
        var closeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeRef) == .success,
              let closeButton = closeRef else { return }
        AXUIElementPerformAction((closeButton as! AXUIElement), kAXPressAction as CFString)
    }
}

// Sources/ImperumTool/CaretLocator.swift
import AppKit
import ApplicationServices
import ImperumCore

/// Finds where the text cursor is in whatever app is in front, so the Copy
/// Stack bubble can open right there. Read-only Accessibility, synchronous
/// on the caller's thread, and bounded: every AX round-trip is capped at
/// `messagingTimeout`, so a hung app can't stall the trigger.
enum CaretLocator {
    /// Same ceiling `BrowserPageURL` uses; the AX default is ~6 s.
    private static let messagingTimeout: Float = 0.1

    /// Roles that are a text input even when the caret bounds can't be read
    /// (the bubble then hangs off the whole field).
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    /// Containers that report a selected text range without being a place
    /// the user types into: never anchor to these.
    private static let containerRoles: Set<String> = ["AXWebArea", "AXWindow", "AXApplication", "AXSheet", "AXDrawer", "AXScrollArea"]

    /// The insertion point of the focused text element, in Cocoa screen
    /// coordinates (y up), or the whole element's frame when only that is
    /// readable. nil when Accessibility isn't granted, nothing text-like has
    /// focus, or the front app is Imperum Tool itself.
    static func caretRect() -> CGRect? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, messagingTimeout)

        var element = focusedElement(axApp: axApp)
        if element.map(isTextInput) != true {
            // Chromium, Electron and WebView2 apps (Teams, Slack, VS Code,
            // browsers) build their accessibility tree lazily, once an
            // assistive client asks for it. Ask, then look once more.
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            element = focusedElement(axApp: axApp)
        }
        guard let element, isTextInput(element) else { return nil }

        let axRect = caretBounds(of: element) ?? AXWindow.frame(of: element)
        guard let axRect, axRect.height > 0, axRect.width.isFinite, axRect.height.isFinite else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return AXCoordinates.cocoaRect(axRect, primaryScreenHeight: primaryHeight)
    }

    // MARK: - Pieces

    /// System-wide focus first (it follows keyboard focus across apps), then
    /// the front app's own idea of it.
    private static func focusedElement(axApp: AXUIElement) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        for root in [system, axApp] {
            var ref: AnyObject?
            if AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &ref) == .success, let ref {
                let el = ref as! AXUIElement
                AXUIElementSetMessagingTimeout(el, messagingTimeout)
                return el
            }
        }
        return nil
    }

    private static func role(of element: AXUIElement) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// A known text role, or anything else that carries a text selection
    /// and isn't a mere container (custom editors, rich-text web widgets).
    private static func isTextInput(_ element: AXUIElement) -> Bool {
        let role = role(of: element) ?? ""
        if textRoles.contains(role) { return true }
        if containerRoles.contains(role) { return false }
        return selectedRange(of: element) != nil
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success, let ref else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func textLength(of element: AXUIElement) -> Int? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &ref) == .success else { return nil }
        return ref as? Int
    }

    /// Bounds of the caret in AX coordinates: the first candidate range the
    /// app answers with a rect of non-zero height.
    private static func caretBounds(of element: AXUIElement) -> CGRect? {
        guard let sel = selectedRange(of: element) else { return nil }
        let candidates = PanelPlacement.caretRangeCandidates(location: sel.location, length: sel.length,
                                                             textLength: textLength(of: element))
        for r in candidates {
            var cf = CFRange(location: r.location, length: r.length)
            guard let rangeValue = AXValueCreate(.cfRange, &cf) else { continue }
            var ref: AnyObject?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                              rangeValue, &ref) == .success, let ref else { continue }
            var rect = CGRect.zero
            guard AXValueGetValue(ref as! AXValue, .cgRect, &rect), rect.height > 0, rect.height < 500 else { continue }
            return rect
        }
        return nil
    }
}

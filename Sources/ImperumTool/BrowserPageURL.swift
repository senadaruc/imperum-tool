// Sources/ImperumTool/BrowserPageURL.swift
import AppKit
import ApplicationServices
import Foundation

/// Reads the host of the page shown in the frontmost application's focused
/// window, via Accessibility. Used by the clipboard capture path to veto
/// copies made while an excluded website is in front, the same way an
/// excluded application is vetoed.
///
/// Main thread only — the capture path (`ClipboardController.poll`) runs on
/// main, and the Accessibility calls here are not thread-safe.
enum BrowserPageURL {
    /// Visited-element and depth caps keep a pathological accessibility tree
    /// (a deeply nested or huge web page) from making this walk slow; the
    /// capture path calls this on every pasteboard change and must never
    /// stall noticeably.
    private static let maxVisited = 2500
    private static let maxDepth = 25

    /// A wall-clock ceiling on the whole walk, independent of the per-message
    /// AX timeout below: an app with no web area at all (an IDE, most native
    /// Mac apps) still has a UI tree to walk, and many small, individually
    /// fast AX round-trips can still add up past what a poll on every
    /// pasteboard change should ever cost.
    private static let deadline: TimeInterval = 0.05

    /// Caps every individual AX round-trip. Without this, a hung or slow
    /// frontmost app can leave a single `AXUIElementCopyAttributeValue` call
    /// blocked for the ~6 second AX default — this bounds that to a fraction
    /// of the capture path's 250 ms poll interval.
    private static let messagingTimeout: Float = 0.1

    /// nil on any Accessibility error: no permission, no frontmost app, no
    /// window, or no web-area element found. Never throws, never blocks
    /// waiting on a hung app beyond `messagingTimeout` per AX call.
    static func frontPageHost() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // Imperum Tool's own windows (the settings window, the panel) have no
        // web area to find; walking them would be pure overhead on every copy
        // made while our own UI is in front.
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }

        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, messagingTimeout)

        guard let window = AXWindow.focusedWindow(pid: pid) ?? AXWindow.windows(pid: pid).first else { return nil }
        AXUIElementSetMessagingTimeout(window, messagingTimeout)

        guard let webArea = findWebArea(from: window) else { return nil }
        let url = urlAttribute(webArea, kAXURLAttribute) ?? urlAttribute(webArea, "AXDocument")
        return url?.host
    }

    /// Breadth-first search of the accessibility tree under `root` for an
    /// element whose role is "AXWebArea", capped at `maxVisited` elements,
    /// `maxDepth` levels and `deadline` wall-clock seconds. Indexes into
    /// `queue` instead of `removeFirst()`, which is O(n) on an array.
    private static func findWebArea(from root: AXUIElement) -> AXUIElement? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var head = 0
        var visited = 0
        let deadlineAt = Date().addingTimeInterval(deadline)
        while head < queue.count {
            if Date() > deadlineAt { return nil }
            let (element, depth) = queue[head]
            head += 1
            visited += 1
            if visited > maxVisited { return nil }

            if stringAttribute(element, kAXRoleAttribute) == "AXWebArea" { return element }
            guard depth < maxDepth else { continue }

            var childrenRef: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { continue }
            for child in children { queue.append((child, depth + 1)) }
        }
        return nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// `kAXURLAttribute` ("AXURL") comes back as an `NSURL`, not a string —
    /// `AXDocument` is inconsistent across apps, so both a URL and a plain
    /// string value are accepted here.
    private static func urlAttribute(_ element: AXUIElement, _ attribute: String) -> URL? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        if let url = ref as? URL { return url }
        if let s = ref as? String { return URL(string: s) }
        return nil
    }
}

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

    /// nil on any Accessibility error: no permission, no frontmost app, no
    /// window, or no web-area element found. Never throws, never blocks
    /// waiting on a hung app beyond what the underlying AX calls do.
    static func frontPageHost() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        let window = focusedOrFirstWindow(of: axApp)
        guard let window else { return nil }

        guard let webArea = findWebArea(from: window) else { return nil }
        guard let urlString = stringAttribute(webArea, kAXURLAttribute) ?? stringAttribute(webArea, "AXDocument") else { return nil }
        return URL(string: urlString)?.host
    }

    private static func focusedOrFirstWindow(of axApp: AXUIElement) -> AXUIElement? {
        var winRef: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
           let win = winRef {
            return (win as! AXUIElement)
        }
        var winsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement], let first = wins.first else { return nil }
        return first
    }

    /// Breadth-first search of the accessibility tree under `root` for an
    /// element whose role is "AXWebArea", capped at `maxVisited` elements and
    /// `maxDepth` levels.
    private static func findWebArea(from root: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
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
}

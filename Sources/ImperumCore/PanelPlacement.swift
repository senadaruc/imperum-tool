// Sources/ImperumCore/PanelPlacement.swift
import Foundation

/// Where the Copy Stack bubble goes when it is anchored to a text caret.
/// Pure geometry so it can be unit-tested: everything is in Cocoa screen
/// coordinates (origin bottom-left, y up).
public struct PanelPlacement: Equatable {
    /// Which edge of the panel carries the arrow. `.top` means the panel
    /// sits below the caret and the arrow points up at it.
    public enum ArrowEdge: Equatable { case top, bottom }

    /// Panel frame including the `arrowHeight` strip on the arrow edge.
    public let frame: CGRect
    public let arrowEdge: ArrowEdge
    /// X of the arrow tip in panel-local coordinates (0 = panel's left edge).
    public let arrowX: CGFloat

    public static let arrowWidth: CGFloat = 20

    /// Prefers below the caret; flips above when there is no room; if neither
    /// side fits, takes the roomier side and clamps inside `screen`. Clamped
    /// horizontally to `screen`; the arrow tracks the caret's centre but
    /// never enters the rounded corners. nil when the caret is off `screen`.
    public static func place(caret: CGRect, panelSize: CGSize, screen: CGRect,
                             gap: CGFloat = 6, arrowHeight: CGFloat = 10, cornerRadius: CGFloat = 12) -> PanelPlacement? {
        let anchor = CGPoint(x: caret.midX, y: caret.midY)
        guard screen.contains(anchor) else { return nil }

        let width = panelSize.width
        let height = panelSize.height + arrowHeight
        let x = min(max(caret.midX - width / 2, screen.minX), screen.maxX - width)

        let roomBelow = caret.minY - gap - screen.minY
        let roomAbove = screen.maxY - (caret.maxY + gap)
        let below: Bool
        if roomBelow >= height { below = true }
        else if roomAbove >= height { below = false }
        else { below = roomBelow >= roomAbove }

        var y = below ? caret.minY - gap - height : caret.maxY + gap
        y = min(max(y, screen.minY), screen.maxY - height)
        let frame = CGRect(x: x, y: y, width: width, height: height)

        let inset = cornerRadius + arrowWidth / 2
        let arrowX = min(max(caret.midX - frame.minX, inset), width - inset)
        return PanelPlacement(frame: frame, arrowEdge: below ? .top : .bottom, arrowX: arrowX)
    }

    /// Text ranges to ask `AXBoundsForRange` about, most specific first:
    /// the selection itself when there is one, then the character at the
    /// caret, the one before it, and finally the empty range at the caret
    /// (AppKit answers that with a zero-width rect at the insertion point).
    public static func caretRangeCandidates(location: Int, length: Int, textLength: Int?) -> [NSRange] {
        var out: [NSRange] = []
        if length > 0 { out.append(NSRange(location: location, length: length)) }
        if textLength.map({ location < $0 }) ?? true { out.append(NSRange(location: location, length: 1)) }
        if location > 0 { out.append(NSRange(location: location - 1, length: 1)) }
        out.append(NSRange(location: location, length: 0))
        return out
    }
}

/// Accessibility reports rectangles with the origin at the top-left of the
/// primary screen and y growing downwards; AppKit wants the opposite.
public enum AXCoordinates {
    public static func cocoaRect(_ ax: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: ax.minX, y: primaryScreenHeight - ax.maxY, width: ax.width, height: ax.height)
    }
}

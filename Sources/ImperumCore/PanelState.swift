import Foundation

/// Everything the panel needs to decide what to draw and what the arrow keys
/// do, kept AppKit-free so it can be tested. The SwiftUI view is a function of
/// this plus the store.
public struct PanelState: Equatable {
    public private(set) var query = ""
    public private(set) var category: ClipCategory = .all
    public var selectedIndex = 0

    public init() {}

    public func visible(from clips: [Clip], now: Date, calendar: Calendar) -> (sections: [ClipSection], flat: [Clip]) {
        let filtered = ClipFilter.apply(clips, category: category, query: query)
        let sections = ClipGrouper.sections(filtered, now: now, calendar: calendar)
        return (sections, sections.flatMap(\.clips))
    }

    public mutating func setQuery(_ q: String) {
        guard q != query else { return }
        query = q; selectedIndex = 0
    }

    public mutating func cycleCategory(by delta: Int) {
        let all = ClipCategory.allCases
        let i = all.firstIndex(of: category)!
        category = all[((i + delta) % all.count + all.count) % all.count]
        selectedIndex = 0
    }

    public mutating func moveSelection(by delta: Int, count: Int) {
        guard count > 0 else { selectedIndex = 0; return }
        selectedIndex = min(count - 1, max(0, selectedIndex + delta))
    }

    public mutating func clampSelection(count: Int) { moveSelection(by: 0, count: count) }

    public mutating func reset() { self = PanelState() }
}

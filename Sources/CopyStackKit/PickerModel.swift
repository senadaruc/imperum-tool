import Foundation
import ImperumCore

/// Pure state model for the copystack terminal picker: turns `Key` events
/// (from `KeyParser`) into state transitions and `Effect`s the tty loop
/// (Task 8) must act on. No terminal I/O, no AppKit — fully testable.
public struct PickerModel: Equatable {
    public enum Effect: Equatable {
        case none, redraw
        case paste(UUID), copy(UUID), pin(UUID), delete(UUID)
        case cancel
    }

    /// Affects only the footer hint and which `Effect` Enter/alt-digit
    /// selection produces: `.copy` for `.copy` mode, `.paste` for every
    /// other mode (the CLI maps `.stdout`'s `.paste` effect onto `get`).
    public enum Mode: Equatable {
        case stdout, paste, copy, pick
    }

    public private(set) var state: PanelState
    /// Rebuilt from `summaries` via `ClipSummary.asClip()`.
    public private(set) var clips: [Clip]
    public private(set) var sections: [ClipSection]
    public private(set) var flat: [Clip]
    /// First visible flat index.
    public private(set) var scrollOffset: Int
    public var mode: Mode
    /// One-line footer message, cleared at the start of the next `reduce`.
    public var status: String?

    public init(summaries: [ClipSummary], mode: Mode, now: Date, calendar: Calendar) {
        self.state = PanelState()
        self.mode = mode
        self.status = nil
        self.clips = summaries.map { $0.asClip() }
        let visible = state.visible(from: clips, now: now, calendar: calendar)
        self.sections = visible.sections
        self.flat = visible.flat
        self.scrollOffset = 0
    }

    /// Keeps the selection on the same clip id when it still exists in the
    /// new list, else clamps it. Does not know the current list height, so
    /// it only clamps `scrollOffset` into the valid flat-index range; the
    /// next `reduce` call re-derives a precise window.
    public mutating func replace(summaries: [ClipSummary], now: Date, calendar: Calendar) {
        let previousSelectedID = selected?.id
        clips = summaries.map { $0.asClip() }
        let visible = state.visible(from: clips, now: now, calendar: calendar)
        sections = visible.sections
        flat = visible.flat
        if let id = previousSelectedID, let idx = flat.firstIndex(where: { $0.id == id }) {
            state.selectedIndex = idx
        } else {
            state.clampSelection(count: flat.count)
        }
        scrollOffset = min(max(scrollOffset, 0), max(0, flat.count - 1))
    }

    public var selected: Clip? {
        guard flat.indices.contains(state.selectedIndex) else { return nil }
        return flat[state.selectedIndex]
    }

    /// `listHeight` is the number of rows available for section headers +
    /// clip rows (what `FrameRenderer` will actually draw the list into).
    public mutating func reduce(_ key: Key, listHeight: Int, now: Date, calendar: Calendar) -> Effect {
        status = nil
        switch key {
        case .char(let c):
            state.setQuery(state.query + String(c))
        case .backspace:
            guard !state.query.isEmpty else { return .none }
            state.setQuery(String(state.query.dropLast()))
        case .ctrl("u"):
            state.setQuery("")
        case .paste(let s):
            let cleaned = String(s.unicodeScalars.filter { $0 != "\n" && $0 != "\r" })
            state.setQuery(state.query + cleaned)
        case .up, .ctrl("k"):
            state.moveSelection(by: -1, count: flat.count)
        case .down, .ctrl("n"), .ctrl("j"):
            state.moveSelection(by: 1, count: flat.count)
        case .pageUp:
            state.moveSelection(by: -(listHeight - 1), count: flat.count)
        case .pageDown:
            state.moveSelection(by: listHeight - 1, count: flat.count)
        case .home:
            state.moveSelection(by: -flat.count, count: flat.count)
        case .end:
            state.moveSelection(by: flat.count, count: flat.count)
        case .left:
            state.cycleCategory(by: -1)
        case .right:
            state.cycleCategory(by: 1)
        case .enter:
            guard let clip = selected else { return .none }
            return mode == .copy ? .copy(clip.id) : .paste(clip.id)
        case .alt(let c):
            guard let n = c.wholeNumberValue, n >= 1, n <= 9, n - 1 < flat.count else { return .none }
            let clip = flat[n - 1]
            return mode == .copy ? .copy(clip.id) : .paste(clip.id)
        case .ctrl("p"):
            guard let clip = selected else { return .none }
            return .pin(clip.id)
        case .ctrl("d"):
            guard let clip = selected else { return .none }
            return .delete(clip.id)
        case .escape, .ctrl("c"):
            return .cancel
        default:
            return .none
        }
        recompute(now: now, calendar: calendar)
        adjustScroll(listHeight: listHeight)
        return .redraw
    }

    // MARK: - Private

    private mutating func recompute(now: Date, calendar: Calendar) {
        let visible = state.visible(from: clips, now: now, calendar: calendar)
        sections = visible.sections
        flat = visible.flat
        state.clampSelection(count: flat.count)
    }

    private enum LineItem {
        case header
        case row(flatIndex: Int)
    }

    private func lineItems() -> [LineItem] {
        var items: [LineItem] = []
        var flatIndex = 0
        for section in sections {
            items.append(.header)
            for _ in section.clips {
                items.append(.row(flatIndex: flatIndex))
                flatIndex += 1
            }
        }
        return items
    }

    /// Adjusts `scrollOffset` so the selected row — counting section headers
    /// as rows — stays inside a `listHeight`-row window.
    private mutating func adjustScroll(listHeight: Int) {
        guard listHeight > 0, !flat.isEmpty else { scrollOffset = 0; return }

        let items = lineItems()
        var lineForFlat: [Int: Int] = [:]
        for (i, item) in items.enumerated() {
            if case .row(let idx) = item { lineForFlat[idx] = i }
        }

        func startLine(for offset: Int) -> Int {
            guard let line = lineForFlat[offset] else { return 0 }
            if line > 0, case .header = items[line - 1] { return line - 1 }
            return line
        }

        scrollOffset = min(max(scrollOffset, 0), flat.count - 1)
        guard let selectedLine = lineForFlat[state.selectedIndex] else { return }

        if selectedLine < startLine(for: scrollOffset) {
            scrollOffset = state.selectedIndex
        }
        while selectedLine - startLine(for: scrollOffset) > listHeight - 1, scrollOffset < flat.count - 1 {
            scrollOffset += 1
        }
    }
}

import Foundation
import ImperumCore

public struct TerminalSize: Equatable {
    public let cols: Int
    public let rows: Int
    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

/// Renders a `PickerModel` into a full-screen terminal frame. Pure text: no
/// terminal I/O. `plain(_:)` strips every ANSI escape sequence so tests can
/// compare against a golden multi-line string that reads like what a person
/// would see.
public enum FrameRenderer {
    private static let minCols = 40
    private static let minRows = 8
    private static let previewThresholdRows = 20
    private static let previewRowCount = 6

    /// Whole frame as one string starting with cursor-home; every line ends
    /// with an erase-to-end-of-line sequence; lines are joined with "\r\n";
    /// there is no trailing newline after the last line.
    public static func render(_ m: PickerModel, size: TerminalSize, now: Date, calendar: Calendar, noColor: Bool) -> String {
        guard size.rows >= minRows, size.cols >= minCols else {
            let msg = DisplayWidth.truncate("Copy Stack: window too small (min 40×8)", to: size.cols)
            return "\u{1b}[H" + msg + "\u{1b}[K"
        }

        let cols = size.cols
        var lines: [String] = []

        lines.append(row1(m, cols: cols))
        lines.append(row2(m, cols: cols, noColor: noColor))
        lines.append("") // row 3: blank separator

        let listRows = listHeight(for: size)
        let showPreview = size.rows >= previewThresholdRows

        lines.append(contentsOf: listLines(m, width: cols, listRows: listRows, now: now, calendar: calendar, noColor: noColor))

        if showPreview {
            lines.append(contentsOf: previewBoxLines(m, width: cols, noColor: noColor))
        }

        lines.append("") // blank separator above footer
        lines.append(footerLine(m, cols: cols))

        let body = lines.map { $0 + "\u{1b}[K" }.joined(separator: "\r\n")
        return "\u{1b}[H" + body
    }

    /// Rows available for section headers + clip rows at `size`: the list
    /// zone (rows 4…rows-2), minus the 6 rows reserved for the preview box
    /// once `size.rows >= 20`; 0 when the frame is too small to render.
    public static func listHeight(for size: TerminalSize) -> Int {
        guard size.rows >= minRows, size.cols >= minCols else { return 0 }
        let contentZoneHeight = size.rows - 5
        let previewRows = size.rows >= previewThresholdRows ? previewRowCount : 0
        return max(0, contentZoneHeight - previewRows)
    }

    /// Same frame with every ANSI escape sequence stripped.
    public static func plain(_ frame: String) -> String {
        var result = ""
        let chars = Array(frame)
        var i = 0
        while i < chars.count {
            if chars[i] == "\u{1b}", i + 1 < chars.count, chars[i + 1] == "[" {
                var j = i + 2
                while j < chars.count, !("@"..."~").contains(chars[j]) {
                    j += 1
                }
                i = j + 1 // also skip the final byte
                continue
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    // MARK: - Row 1: query + count

    private static func row1(_ m: PickerModel, cols: Int) -> String {
        // Defence in depth: PickerModel already sanitizes the query as it's
        // typed/pasted, but row 1 must never trust that and re-sanitizes
        // before it ever reaches the terminal frame.
        let left = "› " + Sanitize.line(m.state.query) + "▏"
        let right = "\(m.flat.count) clips"
        return leftRightPlain(left, right, width: cols)
    }

    // MARK: - Row 2: categories

    private static func row2(_ m: PickerModel, cols: Int, noColor: Bool) -> String {
        var plainParts: [String] = []
        var styledParts: [String] = []
        for cat in ClipCategory.allCases {
            if cat == m.state.category {
                if noColor {
                    plainParts.append("[\(cat.title)]")
                    styledParts.append("[\(cat.title)]")
                } else {
                    plainParts.append(cat.title)
                    styledParts.append("\u{1b}[7m\(cat.title)\u{1b}[0m")
                }
            } else {
                plainParts.append(cat.title)
                styledParts.append(cat.title)
            }
        }
        let plain = plainParts.joined(separator: "  ")
        if DisplayWidth.of(plain) > cols {
            return DisplayWidth.truncate(plain, to: cols)
        }
        return styledParts.joined(separator: "  ")
    }

    // MARK: - List rows

    private static func listLines(
        _ m: PickerModel, width: Int, listRows: Int, now: Date, calendar: Calendar, noColor: Bool
    ) -> [String] {
        guard !m.flat.isEmpty else {
            let query = m.state.query.trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = query.isEmpty ? "No clips" : "No matches for \"\(m.state.query)\""
            var lines = [DisplayWidth.truncate(msg, to: width)]
            while lines.count < listRows { lines.append("") }
            return lines
        }

        let items = PickerLineLayout.items(m.sections)
        let lineForFlat = PickerLineLayout.lineForFlatIndex(items)
        let startLine = PickerLineLayout.startLine(for: m.scrollOffset, items: items, lineForFlat: lineForFlat)

        var lines: [String] = []
        var i = startLine
        while lines.count < listRows, i < items.count {
            switch items[i] {
            case .header(let title):
                let text = DisplayWidth.truncate(title, to: width)
                lines.append(noColor ? text : "\u{1b}[2m\(text)\u{1b}[0m")
            case .row(let idx):
                let clip = m.flat[idx]
                lines.append(clipRow(
                    clip, selected: idx == m.state.selectedIndex, width: width, now: now, noColor: noColor
                ))
            }
            i += 1
        }
        while lines.count < listRows { lines.append("") }
        return lines
    }

    private static func clipRow(_ clip: Clip, selected: Bool, width: Int, now: Date, noColor: Bool) -> String {
        let markerPlain = selected ? "▶ " : "  "
        let pinPlain = clip.isPinned ? "★ " : "  "
        let glyphStr = glyph(for: clip.kind)
        let prefixPlain = markerPlain + pinPlain + glyphStr + " "
        let source = Sanitize.line(clip.sourceAppName)
        let right = "\(source) · \(ageString(clip.capturedAt, now: now))"
        let rightWidth = DisplayWidth.of(right)
        let titleBudget = max(0, width - DisplayWidth.of(prefixPlain) - rightWidth - 1)
        let title = DisplayWidth.truncate(Sanitize.line(clip.title), to: titleBudget)

        let leftPlain = prefixPlain + title
        let gap = max(0, width - DisplayWidth.of(leftPlain) - rightWidth)

        let markerStyled = (selected && !noColor) ? "\u{1b}[7m\(markerPlain)\u{1b}[0m" : markerPlain
        let leftStyled = markerStyled + pinPlain + glyphStr + " " + title
        return leftStyled + String(repeating: " ", count: gap) + right
    }

    private static func glyph(for kind: ClipKind) -> String {
        switch kind {
        case .text, .color: return "T"
        case .link: return "↗"
        case .email: return "@"
        case .image: return "▣"
        case .screenshot: return "▣"
        case .video: return "▶"
        case .file: return "▤"
        }
    }

    private static func ageString(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        return "\(days)d"
    }

    // MARK: - Preview box

    private static func previewBoxLines(_ m: PickerModel, width: Int, noColor: Bool) -> [String] {
        var lines: [String] = []
        lines.append(dimRule(width, noColor: noColor))
        let content = previewLines(for: m.selected, width: width)
        for i in 0..<4 {
            lines.append(i < content.count ? content[i] : "")
        }
        lines.append(dimRule(width, noColor: noColor))
        return lines
    }

    private static func dimRule(_ width: Int, noColor: Bool) -> String {
        let rule = String(repeating: "─", count: max(0, width))
        return noColor ? rule : "\u{1b}[2m\(rule)\u{1b}[0m"
    }

    private static func previewLines(for clip: Clip?, width: Int) -> [String] {
        guard let clip else { return [] }
        switch clip.payload {
        case .text(let s):
            return Sanitize.lines(s, max: 4).map { DisplayWidth.truncate($0, to: width) }
        case .fileURLs(let urls):
            return urls.map { Sanitize.line($0.lastPathComponent) }.prefix(4).map { DisplayWidth.truncate($0, to: width) }
        case .blob(_, _, let w, let h):
            return [DisplayWidth.truncate(Sanitize.line("Image \(w)×\(h)"), to: width)]
        }
    }

    // MARK: - Footer

    private static func footerLine(_ m: PickerModel, cols: Int) -> String {
        let hints: String
        switch m.mode {
        case .copy:
            hints = "↑↓ move  ←→ category  ⏎ copy  ^P pin  ^D delete  esc cancel"
        case .stdout:
            hints = "↑↓ move  ←→ category  ⏎ select  ^P pin  ^D delete  esc cancel"
        case .paste, .pick:
            hints = "↑↓ move  ←→ category  ⏎ paste  ^P pin  ^D delete  esc cancel"
        }
        let text = m.status.map(Sanitize.line) ?? hints
        return DisplayWidth.truncate(text, to: cols)
    }

    // MARK: - Shared layout helper

    private static func leftRightPlain(_ left: String, _ right: String, width: Int) -> String {
        let rightTrunc = DisplayWidth.of(right) > width ? DisplayWidth.truncate(right, to: width) : right
        let leftBudget = max(0, width - DisplayWidth.of(rightTrunc) - 1)
        let leftTrunc = DisplayWidth.of(left) > leftBudget ? DisplayWidth.truncate(left, to: leftBudget) : left
        let gap = max(0, width - DisplayWidth.of(leftTrunc) - DisplayWidth.of(rightTrunc))
        return leftTrunc + String(repeating: " ", count: gap) + rightTrunc
    }
}

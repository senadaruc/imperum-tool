import XCTest
import ImperumCore
@testable import CopyStackKit

final class FrameRendererTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }

    // A fixed instant so "Today" and ages are deterministic.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func summary(
        kind: ClipKind = .text, title: String, source: String, pinned: Bool = false,
        secondsAgo: TimeInterval, id: UUID = UUID(), width: Int = 0, height: Int = 0
    ) -> ClipSummary {
        let payload: ClipPayload = kind == .image
            ? .blob(id: id, utType: "public.png", width: width, height: height)
            : .text(title)
        let clip = Clip(
            id: id, kind: kind, capturedAt: now.addingTimeInterval(-secondsAgo),
            sourceAppName: source, sourceBundleID: nil, isPinned: pinned,
            title: title, payload: payload
        )
        return ClipSummary(clip: clip)
    }

    private func fourClipModel() -> PickerModel {
        let summaries = [
            summary(title: "Pinned note", source: "Notes", pinned: true, secondsAgo: 3600),
            summary(title: "Meeting agenda for tomorrow", source: "Mail", secondsAgo: 30),
            summary(title: "Shopping list", source: "TextEdit", secondsAgo: 120),
            summary(kind: .image, title: "Screenshot", source: "Preview", secondsAgo: 90, width: 1920, height: 1080),
        ]
        var m = PickerModel(summaries: summaries, mode: .paste, now: now, calendar: calendar)
        _ = m.reduce(.down, listHeight: 20, now: now, calendar: calendar) // select row 2 (index 1)
        return m
    }

    // MARK: - 100x30 golden frame (with preview box)

    func testGolden100x30() {
        let m = fourClipModel()
        let frame = FrameRenderer.render(m, size: TerminalSize(cols: 100, rows: 30), now: now, calendar: calendar, noColor: true)
        let plain = FrameRenderer.plain(frame)
        let lines = plain.components(separatedBy: "\r\n")

        XCTAssertEqual(lines.count, 30)

        // Row 1: query + right-aligned count.
        XCTAssertTrue(lines[0].hasPrefix("› ▏"))
        XCTAssertTrue(lines[0].hasSuffix("4 clips"))

        // Row 2: categories, [All] bracketed as active (noColor).
        XCTAssertTrue(lines[1].hasPrefix("[All]  Text  Links  Emails  Images  Videos  Files"))

        // Row 3: blank separator.
        XCTAssertEqual(lines[2], "")

        // Row 4: "Pinned" section header.
        XCTAssertEqual(lines[3], "Pinned")
        // Row 5: the pinned clip.
        XCTAssertTrue(lines[4].hasPrefix("  ★ T Pinned note"))
        XCTAssertTrue(lines[4].hasSuffix("Notes · 1h"))

        // Row 6: "Today" section header.
        XCTAssertEqual(lines[5], "Today")
        // Row 7: second clip, selected (marker + no pin).
        XCTAssertTrue(lines[6].hasPrefix("▶   T Meeting agenda for tomorrow"))
        XCTAssertTrue(lines[6].hasSuffix("Mail · 30s"))
        // Row 8: third clip.
        XCTAssertTrue(lines[7].hasPrefix("    T Shopping list"))
        XCTAssertTrue(lines[7].hasSuffix("TextEdit · 2m"))
        // Row 9: image clip.
        XCTAssertTrue(lines[8].hasPrefix("    ▣ Screenshot"))
        XCTAssertTrue(lines[8].hasSuffix("Preview · 1m"))

        // Content zone is rows-5 = 25 rows (0-indexed 3...27); the preview
        // box reserves the last 6 of those (0-indexed 22...27), leaving 19
        // list rows (0-indexed 3...21). Row 28 is the blank separator
        // before the footer, row 29 is the footer.
        let ruleTop = lines[22]
        XCTAssertEqual(ruleTop, String(repeating: "─", count: 100))
        XCTAssertEqual(lines[23], "Meeting agenda for tomorrow") // selected clip's text preview
        XCTAssertEqual(lines[24], "")
        XCTAssertEqual(lines[25], "")
        XCTAssertEqual(lines[26], "")
        XCTAssertEqual(lines[27], String(repeating: "─", count: 100))

        // Blank separator before footer.
        XCTAssertEqual(lines[28], "")
        // Footer is the last line.
        XCTAssertEqual(lines[29], "↑↓ move  ←→ category  ⏎ paste  ^P pin  ^D delete  esc cancel")

        for line in lines {
            XCTAssertLessThanOrEqual(DisplayWidth.of(line), 100)
        }
    }

    // MARK: - 60x10 (no preview box, list truncated, selection still visible)

    func testGolden60x10NoPreviewBox() {
        var summaries: [ClipSummary] = []
        for i in 0..<20 {
            summaries.append(summary(title: "clip \(i)", source: "App", secondsAgo: TimeInterval(20 - i)))
        }
        var m = PickerModel(summaries: summaries, mode: .paste, now: now, calendar: calendar)
        for _ in 0..<10 {
            _ = m.reduce(.down, listHeight: 3, now: now, calendar: calendar) // matches the 60x10 list budget below
        }

        let frame = FrameRenderer.render(m, size: TerminalSize(cols: 60, rows: 10), now: now, calendar: calendar, noColor: true)
        let plain = FrameRenderer.plain(frame)
        let lines = plain.components(separatedBy: "\r\n")

        XCTAssertEqual(lines.count, 10)
        // No preview box at this height: rows 4...8 (0-indexed 3...7) are list rows,
        // row 9 (0-indexed 8) is blank, row 10 (0-indexed 9) is the footer.
        XCTAssertEqual(lines[8], "")
        XCTAssertEqual(lines[9], "↑↓ move  ←→ category  ⏎ paste  ^P pin  ^D delete  esc cancel")

        // The selected clip (index 10, "clip 10") must appear somewhere in the
        // rendered list window (rows 3...7, 0-indexed).
        let listWindow = lines[3...7].joined(separator: "\n")
        XCTAssertTrue(listWindow.contains("clip 10"))
        XCTAssertTrue(listWindow.contains("▶"))

        for line in lines {
            XCTAssertLessThanOrEqual(DisplayWidth.of(line), 60)
        }
    }

    // MARK: - Sanitization of clip-derived strings

    private func fileSummary(name: String, source: String = "Finder", secondsAgo: TimeInterval = 30) -> ClipSummary {
        let clip = Clip(
            id: UUID(), kind: .file, capturedAt: now.addingTimeInterval(-secondsAgo),
            sourceAppName: source, sourceBundleID: nil, isPinned: false,
            title: name, payload: .fileURLs([URL(fileURLWithPath: "/tmp/\(name)")])
        )
        return ClipSummary(clip: clip)
    }

    func testFileNameWithEscapeSequenceIsSanitizedInPreviewBox() {
        let evilName = "evil\u{1B}[31m.txt"
        let summaries = [fileSummary(name: evilName)]
        let m = PickerModel(summaries: summaries, mode: .paste, now: now, calendar: calendar)
        // rows >= 20 shows the preview box, where the file name is listed.
        let frame = FrameRenderer.render(m, size: TerminalSize(cols: 100, rows: 30), now: now, calendar: calendar, noColor: true)
        let plain = FrameRenderer.plain(frame)
        XCTAssertFalse(plain.contains("\u{1B}"))
        XCTAssertTrue(plain.contains("·"), "escape sequence in the file name must be replaced with a visible marker")
    }

    func testFileNameWithEscapeSequenceIsSanitizedInTitleColumn() {
        let evilTitle = "evil\u{1B}[31m.txt"
        let summaries = [fileSummary(name: evilTitle)]
        let m = PickerModel(summaries: summaries, mode: .paste, now: now, calendar: calendar)
        let frame = FrameRenderer.render(m, size: TerminalSize(cols: 100, rows: 10), now: now, calendar: calendar, noColor: true)
        let plain = FrameRenderer.plain(frame)
        XCTAssertFalse(plain.contains("\u{1B}"))
        XCTAssertTrue(plain.contains("·"))
    }

    func testSourceAppNameWithEscapeSequenceIsSanitized() {
        let summaries = [summary(title: "note", source: "Evil\u{1B}[31mApp", secondsAgo: 30)]
        let m = PickerModel(summaries: summaries, mode: .paste, now: now, calendar: calendar)
        let frame = FrameRenderer.render(m, size: TerminalSize(cols: 100, rows: 10), now: now, calendar: calendar, noColor: true)
        let plain = FrameRenderer.plain(frame)
        XCTAssertFalse(plain.contains("\u{1B}"))
        XCTAssertTrue(plain.contains("·"))
    }

    func testImageDimensionsTextIsSanitized() {
        // Image dimensions are attacker-controlled only in the sense that
        // they flow through the same clip-derived path; sanitizing them is
        // cheap and keeps the invariant uniform across payload kinds. This
        // just checks the normal case still renders correctly.
        let summaries = [summary(kind: .image, title: "shot", source: "Preview", secondsAgo: 30, width: 800, height: 600)]
        let m = PickerModel(summaries: summaries, mode: .paste, now: now, calendar: calendar)
        let frame = FrameRenderer.render(m, size: TerminalSize(cols: 100, rows: 30), now: now, calendar: calendar, noColor: true)
        let plain = FrameRenderer.plain(frame)
        XCTAssertTrue(plain.contains("Image 800×600"))
    }

    // MARK: - listHeight(for:)

    func testListHeightMatchesActualRenderedListRows() {
        let sizes = [TerminalSize(cols: 100, rows: 30), TerminalSize(cols: 60, rows: 10), TerminalSize(cols: 30, rows: 5)]
        var summaries: [ClipSummary] = []
        for i in 0..<30 {
            summaries.append(summary(title: "clip \(i)", source: "App", secondsAgo: TimeInterval(30 - i)))
        }
        let m = PickerModel(summaries: summaries, mode: .paste, now: now, calendar: calendar)

        for size in sizes {
            let expected = FrameRenderer.listHeight(for: size)
            let frame = FrameRenderer.render(m, size: size, now: now, calendar: calendar, noColor: true)
            let plain = FrameRenderer.plain(frame)
            let lines = plain.components(separatedBy: "\r\n")

            if size.rows < 8 || size.cols < 40 {
                XCTAssertEqual(expected, 0)
                continue
            }

            // Total rendered rows minus the fixed rows: row1, row2, blank
            // separator, blank-before-footer, footer (5), and the preview
            // box (6) when shown, leaves exactly the list rows.
            let showPreview = size.rows >= 20
            let fixedRows = 5 + (showPreview ? 6 : 0)
            XCTAssertEqual(lines.count - fixedRows, expected, "size \(size)")
        }
    }

    // MARK: - Too small

    func testTooSmallSize() {
        let m = fourClipModel()
        let frame = FrameRenderer.render(m, size: TerminalSize(cols: 30, rows: 5), now: now, calendar: calendar, noColor: true)
        let plain = FrameRenderer.plain(frame)
        XCTAssertLessThanOrEqual(DisplayWidth.of(plain), 30)
        XCTAssertTrue(plain.hasPrefix("Copy Stack:"))
    }

    func testTooSmallSizeExactMessageWhenWidthAllows() {
        let m = fourClipModel()
        let frame = FrameRenderer.render(m, size: TerminalSize(cols: 60, rows: 5), now: now, calendar: calendar, noColor: true)
        let plain = FrameRenderer.plain(frame)
        XCTAssertEqual(plain, "Copy Stack: window too small (min 40×8)")
    }

    // MARK: - noColor invariant

    func testNoColorFrameHasNoStrayEscapes() {
        let m = fourClipModel()
        let frame = FrameRenderer.render(m, size: TerminalSize(cols: 100, rows: 30), now: now, calendar: calendar, noColor: true)
        // Every ESC in the raw frame must be immediately followed by '[H' or '[K'.
        let chars = Array(frame)
        var i = 0
        while i < chars.count {
            if chars[i] == "\u{1b}" {
                XCTAssertTrue(i + 1 < chars.count && chars[i + 1] == "[")
                XCTAssertTrue(i + 2 < chars.count && (chars[i + 2] == "H" || chars[i + 2] == "K"))
            }
            i += 1
        }
    }

    func testColorFrameContainsSGRForSelectionAndCategory() {
        let m = fourClipModel()
        let frame = FrameRenderer.render(m, size: TerminalSize(cols: 100, rows: 30), now: now, calendar: calendar, noColor: false)
        XCTAssertTrue(frame.contains("\u{1b}[7m"))
        XCTAssertTrue(frame.contains("\u{1b}[2m"))
        // plain() must still strip it all back to the same visible text as noColor's marker rendering.
        let plain = FrameRenderer.plain(frame)
        XCTAssertFalse(plain.contains("\u{1b}"))
    }

    // MARK: - plain() strips escapes

    func testPlainStripsCursorHomeAndEraseSequences() {
        let raw = "\u{1b}[Hhello\u{1b}[K\r\nworld\u{1b}[K"
        XCTAssertEqual(FrameRenderer.plain(raw), "hello\r\nworld")
    }

    // MARK: - Every line width bound, across sizes

    func testEveryLineWithinColumnBudget() {
        let sizes = [TerminalSize(cols: 100, rows: 30), TerminalSize(cols: 60, rows: 10), TerminalSize(cols: 40, rows: 8)]
        let m = fourClipModel()
        for size in sizes {
            let frame = FrameRenderer.render(m, size: size, now: now, calendar: calendar, noColor: true)
            let plain = FrameRenderer.plain(frame)
            for line in plain.components(separatedBy: "\r\n") {
                XCTAssertLessThanOrEqual(DisplayWidth.of(line), size.cols, "size \(size)")
            }
        }
    }
}

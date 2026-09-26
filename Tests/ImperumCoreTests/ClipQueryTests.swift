import XCTest
@testable import ImperumCore

private func clip(_ kind: ClipKind, _ title: String, text: String? = nil, at t: TimeInterval, pinned: Bool = false) -> Clip {
    Clip(kind: kind, capturedAt: Date(timeIntervalSince1970: t), sourceAppName: "A", sourceBundleID: nil,
         isPinned: pinned, title: title, payload: .text(text ?? title))
}

final class ClipQueryTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    func testCategoriesMapToKinds() {
        XCTAssertNil(ClipCategory.all.kind)
        XCTAssertEqual(ClipCategory.links.kind, .link)
        XCTAssertEqual(ClipCategory.emails.kind, .email)
        XCTAssertEqual(ClipCategory.allCases.map(\.title), ["All", "Text", "Links", "Emails", "Colors", "Images", "Videos", "Files"])
    }

    func testFilterByCategoryAndQueryOnTitleAndBody() {
        let clips = [clip(.text, "Alpha", text: "Alpha\nsecret body", at: 3), clip(.link, "https://x.io", at: 2), clip(.email, "a@b.co", at: 1)]
        XCTAssertEqual(ClipFilter.apply(clips, category: .links, query: "").map(\.title), ["https://x.io"])
        XCTAssertEqual(ClipFilter.apply(clips, category: .all, query: "BODY").map(\.title), ["Alpha"])
        XCTAssertEqual(ClipFilter.apply(clips, category: .all, query: "x.IO").map(\.title), ["https://x.io"])
        XCTAssertEqual(ClipFilter.apply(clips, category: .emails, query: "alpha").count, 0)
        XCTAssertEqual(ClipFilter.apply(clips, category: .all, query: "  ").count, 3)
    }

    func testSectionsPinnedTodayYesterdayOlder() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)          // 2023-11-14 22:13 UTC
        let today = now.timeIntervalSince1970 - 3600
        let yesterday = now.timeIntervalSince1970 - 86_400
        let older = now.timeIntervalSince1970 - 3 * 86_400
        let clips = [clip(.text, "t", at: today), clip(.text, "y", at: yesterday), clip(.text, "o", at: older),
                     clip(.text, "p", at: older, pinned: true)]
        let s = ClipGrouper.sections(clips, now: now, calendar: cal)
        XCTAssertEqual(s.map(\.title), ["Pinned", "Today", "Yesterday", "November 11, 2023"])
        XCTAssertEqual(s.map { $0.clips.map(\.title) }, [["p"], ["t"], ["y"], ["o"]])
    }

    func testMidnightBoundaryUsesCalendarDays() {
        var c = cal
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        // 2023-11-15 00:30 Amsterdam = 2023-11-14 23:30 UTC
        let now = Date(timeIntervalSince1970: 1_700_004_600)
        let justBeforeMidnight = now.addingTimeInterval(-3600)         // 23:30 on the 14th, Amsterdam
        let s = ClipGrouper.sections([clip(.text, "x", at: justBeforeMidnight.timeIntervalSince1970)], now: now, calendar: c)
        XCTAssertEqual(s.map(\.title), ["Yesterday"])
    }

    func testEmptyInputGivesNoSections() {
        XCTAssertTrue(ClipGrouper.sections([], now: Date(), calendar: cal).isEmpty)
    }
}

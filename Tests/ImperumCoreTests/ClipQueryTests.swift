import XCTest
@testable import ImperumCore

private func clip(_ kind: ClipKind, _ title: String, text: String? = nil, at t: TimeInterval, pinned: Bool = false) -> Clip {
    Clip(kind: kind, capturedAt: Date(timeIntervalSince1970: t), sourceAppName: "A", sourceBundleID: nil,
         isPinned: pinned, title: title, payload: .text(text ?? title))
}

final class ClipQueryTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    func testCategoriesMapToKinds() {
        XCTAssertNil(ClipCategory.all.kind)
        XCTAssertEqual(ClipCategory.links.kind, .link)
        XCTAssertEqual(ClipCategory.emails.kind, .email)
        XCTAssertEqual(ClipCategory.allCases.map(\.title), ["All", "Text", "Links", "Emails", "Images", "Videos", "Files"])
    }

    /// Round 10: the Colors category is gone; a legacy `.color` clip (from an
    /// archive written before round 10) must still be reachable, under Text.
    func testLegacyColorClipStaysReachableUnderTextCategory() {
        let legacyColor = Clip(kind: .color, sourceAppName: "A", sourceBundleID: nil, title: "#FF0080", payload: .text("#FF0080"))
        let clips = [clip(.text, "Alpha", at: 1), legacyColor]
        XCTAssertEqual(ClipFilter.apply(clips, category: .text, query: "").map(\.title), ["Alpha", "#FF0080"])
    }

    func testFilterByCategoryAndQueryOnTitleAndBody() {
        let clips = [clip(.text, "Alpha", text: "Alpha\nsecret body", at: 3), clip(.link, "https://x.io", at: 2), clip(.email, "a@b.co", at: 1)]
        XCTAssertEqual(ClipFilter.apply(clips, category: .links, query: "").map(\.title), ["https://x.io"])
        XCTAssertEqual(ClipFilter.apply(clips, category: .all, query: "BODY").map(\.title), ["Alpha"])
        XCTAssertEqual(ClipFilter.apply(clips, category: .all, query: "x.IO").map(\.title), ["https://x.io"])
        XCTAssertEqual(ClipFilter.apply(clips, category: .emails, query: "alpha").count, 0)
        XCTAssertEqual(ClipFilter.apply(clips, category: .all, query: "  ").count, 3)
    }

    func testFilterIsDiacriticInsensitive() {
        let clips = [clip(.text, "Alpha", at: 1)]
        XCTAssertEqual(ClipFilter.apply(clips, category: .all, query: "ALPHÁ").map(\.title), ["Alpha"])
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

    func testFutureStampedClipsCollapseIntoSingleTodaySection() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)          // 2023-11-14 22:13 UTC
        let future = now.timeIntervalSince1970 + 86_400
        let recent = now.timeIntervalSince1970 - 3600
        let clips = [clip(.text, "f", at: future), clip(.text, "t", at: recent)]
        let s = ClipGrouper.sections(clips, now: now, calendar: cal)
        XCTAssertEqual(s.map(\.title), ["Today"])
        XCTAssertEqual(s.map { $0.clips.map(\.title) }, [["f", "t"]])
    }

    func testEmptyInputGivesNoSections() {
        XCTAssertTrue(ClipGrouper.sections([], now: Date(), calendar: cal).isEmpty)
    }

    func testEveryKindMapsToOneCategoryForLimits() {
        XCTAssertEqual(ClipCategory(kind: .text), .text)
        XCTAssertEqual(ClipCategory(kind: .color), .text)
        XCTAssertEqual(ClipCategory(kind: .link), .links)
        XCTAssertEqual(ClipCategory(kind: .email), .emails)
        XCTAssertEqual(ClipCategory(kind: .image), .images)
        XCTAssertEqual(ClipCategory(kind: .video), .videos)
        XCTAssertEqual(ClipCategory(kind: .file), .files)
        for k in ClipKind.allCases { XCTAssertNotEqual(ClipCategory(kind: k), .all) }
    }
}

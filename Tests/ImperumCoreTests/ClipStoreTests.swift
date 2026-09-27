import XCTest
@testable import ImperumCore

private let limits = ClipLimits(maxStack: 3, retentionDays: 30)
private let base = Date(timeIntervalSince1970: 1_700_000_000)
private func text(_ s: String, app: String = "A", at t: TimeInterval = 0, pinned: Bool = false) -> Clip {
    Clip(kind: .text, capturedAt: base.addingTimeInterval(t), sourceAppName: app, sourceBundleID: nil, isPinned: pinned, title: s, payload: .text(s))
}

private func clip(_ kind: ClipKind, _ title: String, at t: TimeInterval, pinned: Bool = false) -> Clip {
    Clip(kind: kind, capturedAt: base.addingTimeInterval(t), sourceAppName: "A", sourceBundleID: nil,
         isPinned: pinned, title: title, payload: .text(title))
}

final class ClipStoreTests: XCTestCase {
    func testInsertPutsNewestFirst() {
        let s = ClipStore()
        s.insert(text("one"), limits: limits, now: base)
        s.insert(text("two"), limits: limits, now: base)
        XCTAssertEqual(s.clips.map(\.title), ["two", "one"])
    }

    func testDedupeKeepsIdAndPinMovesToTopUpdatesSourceAndTime() {
        let s = ClipStore()
        let first = s.insert(text("same", app: "Notes", at: 10), limits: limits, now: base)
        s.togglePin(first.id)
        s.insert(text("other", at: 20), limits: limits, now: base)
        let again = s.insert(text("same", app: "Safari", at: 30), limits: limits, now: base)
        XCTAssertEqual(s.clips.count, 2)
        XCTAssertEqual(again.id, first.id)
        XCTAssertTrue(again.isPinned)
        XCTAssertEqual(again.sourceAppName, "Safari")
        XCTAssertEqual(again.capturedAt, base.addingTimeInterval(30))
        XCTAssertEqual(s.clips.first?.id, first.id)
    }

    /// A fresh rich copy of previously-plain text upgrades the stored clip:
    /// richText, like capturedAt and source, comes from the INCOMING insert.
    func testDedupeUpgradesRichTextFromIncoming() {
        let s = ClipStore()
        s.insert(text("same", at: 10), limits: limits, now: base)
        var rich = text("same", at: 20)
        rich.richText = Data([1, 2, 3])
        let again = s.insert(rich, limits: limits, now: base)
        XCTAssertEqual(s.clips.count, 1)
        XCTAssertEqual(again.richText, Data([1, 2, 3]))
        XCTAssertEqual(s.clips.first?.richText, Data([1, 2, 3]))
    }

    /// Guards the shape of clip the controller rebuilds after a successful
    /// paste, to move it to the top (same id/kind/source/pin/title/payload/
    /// richText, just a fresh capturedAt): re-inserting that must not drop
    /// richText, since it dedupes onto the same contentKey as the original.
    func testReinsertAfterPasteKeepsRichText() {
        let s = ClipStore()
        let original = Clip(kind: .text, sourceAppName: "Word", sourceBundleID: "com.microsoft.Word",
                            title: "hi", payload: .text("hi"), richText: Data([1, 2, 3]))
        s.insert(original, limits: limits, now: base)
        let refreshed = Clip(id: original.id, kind: original.kind, capturedAt: base.addingTimeInterval(10),
                             sourceAppName: original.sourceAppName, sourceBundleID: original.sourceBundleID,
                             isPinned: original.isPinned, title: original.title, payload: original.payload,
                             richText: original.richText)
        let again = s.insert(refreshed, limits: limits, now: base)
        XCTAssertEqual(s.clips.count, 1)
        XCTAssertEqual(again.richText, Data([1, 2, 3]))
        XCTAssertEqual(s.clips.first?.richText, Data([1, 2, 3]))
    }

    func testMaxStackDropsOldestUnpinnedOnly() {
        let s = ClipStore()
        let keep = s.insert(text("pinned", at: 1), limits: limits, now: base)
        s.togglePin(keep.id)
        for i in 2...6 { s.insert(text("t\(i)", at: TimeInterval(i)), limits: limits, now: base) }
        XCTAssertEqual(s.clips.filter { !$0.isPinned }.count, 3)
        XCTAssertTrue(s.clips.contains { $0.id == keep.id })
        XCTAssertEqual(s.clips.filter { !$0.isPinned }.map(\.title), ["t6", "t5", "t4"])
    }

    func testRetentionDropsOldUnpinnedKeepsPinnedAndFuture() {
        let s = ClipStore()
        s.insert(text("old", at: -90 * 86_400), limits: limits, now: base)
        s.insert(text("old-pinned", at: -90 * 86_400, pinned: true), limits: limits, now: base)
        s.insert(text("future", at: 100 * 86_400), limits: limits, now: base)
        s.insert(text("fresh", at: -1 * 86_400), limits: limits, now: base)
        XCTAssertEqual(Set(s.clips.map(\.title)), ["old-pinned", "future", "fresh"])
    }

    func testSameImageDedupesKeepingOneClip() {
        let s = ClipStore()
        var dropped: [UUID] = []
        s.onBlobsDropped = { dropped += $0 }
        let blob = UUID()
        let payload = ClipPayload.blob(id: blob, utType: "public.png", width: 1, height: 1)
        s.insert(Clip(id: blob, kind: .image, capturedAt: base, sourceAppName: "P", sourceBundleID: nil,
                     title: "Image 1×1", payload: payload), limits: limits, now: base)
        s.insert(Clip(id: blob, kind: .image, capturedAt: base.addingTimeInterval(10), sourceAppName: "P", sourceBundleID: nil,
                     title: "Image 1×1", payload: payload), limits: limits, now: base)
        XCTAssertEqual(s.clips.count, 1)
        XCTAssertTrue(dropped.isEmpty)
    }

    func testDeleteClearAllAndBlobCallback() {
        let s = ClipStore()
        var dropped: [UUID] = []
        s.onBlobsDropped = { dropped += $0 }
        let blob = UUID()
        let img = s.insert(Clip(id: blob, kind: .image, sourceAppName: "P", sourceBundleID: nil, title: "Image 1×1",
                                payload: .blob(id: blob, utType: "public.png", width: 1, height: 1)), limits: limits, now: base)
        s.insert(text("t"), limits: limits, now: base)
        s.delete(img.id)
        XCTAssertEqual(dropped, [blob])
        XCTAssertEqual(s.clips.count, 1)
        s.clearAll()
        XCTAssertTrue(s.clips.isEmpty)
    }

    func testOnChangeFiresOncePerMutation() {
        let s = ClipStore()
        var n = 0
        s.onChange = { n += 1 }
        let c = s.insert(text("a"), limits: limits, now: base)
        s.togglePin(c.id)
        s.delete(c.id)
        XCTAssertEqual(n, 3)
    }

    func testHugeTextInsertIsFast() {
        let s = ClipStore()
        let huge = String(repeating: "x", count: 5_000_000)
        measure { s.insert(text(huge), limits: limits, now: base) }
    }

    // MARK: Per-category limits

    func testCategoryCapDropsOldestUnpinnedInThatCategoryOnly() {
        let s = ClipStore()
        let l = ClipLimits(maxStack: 100, retentionDays: 30, perCategory: [.links: 2])
        s.insert(clip(.link, "l1", at: 1), limits: l, now: base)
        s.insert(clip(.text, "t1", at: 2), limits: l, now: base)
        s.insert(clip(.link, "l2", at: 3), limits: l, now: base)
        s.insert(clip(.text, "t2", at: 4), limits: l, now: base)
        s.insert(clip(.link, "l3", at: 5), limits: l, now: base)
        XCTAssertEqual(s.clips.map(\.title), ["l3", "t2", "l2", "t1"])
    }

    func testCategoryCapSkipsPinnedAndDoesNotCountThem() {
        let s = ClipStore()
        let l = ClipLimits(maxStack: 100, retentionDays: 30, perCategory: [.links: 1])
        let pinned = s.insert(clip(.link, "keep", at: 1), limits: l, now: base)
        s.togglePin(pinned.id)
        s.insert(clip(.link, "l2", at: 2), limits: l, now: base)
        s.insert(clip(.link, "l3", at: 3), limits: l, now: base)
        XCTAssertEqual(Set(s.clips.map(\.title)), ["keep", "l3"])
    }

    func testLegacyColorClipsCountTowardText() {
        let s = ClipStore()
        let l = ClipLimits(maxStack: 100, retentionDays: 30, perCategory: [.text: 1])
        s.insert(clip(.color, "#ff0000", at: 1), limits: l, now: base)
        s.insert(clip(.text, "hello", at: 2), limits: l, now: base)
        XCTAssertEqual(s.clips.map(\.title), ["hello"])
    }

    func testGlobalAndCategoryCapsBothApply() {
        let s = ClipStore()
        let l = ClipLimits(maxStack: 3, retentionDays: 30, perCategory: [.text: 1])
        for i in 1...3 { s.insert(clip(.link, "l\(i)", at: TimeInterval(i)), limits: l, now: base) }
        s.insert(clip(.text, "t1", at: 4), limits: l, now: base)
        s.insert(clip(.text, "t2", at: 5), limits: l, now: base)
        // Newest first: t2 fills the text cap, t1 goes; l3 and l2 fill the global cap of 3, l1 goes.
        XCTAssertEqual(s.clips.map(\.title), ["t2", "l3", "l2"])
    }

    func testLoweringCategoryCapViaEnforceDropsImmediatelyAndReportsBlobs() {
        let s = ClipStore()
        var dropped: [UUID] = []
        s.onBlobsDropped = { dropped += $0 }
        let none = ClipLimits(maxStack: 100, retentionDays: 30)
        let ids = (0..<3).map { _ in UUID() }
        for (i, id) in ids.enumerated() {
            s.insert(Clip(id: id, kind: .image, capturedAt: base.addingTimeInterval(TimeInterval(i)), sourceAppName: "P", sourceBundleID: nil,
                          title: "img\(i)", payload: .blob(id: id, utType: "public.png", width: i + 1, height: 1)), limits: none, now: base)
        }
        XCTAssertEqual(s.clips.count, 3)
        s.enforce(limits: ClipLimits(maxStack: 100, retentionDays: 30, perCategory: [.images: 1]), now: base)
        XCTAssertEqual(s.clips.map(\.title), ["img2"])
        XCTAssertEqual(Set(dropped), Set([ids[0], ids[1]]))
    }
}

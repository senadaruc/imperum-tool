import XCTest
@testable import ImperumCore

private let limits = ClipLimits(maxStack: 3, retentionDays: 30)
private let base = Date(timeIntervalSince1970: 1_700_000_000)
private func text(_ s: String, app: String = "A", at t: TimeInterval = 0, pinned: Bool = false) -> Clip {
    Clip(kind: .text, capturedAt: base.addingTimeInterval(t), sourceAppName: app, sourceBundleID: nil, isPinned: pinned, title: s, payload: .text(s))
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
}

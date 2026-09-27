import XCTest
@testable import ImperumCore

final class ClipTests: XCTestCase {
    func testCodableRoundTripForEveryPayload() throws {
        let id = UUID()
        let clips = [
            Clip(kind: .text, sourceAppName: "Notes", sourceBundleID: "com.apple.Notes", title: "hi", payload: .text("hi")),
            Clip(kind: .file, sourceAppName: "Finder", sourceBundleID: "com.apple.finder", title: "a.txt",
                 payload: .fileURLs([URL(fileURLWithPath: "/tmp/a.txt")])),
            Clip(kind: .image, sourceAppName: "Preview", sourceBundleID: nil, title: "Image 2×2",
                 payload: .blob(id: id, utType: "public.png", width: 2, height: 2)),
            Clip(kind: .screenshot, sourceAppName: "CleanShot X", sourceBundleID: "pl.maketheweb.cleanshotx", title: "Screenshot 2×2",
                 payload: .blob(id: id, utType: "public.png", width: 2, height: 2)),
        ]
        let data = try JSONEncoder().encode(clips)
        let back = try JSONDecoder().decode([Clip].self, from: data)
        XCTAssertEqual(back, clips)
    }

    func testContentKeyIgnoresIdentityAndTime() {
        let a = Clip(kind: .text, sourceAppName: "A", sourceBundleID: nil, title: "x", payload: .text("same"))
        let b = Clip(kind: .text, capturedAt: Date(timeIntervalSince1970: 1), sourceAppName: "B",
                     sourceBundleID: "b", isPinned: true, title: "y", payload: .text("same"))
        XCTAssertEqual(a.contentKey, b.contentKey)
        XCTAssertNotEqual(a.contentKey, Clip(kind: .link, sourceAppName: "A", sourceBundleID: nil, title: "x", payload: .text("same")).contentKey)
    }

    /// Old archives never wrote a "richText" key; decoding must not fail and
    /// the property must come back nil. Built by stripping the key from a
    /// real encode, so this doesn't depend on the exact JSON shape.
    func testDecodingClipWithoutRichTextYieldsNil() throws {
        let clip = Clip(kind: .text, sourceAppName: "Notes", sourceBundleID: "com.apple.Notes", title: "hi", payload: .text("hi"))
        var obj = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(clip)) as! [String: Any]
        obj.removeValue(forKey: "richText")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(Clip.self, from: stripped)
        XCTAssertNil(decoded.richText)
    }

    func testRichTextRoundTrips() throws {
        let clip = Clip(kind: .text, sourceAppName: "Word", sourceBundleID: "com.microsoft.Word",
                        title: "hi", payload: .text("hi"), richText: Data([1, 2, 3]))
        let data = try JSONEncoder().encode(clip)
        let back = try JSONDecoder().decode(Clip.self, from: data)
        XCTAssertEqual(back.richText, Data([1, 2, 3]))
        XCTAssertEqual(back, clip)
    }

    func testContentKeyIgnoresRichText() {
        let a = Clip(kind: .text, sourceAppName: "A", sourceBundleID: nil, title: "x", payload: .text("same"), richText: nil)
        let b = Clip(kind: .text, sourceAppName: "A", sourceBundleID: nil, title: "x", payload: .text("same"), richText: Data([9]))
        XCTAssertEqual(a.contentKey, b.contentKey)
    }
}

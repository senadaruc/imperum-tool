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
}

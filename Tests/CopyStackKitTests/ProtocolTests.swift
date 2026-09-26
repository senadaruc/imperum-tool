import XCTest
import ImperumCore
@testable import CopyStackKit

final class ProtocolTests: XCTestCase {
    // MARK: - Request round trip

    func testRequestRoundTripHello() throws {
        try roundTripRequest(.hello(session: "abc"))
        try roundTripRequest(.hello(session: nil))
    }

    func testRequestRoundTripList() throws {
        try roundTripRequest(.list)
    }

    func testRequestRoundTripGet() throws {
        try roundTripRequest(.get(id: UUID()))
    }

    func testRequestRoundTripPaste() throws {
        try roundTripRequest(.paste(id: UUID()))
    }

    func testRequestRoundTripCopy() throws {
        try roundTripRequest(.copy(id: UUID()))
    }

    func testRequestRoundTripPin() throws {
        try roundTripRequest(.pin(id: UUID()))
    }

    func testRequestRoundTripDelete() throws {
        try roundTripRequest(.delete(id: UUID()))
    }

    func testRequestEncodesProtocolVersion() throws {
        let data = try ProtocolCodec.encode(Request.list)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["v"] as? Int, CopyStackKit.protocolVersion)
    }

    private func roundTripRequest(_ request: Request) throws {
        let data = try ProtocolCodec.encode(request)
        switch ProtocolCodec.decodeRequest(data) {
        case .success(let decoded):
            XCTAssertEqual(decoded, request)
        case .failure(let code):
            XCTFail("expected success, got \(code)")
        }
    }

    // MARK: - Response round trip

    func testResponseRoundTripOK() throws {
        try roundTripResponse(.ok)
    }

    func testResponseRoundTripClips() throws {
        // ISO 8601 with fractional seconds only preserves millisecond precision,
        // so pin the fixture to a whole millisecond to get exact Equatable round trips.
        let millisecondDate = Date(timeIntervalSince1970: 1_700_000_000.123)
        let clip = Clip(kind: .text, capturedAt: millisecondDate, sourceAppName: "Test",
                         sourceBundleID: nil, title: "hello", payload: .text("hello"))
        try roundTripResponse(.clips([ClipSummary(clip: clip)]))
    }

    func testResponseRoundTripContentText() throws {
        try roundTripResponse(.content(.text("hello world")))
    }

    func testResponseRoundTripContentFiles() throws {
        try roundTripResponse(.content(.files(["a.txt", "b.txt"])))
    }

    func testResponseRoundTripContentImage() throws {
        try roundTripResponse(.content(.image(width: 100, height: 200)))
    }

    func testResponseRoundTripError() throws {
        for code: Response.ErrorCode in [.disabled, .notFound, .imageMissing, .badRequest, .version] {
            try roundTripResponse(.error(code: code, message: "boom"))
        }
    }

    private func roundTripResponse(_ response: Response) throws {
        let data = try ProtocolCodec.encode(response)
        let decoded = try ProtocolCodec.decodeResponse(data)
        XCTAssertEqual(decoded, response)
    }

    // MARK: - Version / malformed

    func testWrongVersionReturnsVersionError() {
        let data = "{\"v\":2,\"op\":\"list\"}".data(using: .utf8)!
        switch ProtocolCodec.decodeRequest(data) {
        case .success:
            XCTFail("expected failure")
        case .failure(let code):
            XCTAssertEqual(code, .version)
        }
    }

    func testGarbageReturnsBadRequest() {
        let data = "not json at all".data(using: .utf8)!
        switch ProtocolCodec.decodeRequest(data) {
        case .success:
            XCTFail("expected failure")
        case .failure(let code):
            XCTAssertEqual(code, .badRequest)
        }
    }

    func testMalformedRequestWithCorrectVersionReturnsBadRequest() {
        let data = "{\"v\":1,\"op\":\"bogus-op\"}".data(using: .utf8)!
        switch ProtocolCodec.decodeRequest(data) {
        case .success:
            XCTFail("expected failure")
        case .failure(let code):
            XCTAssertEqual(code, .badRequest)
        }
    }

    // MARK: - Preview truncation

    func testPreviewTruncatesAtGraphemeBoundaryAndFitsLimit() {
        var text = String(repeating: "a", count: 2040)
        text += "é"      // 2-byte scalar landing right at the cut boundary
        text += "😀"      // 4-byte scalar landing right at the cut boundary
        text += String(repeating: "b", count: 3000)

        let clip = Clip(kind: .text, sourceAppName: "Test", sourceBundleID: nil, title: "t", payload: .text(text))
        let summary = ClipSummary(clip: clip)

        XCTAssertLessThanOrEqual(summary.preview.utf8.count, ClipSummary.defaultPreviewLimit)
        XCTAssertFalse(summary.preview.isEmpty)
        XCTAssertTrue(text.hasPrefix(summary.preview))
    }

    func testPreviewUnderLimitIsUnchanged() {
        let clip = Clip(kind: .text, sourceAppName: "Test", sourceBundleID: nil, title: "t", payload: .text("short"))
        let summary = ClipSummary(clip: clip)
        XCTAssertEqual(summary.preview, "short")
    }

    // MARK: - asClip round trip

    func testAsClipRoundTripsText() {
        let clip = Clip(kind: .text, sourceAppName: "Notes", sourceBundleID: nil,
                         isPinned: true, title: "hello", payload: .text("hello"))
        let summary = ClipSummary(clip: clip)
        let rebuilt = summary.asClip()
        XCTAssertEqual(rebuilt.id, clip.id)
        XCTAssertEqual(rebuilt.kind, clip.kind)
        XCTAssertEqual(rebuilt.title, clip.title)
        XCTAssertEqual(rebuilt.isPinned, clip.isPinned)
        XCTAssertEqual(rebuilt.capturedAt, clip.capturedAt)
        XCTAssertEqual(rebuilt.payload, .text("hello"))
    }

    func testAsClipRoundTripsFile() {
        let clip = Clip(kind: .file, sourceAppName: "Finder", sourceBundleID: nil,
                         title: "report.pdf", payload: .fileURLs([URL(fileURLWithPath: "/Users/alice/report.pdf")]))
        let summary = ClipSummary(clip: clip)
        let rebuilt = summary.asClip()
        XCTAssertEqual(rebuilt.id, clip.id)
        XCTAssertEqual(rebuilt.kind, clip.kind)
        XCTAssertEqual(rebuilt.title, clip.title)
        XCTAssertEqual(rebuilt.isPinned, clip.isPinned)
        XCTAssertEqual(rebuilt.capturedAt, clip.capturedAt)
        XCTAssertEqual(rebuilt.payload, .fileURLs([URL(fileURLWithPath: "/report.pdf")]))
    }

    func testAsClipRoundTripsImage() {
        let blobID = UUID()
        let clip = Clip(kind: .image, sourceAppName: "Preview", sourceBundleID: nil,
                         title: "screenshot", payload: .blob(id: blobID, utType: "public.png", width: 640, height: 480))
        let summary = ClipSummary(clip: clip)
        let rebuilt = summary.asClip()
        XCTAssertEqual(rebuilt.id, clip.id)
        XCTAssertEqual(rebuilt.kind, clip.kind)
        XCTAssertEqual(rebuilt.title, clip.title)
        XCTAssertEqual(rebuilt.isPinned, clip.isPinned)
        XCTAssertEqual(rebuilt.capturedAt, clip.capturedAt)
        XCTAssertEqual(rebuilt.payload, .blob(id: clip.id, utType: "public.png", width: 640, height: 480))
        XCTAssertEqual(summary.image, ClipSummary.ImageInfo(width: 640, height: 480))
    }

    // MARK: - Date round trip

    func testCapturedAtRoundTripsToTheSecond() throws {
        let clip = Clip(kind: .text, capturedAt: Date(), sourceAppName: "Test", sourceBundleID: nil,
                         title: "t", payload: .text("t"))
        let summary = ClipSummary(clip: clip)
        let response = Response.clips([summary])
        let data = try ProtocolCodec.encode(response)
        let decoded = try ProtocolCodec.decodeResponse(data)
        guard case .clips(let clips) = decoded, let decodedSummary = clips.first else {
            return XCTFail("expected clips")
        }
        XCTAssertEqual(
            decodedSummary.capturedAt.timeIntervalSince1970.rounded(),
            summary.capturedAt.timeIntervalSince1970.rounded()
        )
    }

    // MARK: - LineFramer

    func testFramerSplitsBytesMidLine() {
        var framer = LineFramer()
        let first = framer.feed("hel".data(using: .utf8)!)
        XCTAssertEqual(first, [])
        let second = framer.feed("lo\n".data(using: .utf8)!)
        XCTAssertEqual(second, ["hello".data(using: .utf8)!])
        XCTAssertFalse(framer.overflowed)
    }

    func testFramerHandlesTwoLinesInOneChunk() {
        var framer = LineFramer()
        let lines = framer.feed("one\ntwo\n".data(using: .utf8)!)
        XCTAssertEqual(lines, ["one".data(using: .utf8)!, "two".data(using: .utf8)!])
        XCTAssertFalse(framer.overflowed)
    }

    func testFramerSetsOverflowedOnTooLongLine() {
        var framer = LineFramer(maxLineLength: 65_536)
        let bigLine = Data(repeating: 0x61, count: 70_000)
        let lines = framer.feed(bigLine)
        XCTAssertEqual(lines, [])
        XCTAssertTrue(framer.overflowed)
    }

    func testFramerSetsOverflowedOnCompleteOversizedLine() {
        var framer = LineFramer(maxLineLength: 65_536)
        var oversizedLine = Data(repeating: 0x61, count: 70_000)
        oversizedLine.append(0x0A)
        let lines = framer.feed(oversizedLine)
        XCTAssertEqual(lines, [])
        XCTAssertTrue(framer.overflowed)
    }

    func testFramerReturnsPriorLinesThenOverflowsOnOversizedLineInSameFeed() {
        var framer = LineFramer(maxLineLength: 65_536)
        var chunk = "short\n".data(using: .utf8)!
        var oversizedLine = Data(repeating: 0x62, count: 70_000)
        oversizedLine.append(0x0A)
        chunk.append(oversizedLine)
        let lines = framer.feed(chunk)
        XCTAssertEqual(lines, ["short".data(using: .utf8)!])
        XCTAssertTrue(framer.overflowed)
    }

    func testFramerReturnsNothingAfterOverflow() {
        var framer = LineFramer(maxLineLength: 65_536)
        var oversizedLine = Data(repeating: 0x63, count: 70_000)
        oversizedLine.append(0x0A)
        _ = framer.feed(oversizedLine)
        XCTAssertTrue(framer.overflowed)
        let lines = framer.feed("more\n".data(using: .utf8)!)
        XCTAssertEqual(lines, [])
        XCTAssertTrue(framer.overflowed)
    }
}

import XCTest
@testable import CopyStackKit
import ImperumCore

final class FakeBackend: ClipBackend {
    var storage: [Clip]

    init(_ clips: [Clip]) {
        storage = clips
    }

    var clips: [Clip] { storage }

    func clip(id: UUID) -> Clip? {
        storage.first { $0.id == id }
    }

    func togglePin(_ id: UUID) {
        guard let index = storage.firstIndex(where: { $0.id == id }) else { return }
        storage[index].isPinned.toggle()
    }

    func delete(_ id: UUID) {
        storage.removeAll { $0.id == id }
    }
}

final class RequestHandlerTests: XCTestCase {

    private func assertError(_ response: Response, _ code: Response.ErrorCode, file: StaticString = #filePath, line: UInt = #line) {
        guard case .error(let actualCode, _) = response else {
            return XCTFail("expected .error(\(code)) but got \(response)", file: file, line: line)
        }
        XCTAssertEqual(actualCode, code, file: file, line: line)
    }

    private func makeTextClip(text: String = "hello", kind: ClipKind = .text, pinned: Bool = false) -> Clip {
        Clip(kind: kind, sourceAppName: "TestApp", sourceBundleID: "com.test.app",
             isPinned: pinned, title: "Title", payload: .text(text))
    }

    private func makeFileClip(paths: [String] = ["/tmp/a.txt", "/tmp/b.txt"], kind: ClipKind = .file) -> Clip {
        Clip(kind: kind, sourceAppName: "TestApp", sourceBundleID: "com.test.app",
             title: "Files", payload: .fileURLs(paths.map { URL(fileURLWithPath: $0) }))
    }

    private func makeImageClip(width: Int = 100, height: Int = 200) -> Clip {
        Clip(kind: .image, sourceAppName: "TestApp", sourceBundleID: "com.test.app",
             title: "Image", payload: .blob(id: UUID(), utType: "public.png", width: width, height: height))
    }

    private func makeHandler(clips: [Clip], enabled: Bool = true,
                              onPaste: @escaping (Clip, SessionID?) -> Result<Void, PasteError> = { _, _ in .success(()) },
                              onCopy: @escaping (Clip) -> Bool = { _ in true }) -> (RequestHandler, FakeBackend) {
        let backend = FakeBackend(clips)
        let handler = RequestHandler(backend: backend, isEnabled: { enabled }, onPaste: onPaste, onCopy: onCopy)
        return (handler, backend)
    }

    // MARK: - hello / session tracking

    func testHelloBindsSessionAndReturnsOK() {
        let (handler, _) = makeHandler(clips: [])
        let response = handler.handle(.hello(session: "sess-1"), connection: 1)
        XCTAssertEqual(response, .ok)
        XCTAssertEqual(handler.session(for: 1), "sess-1")
    }

    func testHelloWithoutSessionLeavesNoBinding() {
        let (handler, _) = makeHandler(clips: [])
        let response = handler.handle(.hello(session: nil), connection: 1)
        XCTAssertEqual(response, .ok)
        XCTAssertNil(handler.session(for: 1))
    }

    func testConnectionClosedForgetsSession() {
        let (handler, _) = makeHandler(clips: [])
        _ = handler.handle(.hello(session: "sess-1"), connection: 1)
        XCTAssertEqual(handler.session(for: 1), "sess-1")
        handler.connectionClosed(1)
        XCTAssertNil(handler.session(for: 1))
    }

    func testHelloRecordsPickerPIDAndSessionConnection() {
        let (handler, _) = makeHandler(clips: [])
        _ = handler.handle(.hello(session: "sess-1", pid: 4242), connection: 3)
        XCTAssertEqual(handler.pickerPID(for: 3), 4242)
        XCTAssertEqual(handler.connection(for: "sess-1"), 3)
        XCTAssertNil(handler.connection(for: "other"))
    }

    func testHelloWithoutPIDRecordsNoPID() {
        let (handler, _) = makeHandler(clips: [])
        _ = handler.handle(.hello(session: "sess-1"), connection: 3)
        XCTAssertNil(handler.pickerPID(for: 3))
    }

    /// A pid is only meaningful alongside a session: a standalone `copystack`
    /// (no session) is never a candidate for signalling.
    func testHelloPIDWithoutSessionIsIgnored() {
        let (handler, _) = makeHandler(clips: [])
        _ = handler.handle(.hello(session: nil, pid: 4242), connection: 3)
        XCTAssertNil(handler.pickerPID(for: 3))
    }

    func testConnectionClosedForgetsPIDAndSessionConnection() {
        let (handler, _) = makeHandler(clips: [])
        _ = handler.handle(.hello(session: "sess-1", pid: 4242), connection: 3)
        handler.connectionClosed(3)
        XCTAssertNil(handler.pickerPID(for: 3))
        XCTAssertNil(handler.connection(for: "sess-1"))
    }

    func testHelloWorksEvenWhenDisabled() {
        let (handler, _) = makeHandler(clips: [], enabled: false)
        let response = handler.handle(.hello(session: "sess-1"), connection: 1)
        XCTAssertEqual(response, .ok)
    }

    // MARK: - disabled

    func testAllOpsExceptHelloReturnDisabledWhenNotEnabled() {
        let clip = makeTextClip()
        let (handler, _) = makeHandler(clips: [clip], enabled: false)
        assertError(handler.handle(.list, connection: 1), .disabled)
        assertError(handler.handle(.get(id: clip.id), connection: 1), .disabled)
        assertError(handler.handle(.paste(id: clip.id), connection: 1), .disabled)
        assertError(handler.handle(.copy(id: clip.id), connection: 1), .disabled)
        assertError(handler.handle(.pin(id: clip.id), connection: 1), .disabled)
        assertError(handler.handle(.delete(id: clip.id), connection: 1), .disabled)
    }

    // MARK: - list

    func testListReturnsSummariesInBackendOrder() {
        let clip1 = makeTextClip(text: "first")
        let clip2 = makeFileClip()
        let (handler, _) = makeHandler(clips: [clip1, clip2])
        guard case .clips(let summaries) = handler.handle(.list, connection: 1) else {
            return XCTFail("expected .clips")
        }
        XCTAssertEqual(summaries.map(\.id), [clip1.id, clip2.id])
    }

    func testListPreviewIsTruncatedToDefaultLimit() {
        let longText = String(repeating: "x", count: 5000)
        let clip = makeTextClip(text: longText)
        let (handler, _) = makeHandler(clips: [clip])
        guard case .clips(let summaries) = handler.handle(.list, connection: 1) else {
            return XCTFail("expected .clips")
        }
        XCTAssertLessThanOrEqual(summaries[0].preview.utf8.count, ClipSummary.defaultPreviewLimit)
    }

    // MARK: - get

    func testGetTextReturnsFullPayloadText() {
        let clip = makeTextClip(text: "the full text, not a preview")
        let (handler, _) = makeHandler(clips: [clip])
        let response = handler.handle(.get(id: clip.id), connection: 1)
        XCTAssertEqual(response, .content(.text("the full text, not a preview")))
    }

    func testGetLegacyColorReturnsFullPayloadText() {
        let clip = makeTextClip(text: "#FF0000", kind: .color)
        let (handler, _) = makeHandler(clips: [clip])
        let response = handler.handle(.get(id: clip.id), connection: 1)
        XCTAssertEqual(response, .content(.text("#FF0000")))
    }

    func testGetFileReturnsAbsolutePaths() {
        let clip = makeFileClip(paths: ["/tmp/a.txt", "/tmp/b.txt"], kind: .file)
        let (handler, _) = makeHandler(clips: [clip])
        let response = handler.handle(.get(id: clip.id), connection: 1)
        XCTAssertEqual(response, .content(.files(["/tmp/a.txt", "/tmp/b.txt"])))
    }

    func testGetVideoReturnsAbsolutePaths() {
        let clip = makeFileClip(paths: ["/tmp/movie.mov"], kind: .video)
        let (handler, _) = makeHandler(clips: [clip])
        let response = handler.handle(.get(id: clip.id), connection: 1)
        XCTAssertEqual(response, .content(.files(["/tmp/movie.mov"])))
    }

    func testGetImageReturnsDimensions() {
        let clip = makeImageClip(width: 640, height: 480)
        let (handler, _) = makeHandler(clips: [clip])
        let response = handler.handle(.get(id: clip.id), connection: 1)
        XCTAssertEqual(response, .content(.image(width: 640, height: 480)))
    }

    func testGetNotFound() {
        let (handler, _) = makeHandler(clips: [])
        let response = handler.handle(.get(id: UUID()), connection: 1)
        assertError(response, .notFound)
    }

    // MARK: - paste

    func testPastePassesClipAndBoundSessionToOnPaste() {
        let clip = makeTextClip()
        var receivedClip: Clip?
        var receivedSession: SessionID?
        let (handler, _) = makeHandler(clips: [clip], onPaste: { clip, session in
            receivedClip = clip
            receivedSession = session
            return .success(())
        })
        _ = handler.handle(.hello(session: "sess-9"), connection: 1)
        let response = handler.handle(.paste(id: clip.id), connection: 1)
        XCTAssertEqual(response, .ok)
        XCTAssertEqual(receivedClip?.id, clip.id)
        XCTAssertEqual(receivedSession, "sess-9")
    }

    func testPasteWithoutBoundSessionPassesNil() {
        let clip = makeTextClip()
        var receivedSession: SessionID??
        let (handler, _) = makeHandler(clips: [clip], onPaste: { _, session in
            receivedSession = session
            return .success(())
        })
        _ = handler.handle(.paste(id: clip.id), connection: 1)
        XCTAssertEqual(receivedSession, .some(nil))
    }

    func testPasteMapsImageMissingError() {
        let clip = makeImageClip()
        let (handler, _) = makeHandler(clips: [clip], onPaste: { _, _ in .failure(.imageMissing) })
        let response = handler.handle(.paste(id: clip.id), connection: 1)
        assertError(response, .imageMissing)
    }

    func testPasteMapsDisabledError() {
        let clip = makeTextClip()
        let (handler, _) = makeHandler(clips: [clip], onPaste: { _, _ in .failure(.disabled) })
        let response = handler.handle(.paste(id: clip.id), connection: 1)
        assertError(response, .disabled)
    }

    func testPasteNotFound() {
        let (handler, _) = makeHandler(clips: [])
        let response = handler.handle(.paste(id: UUID()), connection: 1)
        assertError(response, .notFound)
    }

    // MARK: - copy

    func testCopySuccessReturnsOK() {
        let clip = makeTextClip()
        let (handler, _) = makeHandler(clips: [clip], onCopy: { _ in true })
        let response = handler.handle(.copy(id: clip.id), connection: 1)
        XCTAssertEqual(response, .ok)
    }

    func testCopyFailureReturnsImageMissing() {
        let clip = makeImageClip()
        let (handler, _) = makeHandler(clips: [clip], onCopy: { _ in false })
        let response = handler.handle(.copy(id: clip.id), connection: 1)
        assertError(response, .imageMissing)
    }

    func testCopyNotFound() {
        let (handler, _) = makeHandler(clips: [])
        let response = handler.handle(.copy(id: UUID()), connection: 1)
        assertError(response, .notFound)
    }

    // MARK: - pin

    func testPinTogglesAndReturnsUpdatedList() {
        let clip = makeTextClip(pinned: false)
        let (handler, backend) = makeHandler(clips: [clip])
        let response = handler.handle(.pin(id: clip.id), connection: 1)
        guard case .clips(let summaries) = response else {
            return XCTFail("expected .clips")
        }
        XCTAssertEqual(summaries.first(where: { $0.id == clip.id })?.isPinned, true)
        XCTAssertEqual(backend.clip(id: clip.id)?.isPinned, true)
    }

    func testPinNotFound() {
        let (handler, _) = makeHandler(clips: [])
        let response = handler.handle(.pin(id: UUID()), connection: 1)
        assertError(response, .notFound)
    }

    // MARK: - delete

    func testDeleteRemovesClipAndReturnsUpdatedList() {
        let clip1 = makeTextClip(text: "keep")
        let clip2 = makeTextClip(text: "remove")
        let (handler, backend) = makeHandler(clips: [clip1, clip2])
        let response = handler.handle(.delete(id: clip2.id), connection: 1)
        guard case .clips(let summaries) = response else {
            return XCTFail("expected .clips")
        }
        XCTAssertEqual(summaries.map(\.id), [clip1.id])
        XCTAssertNil(backend.clip(id: clip2.id))
    }

    func testDeleteNotFound() {
        let (handler, _) = makeHandler(clips: [])
        let response = handler.handle(.delete(id: UUID()), connection: 1)
        assertError(response, .notFound)
    }
}

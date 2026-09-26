import CryptoKit
import XCTest
@testable import ImperumCore

final class ClipArchiveTests: XCTestCase {
    private var dir: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClipArchiveTests-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func archive(_ k: SymmetricKey? = nil) -> ClipArchive {
        ClipArchive(directory: dir, keyProvider: StaticKeyProvider(key: k ?? key))
    }
    private func clip(_ s: String) -> Clip {
        Clip(kind: .text, sourceAppName: "A", sourceBundleID: nil, title: s, payload: .text(s))
    }

    func testMissingIndexLoadsEmpty() throws {
        XCTAssertEqual(try archive().loadIndex(), [])
    }

    func testIndexRoundTripAndPermissions() throws {
        let a = archive()
        let clips = [clip("one"), clip("two")]
        try a.saveIndex(clips)
        XCTAssertEqual(try a.loadIndex(), clips)
        let path = dir.appendingPathComponent("index.bin").path
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! Int
        XCTAssertEqual(perms & 0o777, 0o600)
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertNil(String(data: raw, encoding: .utf8)?.range(of: "one"))      // not plaintext
    }

    func testWrongKeyOrTamperThrowsCorrupt() throws {
        let a = archive()
        try a.saveIndex([clip("x")])
        XCTAssertThrowsError(try archive(SymmetricKey(size: .bits256)).loadIndex()) { e in
            XCTAssertEqual(e as? ClipArchiveError, .corrupt)
        }
        let path = dir.appendingPathComponent("index.bin")
        var raw = try Data(contentsOf: path)
        raw[raw.count / 2] ^= 0xFF
        try raw.write(to: path)
        XCTAssertThrowsError(try a.loadIndex()) { e in XCTAssertEqual(e as? ClipArchiveError, .corrupt) }
    }

    func testBlobsRoundTripSweepAndDelete() throws {
        let a = archive()
        let id1 = UUID(), id2 = UUID()
        try a.saveBlob(Data([1, 2, 3]), id: id1)
        try a.saveBlob(Data([9]), id: id1, suffix: "thumb.png")
        try a.saveBlob(Data([4]), id: id2)
        XCTAssertEqual(a.loadBlob(id: id1), Data([1, 2, 3]))
        XCTAssertEqual(a.loadBlob(id: id1, suffix: "thumb.png"), Data([9]))
        a.sweepBlobs(keeping: [id1])
        XCTAssertNil(a.loadBlob(id: id2))
        XCTAssertNotNil(a.loadBlob(id: id1))
        a.deleteBlobs([id1])
        XCTAssertNil(a.loadBlob(id: id1))
        XCTAssertNil(a.loadBlob(id: id1, suffix: "thumb.png"))
    }

    func testDeleteAllRemovesDirectoryContents() throws {
        let a = archive()
        try a.saveIndex([clip("x")])
        try a.saveBlob(Data([1]), id: UUID())
        try a.deleteAll()
        XCTAssertEqual(try a.loadIndex(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("blobs").path), [])
    }
}

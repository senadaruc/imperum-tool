import XCTest
@testable import ImperumCore

final class ScreenshotDetectorTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func desktop() -> ScreenshotRoot { ScreenshotRoot(url: home.appendingPathComponent("Desktop", isDirectory: true), source: .native, dedicated: false) }
    private func media() -> ScreenshotRoot {
        ScreenshotRoot(url: home.appendingPathComponent("Library/Application Support/CleanShot/media", isDirectory: true), source: .cleanShot, dedicated: true)
    }
    private func event(_ name: String, root: ScreenshotRoot, created: TimeInterval = 10, size: Int = 100, tagged: Bool = false) -> FileEvent {
        FileEvent(url: root.url.appendingPathComponent(name), root: root, createdAt: t0.addingTimeInterval(created), byteSize: size, isTaggedScreenCapture: tagged)
    }

    // MARK: Roots

    func testRootsDefaultToDesktopAndCleanShotMedia() {
        let r = ScreenshotDetector.roots(nativeLocation: nil, cleanShotExportPath: nil, home: home)
        XCTAssertEqual(r, [desktop(), media()])
        XCTAssertEqual(ScreenshotDetector.roots(nativeLocation: "", cleanShotExportPath: nil, home: home), [desktop(), media()])
    }

    func testRootsPreserveTrailingSpaceAndExpandTilde() {
        let r = ScreenshotDetector.roots(nativeLocation: "/Volumes/Backup/imperum private ", cleanShotExportPath: "~/Desktop/Screenshots", home: home)
        XCTAssertEqual(r[0], ScreenshotRoot(url: URL(fileURLWithPath: "/Volumes/Backup/imperum private ", isDirectory: true), source: .native, dedicated: true))
        XCTAssertEqual(r[1], media())
        XCTAssertEqual(r[2], ScreenshotRoot(url: home.appendingPathComponent("Desktop/Screenshots", isDirectory: true), source: .cleanShot, dedicated: true))
        XCTAssertEqual(r.count, 3)
    }

    func testRootsCollapseDuplicatesKeepingDedicated() {
        let r = ScreenshotDetector.roots(nativeLocation: "~/Desktop/Screenshots", cleanShotExportPath: "/Users/me/Desktop/Screenshots/", home: home)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].url.standardizedFileURL.path, "/Users/me/Desktop/Screenshots")
        XCTAssertTrue(r[0].dedicated)
        XCTAssertEqual(r[1], media())
    }

    func testSourceTitlesAndBundles() {
        XCTAssertEqual(ScreenshotSource.native.title, "Screenshot")
        XCTAssertEqual(ScreenshotSource.native.bundleID, "com.apple.screencapture")
        XCTAssertEqual(ScreenshotSource.cleanShot.title, "CleanShot X")
        XCTAssertEqual(ScreenshotSource.cleanShot.bundleID, "pl.maketheweb.cleanshotx")
    }

    // MARK: Native name pattern

    func testNativeNamePatternAcrossLocales() {
        XCTAssertTrue(ScreenshotDetector.matchesNativeName("Screenshot 2026-09-27 at 11.06.37.png"))
        XCTAssertTrue(ScreenshotDetector.matchesNativeName("Bildschirmfoto 2026-09-27 um 11.06.37.png"))
        XCTAssertTrue(ScreenshotDetector.matchesNativeName("Screenshot 2026-09-27 at 11.06.37 (2).png"))
        XCTAssertFalse(ScreenshotDetector.matchesNativeName("holiday.png"))
        XCTAssertFalse(ScreenshotDetector.matchesNativeName("report 2026-09-27.png"))
    }

    // MARK: Verdicts

    func testSettleRequiresTwoEqualNonZeroSizes() {
        var d = ScreenshotDetector(startedAt: t0)
        XCTAssertEqual(d.verdict(for: event("a.png", root: media(), size: 0)), .settle)
        XCTAssertEqual(d.verdict(for: event("a.png", root: media(), size: 500)), .settle, "size changed")
        XCTAssertEqual(d.verdict(for: event("a.png", root: media(), size: 900)), .settle, "still growing")
        XCTAssertEqual(d.verdict(for: event("a.png", root: media(), size: 900)), .accept(.cleanShot))
    }

    func testExtensionsAreFilteredCaseInsensitively() {
        var d = ScreenshotDetector(startedAt: t0)
        XCTAssertEqual(d.verdict(for: event("a.txt", root: media())), .ignore)
        XCTAssertEqual(d.verdict(for: event("a.mov", root: media())), .ignore)
        XCTAssertEqual(d.verdict(for: event("A.HEIC", root: media())), .settle)
        XCTAssertEqual(d.verdict(for: event("A.HEIC", root: media())), .accept(.cleanShot))
    }

    func testFilesCreatedBeforeStartAreIgnored() {
        var d = ScreenshotDetector(startedAt: t0)
        XCTAssertEqual(d.verdict(for: event("old.png", root: media(), created: -1)), .ignore)
        XCTAssertEqual(d.verdict(for: event("old.png", root: media(), created: -1)), .ignore)
        XCTAssertEqual(d.verdict(for: event("new.png", root: media(), created: 0)), .settle, "created exactly at start counts")
    }

    func testSharedDesktopNeedsTagOrNativeName() {
        var d = ScreenshotDetector(startedAt: t0)
        _ = d.verdict(for: event("holiday.png", root: desktop()))
        XCTAssertEqual(d.verdict(for: event("holiday.png", root: desktop())), .ignore, "random image on the Desktop")
        _ = d.verdict(for: event("Screenshot 2026-09-27 at 11.06.37.png", root: desktop()))
        XCTAssertEqual(d.verdict(for: event("Screenshot 2026-09-27 at 11.06.37.png", root: desktop())), .accept(.native))
        _ = d.verdict(for: event("tagged.png", root: desktop(), tagged: true))
        XCTAssertEqual(d.verdict(for: event("tagged.png", root: desktop(), tagged: true)), .accept(.native))
        let custom = ScreenshotRoot(url: URL(fileURLWithPath: "/Volumes/Shots", isDirectory: true), source: .native, dedicated: true)
        _ = d.verdict(for: event("anything.jpg", root: custom))
        XCTAssertEqual(d.verdict(for: event("anything.jpg", root: custom)), .accept(.native), "dedicated folder accepts any image")
    }

    func testAcceptedFileIsNotReimportedOnLaterEvents() {
        var d = ScreenshotDetector(startedAt: t0)
        _ = d.verdict(for: event("a.png", root: media()))
        XCTAssertEqual(d.verdict(for: event("a.png", root: media())), .accept(.cleanShot))
        XCTAssertEqual(d.verdict(for: event("a.png", root: media())), .ignore, "xattr/rename churn after import")
        XCTAssertEqual(d.verdict(for: event("a.png", root: media(), size: 101)), .ignore)
    }

    // MARK: Dedupe

    func testDuplicateBySizeWithinFiveSecondsEitherOrder() {
        var d = ScreenshotDetector(startedAt: t0)
        XCTAssertFalse(d.isDuplicate(width: 800, height: 600, at: t0))
        XCTAssertTrue(d.isDuplicate(width: 800, height: 600, at: t0.addingTimeInterval(2)), "copy after save")
        XCTAssertFalse(d.isDuplicate(width: 801, height: 600, at: t0.addingTimeInterval(2)), "different size")
        XCTAssertFalse(d.isDuplicate(width: 800, height: 600, at: t0.addingTimeInterval(6)), "outside the window")
        XCTAssertTrue(d.isDuplicate(width: 800, height: 600, at: t0.addingTimeInterval(7)), "the 6 s sighting was recorded")
        XCTAssertEqual(ScreenshotDetector.dedupeWindow, 5)
        XCTAssertEqual(ScreenshotDetector.settleDelay, 0.3)
    }
}

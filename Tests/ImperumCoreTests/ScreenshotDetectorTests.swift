import XCTest
@testable import ImperumCore

final class ScreenshotDetectorTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    /// Advances by `dt` (default: comfortably past `settleDelay`) on every sighting.
    private var clock: TimeInterval = 20
    private func desktop() -> ScreenshotRoot { ScreenshotRoot(url: home.appendingPathComponent("Desktop", isDirectory: true), source: .native, dedicated: false) }
    private func media() -> ScreenshotRoot {
        ScreenshotRoot(url: home.appendingPathComponent("Library/Application Support/CleanShot/media", isDirectory: true), source: .cleanShot, dedicated: true)
    }
    private func event(_ name: String, root: ScreenshotRoot, created: TimeInterval = 10, size: Int = 100, tagged: Bool = false) -> FileEvent {
        FileEvent(url: root.url.appendingPathComponent(name), root: root, createdAt: t0.addingTimeInterval(created), byteSize: size, isTaggedScreenCapture: tagged)
    }
    private func see(_ d: inout ScreenshotDetector, _ e: FileEvent, dt: TimeInterval = 1) -> FileVerdict {
        clock += dt
        return d.verdict(for: e, at: t0.addingTimeInterval(clock))
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

    /// CleanShot's default export folder is the Desktop: that must not turn
    /// every image landing on the Desktop into a "screenshot".
    func testDesktopIsNeverDedicatedEvenAsCleanShotExport() {
        let r = ScreenshotDetector.roots(nativeLocation: nil, cleanShotExportPath: "~/Desktop", home: home)
        XCTAssertEqual(r, [desktop(), media()])
        var d = ScreenshotDetector(startedAt: t0)
        _ = see(&d, event("download.jpg", root: r[0]))
        XCTAssertEqual(see(&d, event("download.jpg", root: r[0])), .ignore)
        _ = see(&d, event("CleanShot 2026-09-27 at 11.06.37@2x.png", root: r[0]))
        XCTAssertEqual(see(&d, event("CleanShot 2026-09-27 at 11.06.37@2x.png", root: r[0])), .accept(.cleanShot),
                       "CleanShot's own file name on the Desktop is attributed to CleanShot")
    }

    func testRootLookupPicksLongestMatchOnAPathBoundary() {
        let roots = [desktop(), media(),
                     ScreenshotRoot(url: home.appendingPathComponent("Desktop/Screenshots", isDirectory: true), source: .cleanShot, dedicated: true)]
        XCTAssertEqual(ScreenshotDetector.root(for: "/Users/me/Desktop/Screenshots/a.png", in: roots)?.source, .cleanShot)
        XCTAssertEqual(ScreenshotDetector.root(for: "/Users/me/Desktop/a.png", in: roots)?.source, .native)
        XCTAssertNil(ScreenshotDetector.root(for: "/Users/me/Desktop Old/a.png", in: roots), "no match without a / boundary")
        XCTAssertEqual(ScreenshotDetector.root(for: "/Users/me/Library/Application Support/CleanShot/media/media_x/c.png", in: roots), media())
        XCTAssertEqual(ScreenshotDetector.streamPaths(roots), ["/Users/me/Desktop", "/Users/me/Library/Application Support/CleanShot/media"],
                       "nested roots are covered by their ancestor's stream")
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
        XCTAssertEqual(see(&d, event("a.png", root: media(), size: 0)), .settle)
        XCTAssertEqual(see(&d, event("a.png", root: media(), size: 500)), .settle, "size changed")
        XCTAssertEqual(see(&d, event("a.png", root: media(), size: 900)), .settle, "still growing")
        XCTAssertEqual(see(&d, event("a.png", root: media(), size: 900)), .accept(.cleanShot))
    }

    /// Two sightings milliseconds apart (one FSEvents batch, or two overlapping
    /// re-check chains) prove nothing about a writer pausing between chunks.
    func testEqualSizesCloserThanSettleDelayDoNotAccept() {
        var d = ScreenshotDetector(startedAt: t0)
        XCTAssertEqual(see(&d, event("a.png", root: media(), size: 900)), .settle)
        XCTAssertEqual(see(&d, event("a.png", root: media(), size: 900), dt: 0.01), .settle, "too soon")
        XCTAssertEqual(see(&d, event("a.png", root: media(), size: 900), dt: 0.05), .settle, "still too soon; the first sighting's time is kept")
        XCTAssertEqual(see(&d, event("a.png", root: media(), size: 900), dt: ScreenshotDetector.settleDelay), .accept(.cleanShot))
    }

    func testFileThatNeverSettlesIsGivenUp() {
        var d = ScreenshotDetector(startedAt: t0)
        for _ in 0..<ScreenshotDetector.maxSettleAttempts - 1 {
            XCTAssertEqual(see(&d, event("empty.png", root: media(), size: 0)), .settle)
        }
        XCTAssertEqual(see(&d, event("empty.png", root: media(), size: 0)), .ignore, "cap reached")
        XCTAssertEqual(see(&d, event("empty.png", root: media(), size: 50)), .ignore, "stays given up")
    }

    func testExtensionsAreFilteredCaseInsensitively() {
        var d = ScreenshotDetector(startedAt: t0)
        XCTAssertEqual(see(&d, event("a.txt", root: media())), .ignore)
        XCTAssertEqual(see(&d, event("a.mov", root: media())), .ignore)
        XCTAssertEqual(see(&d, event("A.HEIC", root: media())), .settle)
        XCTAssertEqual(see(&d, event("A.HEIC", root: media())), .accept(.cleanShot))
    }

    func testFilesCreatedBeforeStartAreIgnored() {
        var d = ScreenshotDetector(startedAt: t0)
        XCTAssertEqual(see(&d, event("old.png", root: media(), created: -1)), .ignore)
        XCTAssertEqual(see(&d, event("old.png", root: media(), created: -1)), .ignore)
        XCTAssertEqual(see(&d, event("new.png", root: media(), created: 0)), .settle, "created exactly at start counts")
    }

    func testSharedDesktopNeedsTagOrNativeName() {
        var d = ScreenshotDetector(startedAt: t0)
        _ = see(&d, event("holiday.png", root: desktop()))
        XCTAssertEqual(see(&d, event("holiday.png", root: desktop())), .ignore, "random image on the Desktop")
        _ = see(&d, event("Screenshot 2026-09-27 at 11.06.37.png", root: desktop()))
        XCTAssertEqual(see(&d, event("Screenshot 2026-09-27 at 11.06.37.png", root: desktop())), .accept(.native))
        _ = see(&d, event("tagged.png", root: desktop(), tagged: true))
        XCTAssertEqual(see(&d, event("tagged.png", root: desktop(), tagged: true)), .accept(.native))
        let custom = ScreenshotRoot(url: URL(fileURLWithPath: "/Volumes/Shots", isDirectory: true), source: .native, dedicated: true)
        _ = see(&d, event("anything.jpg", root: custom))
        XCTAssertEqual(see(&d, event("anything.jpg", root: custom)), .accept(.native), "dedicated folder accepts any image")
    }

    func testAcceptedFileIsNotReimportedOnLaterEvents() {
        var d = ScreenshotDetector(startedAt: t0)
        _ = see(&d, event("a.png", root: media()))
        XCTAssertEqual(see(&d, event("a.png", root: media())), .accept(.cleanShot))
        XCTAssertEqual(see(&d, event("a.png", root: media())), .ignore, "xattr/rename churn after import")
        XCTAssertEqual(see(&d, event("a.png", root: media(), size: 101)), .ignore)
    }

    // MARK: Cross-channel counterpart (save + copy of the same shot)

    func testCounterpartMatchesOnlyAcrossChannelsWithinTheWindow() {
        var d = ScreenshotDetector(startedAt: t0)
        let file1 = UUID(), paste1 = UUID(), file2 = UUID(), paste2 = UUID(), paste3 = UUID()
        XCTAssertNil(d.counterpart(width: 800, height: 600, channel: .file, clipID: file1, at: t0))
        XCTAssertNil(d.counterpart(width: 800, height: 600, channel: .file, clipID: file2, at: t0.addingTimeInterval(1)),
                     "two saved shots of the same size are both real")
        XCTAssertEqual(d.counterpart(width: 800, height: 600, channel: .pasteboard, clipID: paste1, at: t0.addingTimeInterval(2)), file1,
                       "copy after save → the saved one, oldest first")
        XCTAssertEqual(d.counterpart(width: 800, height: 600, channel: .pasteboard, clipID: paste2, at: t0.addingTimeInterval(2)), file2,
                       "each entry is consumed once")
        XCTAssertNil(d.counterpart(width: 800, height: 600, channel: .pasteboard, clipID: paste3, at: t0.addingTimeInterval(3)),
                     "nothing left to pair with; recorded")
        XCTAssertEqual(d.counterpart(width: 800, height: 600, channel: .file, clipID: UUID(), at: t0.addingTimeInterval(4)), paste3,
                       "save after copy → the copied one")
        XCTAssertNil(d.counterpart(width: 801, height: 600, channel: .pasteboard, clipID: UUID(), at: t0.addingTimeInterval(4)), "different size")
        XCTAssertNil(d.counterpart(width: 640, height: 480, channel: .pasteboard, clipID: UUID(), at: t0.addingTimeInterval(20)))
        XCTAssertNil(d.counterpart(width: 640, height: 480, channel: .file, clipID: UUID(), at: t0.addingTimeInterval(26)), "outside the window")
        XCTAssertEqual(ScreenshotDetector.dedupeWindow, 5)
        XCTAssertEqual(ScreenshotDetector.settleDelay, 0.3)
    }
}

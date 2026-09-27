# Screenshots Category Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give screenshots their own Copy Stack category and make every screenshot, copied or saved to disk, from macOS or CleanShot X, land in the stack automatically as a pasteable image.

**Architecture:** A new `ClipKind.screenshot` / `ClipCategory.screenshots` pair flows through the existing category mapping (chips, caps, picker). Pure decision logic lives in `ImperumCore` (`ScreenshotDetector`: root resolution, file accept rules, size-and-time dedupe; `ClipCapture`: the single-PNG pasteboard signature). AppKit glue lives in `ImperumTool` (`ScreenshotWatcher`: FSEvents adapter; `ScreenshotImporter`: owns watcher + detector, reads files, produces `CapturedClip`s for the controller's existing insert path). One settings toggle and a status caption.

**Tech Stack:** Swift 5 language mode, SwiftPM, SwiftUI + AppKit, CoreServices FSEvents, `getxattr`, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-27-screenshots-category-design.md`

## Global Constraints

- Platform floor `macOS 14` (`Package.swift`); `swift-tools-version: 5.9`; Swift 5 language mode.
- **Build and test only with the Xcode toolchain.** Every `swift build` / `swift test` below is prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Baseline before Task 1: 181 ImperumCore + 264 CopyStackKit tests pass (445 total, as README states).
- Pure logic in `ImperumCore` (no AppKit, no CoreServices import); AppKit/FSEvents only in `ImperumTool`.
- Chip order after this plan: All · Text · Links · Emails · Images · Screenshots · Videos · Files.
- Screenshot titles: `"Screenshot W×H"` (U+00D7 multiplication sign, same as image titles).
- Sources: native → `sourceAppName "Screenshot"`, `sourceBundleID "com.apple.screencapture"`; CleanShot → `"CleanShot X"`, `"pl.maketheweb.cleanshotx"`.
- Accepted file extensions: `png`, `jpg`, `jpeg`, `heic` (case-insensitive). Dedupe window: 5 seconds. Settle re-check: 300 ms. FSEvents latency: 0.2 s.
- Watched roots: native location from `com.apple.screencapture` `location` (trailing whitespace preserved, `~` expanded, empty/absent → `~/Desktop`); CleanShot media `~/Library/Application Support/CleanShot/media` (recursive); CleanShot export from `pl.maketheweb.cleanshotx` `exportPath` (absent → not watched).
- Never write, move or delete anything under a watched root. Never backfill files that predate the watcher.
- Commit messages: `feat(clipboard): …` / `docs(clipboard): …`, each ending with
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01WjvQwPfzAtrMWx96uCLxNM
  ```
- Work on a feature branch `feat/screenshots-category` cut from `main` (the tree on `main` has one unrelated uncommitted change to `make-dmg.sh`; leave it alone, do not `git add -A`).

## Review Focus

1. **A file that is still being written when FSEvents reports it** (CleanShot writes large PNGs in chunks) must not be imported half-way: the detector must answer `.settle` until two sightings agree on a non-zero size. Pinned in Task 3 (`testSettleRequiresTwoEqualNonZeroSizes`).
2. **A screenshot saved AND copied by CleanShot** (copy-after-capture on) must produce one clip, whichever event arrives first. Pinned in Task 3 (`testDuplicateBySizeWithinFiveSecondsEitherOrder`) and Task 5 (poll path consults the same detector).
3. **An old file touched by Finder or Spotlight** (xattr change, rename) after the watcher started must not be imported: creation date before start, or already-accepted URL, both ignore. Pinned in Task 3 (`testFilesCreatedBeforeStartAreIgnored`, `testAcceptedFileIsNotReimportedOnLaterEvents`).
4. **A browser "Copy Image"** must stay an Image: only a pasteboard with exactly one item whose only type is `public.png` is a screenshot. Pinned in Task 2 (`testOnlyASinglePNGItemIsAScreenshot`).
5. **A native screenshot location on an unmounted volume** (this Mac's is `/Volumes/Backup/imperum private `) must not crash or wedge the watcher, and must start working on mount. Pinned in Task 3 for resolution (`testRootsPreserveTrailingSpaceAndExpandTilde`) and Task 5 for the mount notification; the caption is on Task 6's manual checklist.

---

### Task 1: `ClipKind.screenshot` and `ClipCategory.screenshots` through every switch

**Files:**
- Modify: `Sources/ImperumCore/Clip.swift:3-11` (`ClipKind`)
- Modify: `Sources/ImperumCore/ClipQuery.swift:3-52` (`ClipCategory`)
- Modify: `Sources/ImperumCore/ClipClassifier.swift:81` (title helper)
- Modify: `Sources/CopyStackKit/Protocol.swift:63-108` (two switches)
- Modify: `Sources/CopyStackKit/RequestHandler.swift:129-148` (switch)
- Modify: `Sources/CopyStackKit/FrameRenderer.swift:177-186` (glyph)
- Modify: `Sources/ImperumTool/CopyStackView.swift:141-157` (row glyph)
- Test: `Tests/ImperumCoreTests/ClipQueryTests.swift`, `Tests/ImperumCoreTests/ClipTests.swift`, `Tests/ImperumCoreTests/ClipStoreTests.swift`, `Tests/CopyStackKitTests/FrameRendererTests.swift`, `Tests/CopyStackKitTests/ProtocolTests.swift`

**Interfaces:**
- Produces: `ClipKind.screenshot`; `ClipCategory.screenshots` (between `.images` and `.videos`, `kind == .screenshot`, `title == "Screenshots"`, `ClipCategory(kind: .screenshot) == .screenshots`); `ClipClassifier.title(screenshotWidth:height:) -> String`.

- [ ] **Step 1: Write the failing tests**

In `Tests/ImperumCoreTests/ClipQueryTests.swift`, change the assertion on line 21 to:

```swift
        XCTAssertEqual(ClipCategory.allCases.map(\.title), ["All", "Text", "Links", "Emails", "Images", "Screenshots", "Videos", "Files"])
        XCTAssertEqual(ClipCategory.screenshots.kind, .screenshot)
```

In the same file, inside `testEveryKindMapsToOneCategoryForLimits`, after the `.image` line add:

```swift
        XCTAssertEqual(ClipCategory(kind: .screenshot), .screenshots)
```

Append inside `final class ClipQueryTests`:

```swift
    func testScreenshotsCategoryFiltersOnlyScreenshots() {
        let shot = Clip(kind: .screenshot, sourceAppName: "Screenshot", sourceBundleID: "com.apple.screencapture", title: "Screenshot 2×2",
                        payload: .blob(id: UUID(), utType: "public.png", width: 2, height: 2))
        let img = Clip(kind: .image, sourceAppName: "Safari", sourceBundleID: nil, title: "Image 2×2",
                       payload: .blob(id: UUID(), utType: "public.png", width: 2, height: 2))
        XCTAssertEqual(ClipFilter.apply([shot, img], category: .screenshots, query: "").map(\.id), [shot.id])
        XCTAssertEqual(ClipFilter.apply([shot, img], category: .images, query: "").map(\.id), [img.id])
        XCTAssertEqual(ClipFilter.apply([shot, img], category: .all, query: "").count, 2)
        XCTAssertEqual(ClipClassifier.title(screenshotWidth: 1280, height: 800), "Screenshot 1280×800")
    }
```

In `Tests/ImperumCoreTests/ClipTests.swift`, inside `testCodableRoundTripForEveryPayload`, add to the `clips` array after the `.image` entry:

```swift
            Clip(kind: .screenshot, sourceAppName: "CleanShot X", sourceBundleID: "pl.maketheweb.cleanshotx", title: "Screenshot 2×2",
                 payload: .blob(id: id, utType: "public.png", width: 2, height: 2)),
```

Append inside `final class ClipStoreTests` in `Tests/ImperumCoreTests/ClipStoreTests.swift`:

```swift
    func testScreenshotsCapDropsOnlyScreenshots() {
        let s = ClipStore()
        let l = ClipLimits(maxStack: 100, retentionDays: 30, perCategory: [.screenshots: 1])
        s.insert(clip(.screenshot, "s1", at: 1), limits: l, now: base)
        s.insert(clip(.image, "i1", at: 2), limits: l, now: base)
        s.insert(clip(.screenshot, "s2", at: 3), limits: l, now: base)
        XCTAssertEqual(s.clips.map(\.title), ["s2", "i1"])
    }
```

In `Tests/CopyStackKitTests/FrameRendererTests.swift`, change line 58 to:

```swift
        XCTAssertTrue(lines[1].hasPrefix("[All]  Text  Links  Emails  Images  Screenshots  Videos  Files"))
```

Append inside the `final class` in `Tests/CopyStackKitTests/ProtocolTests.swift`, before its closing brace:

```swift
    func testScreenshotSummaryRoundTripsLikeAnImage() throws {
        let blobID = UUID()
        let clip = Clip(kind: .screenshot, sourceAppName: "CleanShot X", sourceBundleID: "pl.maketheweb.cleanshotx",
                        title: "Screenshot 640×480", payload: .blob(id: blobID, utType: "public.png", width: 640, height: 480))
        let summary = ClipSummary(clip: clip)
        XCTAssertEqual(summary.kind, .screenshot)
        XCTAssertEqual(summary.image, ClipSummary.ImageInfo(width: 640, height: 480))
        let data = try JSONEncoder().encode(summary)
        let back = try JSONDecoder().decode(ClipSummary.self, from: data)
        XCTAssertEqual(back.asClip().kind, .screenshot)
        XCTAssertEqual(back.asClip().payload, .blob(id: clip.id, utType: "public.png", width: 640, height: 480))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'ClipQueryTests|ClipTests|ClipStoreTests|FrameRendererTests|ProtocolTests' 2>&1 | grep -E 'error:' | head -5`
Expected: compile errors — `type 'ClipKind' has no member 'screenshot'`, `type 'ClipCategory' has no member 'screenshots'`.

- [ ] **Step 3: Implement**

`Sources/ImperumCore/Clip.swift`, replace the `ClipKind` enum:

```swift
public enum ClipKind: String, Codable, CaseIterable, Hashable {
    case text, link, email
    /// Legacy: no longer produced (round 10 removed the Colors category —
    /// a colour-shaped string is now just `.text`). Kept so archives written
    /// before round 10 still decode; `ClipCategory.text` also matches this
    /// kind so old colour clips stay reachable in the panel.
    case color
    case image, video, file
    /// A screenshot (native macOS or CleanShot X), copied or saved to disk.
    /// Same `.blob` payload as `.image`; only the category differs.
    case screenshot
}
```

`Sources/ImperumCore/ClipQuery.swift`, in `ClipCategory`:
- change the case list to `case all, text, links, emails, images, screenshots, videos, files`
- in `kind`, after `case .images: return .image` add `case .screenshots: return .screenshot`
- in `title`, after `case .images: return "Images"` add `case .screenshots: return "Screenshots"`
- in `init(kind:)`, after `case .image: self = .images` add `case .screenshot: self = .screenshots`

`Sources/ImperumCore/ClipClassifier.swift`, after `title(imageWidth:height:)`:

```swift
    public static func title(screenshotWidth w: Int, height h: Int) -> String { "Screenshot \(w)×\(h)" }
```

`Sources/CopyStackKit/Protocol.swift`: in `init(clip:previewLimit:)` change `case .image:` to `case .image, .screenshot:`; in `asClip()` change `case .image:` to `case .image, .screenshot:`.

`Sources/CopyStackKit/RequestHandler.swift` `content(for:)`: change `case .image:` to `case .image, .screenshot:`.

`Sources/CopyStackKit/FrameRenderer.swift` `glyph(for:)`: after `case .image: return "▣"` add `case .screenshot: return "▣"`.

`Sources/ImperumTool/CopyStackView.swift` `leading`: change `case .image:` to `case .image, .screenshot:`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | grep -E "error:|Test Suite '(ImperumCoreTests|CopyStackKitTests)\.xctest' (passed|failed)" -A1`
Expected: both bundles pass; ImperumCore 183, CopyStackKit 265. (Run the whole suite: the new enum case must compile through `copystack` and `ImperumTool` too.)

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | grep -E 'error:|Build complete'`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/ImperumCore/Clip.swift Sources/ImperumCore/ClipQuery.swift Sources/ImperumCore/ClipClassifier.swift Sources/CopyStackKit/Protocol.swift Sources/CopyStackKit/RequestHandler.swift Sources/CopyStackKit/FrameRenderer.swift Sources/ImperumTool/CopyStackView.swift Tests/ImperumCoreTests/ClipQueryTests.swift Tests/ImperumCoreTests/ClipTests.swift Tests/ImperumCoreTests/ClipStoreTests.swift Tests/CopyStackKitTests/FrameRendererTests.swift Tests/CopyStackKitTests/ProtocolTests.swift
git commit -m "feat(clipboard): Screenshots category and screenshot clip kind" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01WjvQwPfzAtrMWx96uCLxNM"
```

---

### Task 2: Pasteboard signature for a copied native screenshot

**Files:**
- Modify: `Sources/ImperumCore/ClipCapture.swift:8-18` (`PasteboardReading`), `:150-156` (image branch)
- Modify: `Sources/ImperumTool/PasteboardReader.swift:12-13`
- Test: `Tests/ImperumCoreTests/ClipCaptureTests.swift`

**Interfaces:**
- Consumes: `ClipKind.screenshot`, `ClipClassifier.title(screenshotWidth:height:)` (Task 1).
- Produces: `PasteboardReading.itemTypes: [[String]]` (one array per pasteboard item); `ClipCapture.isScreenshotSignature(itemTypes:) -> Bool`; `ClipCapture.nativeScreenshotSource == (name: "Screenshot", bundle: "com.apple.screencapture")`; `ClipCapture.contentID(_ data: Data) -> UUID` (now `public`, reused by Task 5).

- [ ] **Step 1: Write the failing tests**

In `Tests/ImperumCoreTests/ClipCaptureTests.swift`, add to `FakePasteboard` after `var types: [String] = ["public.utf8-plain-text"]`:

```swift
    /// Per-item types. Defaults to one item carrying `types`.
    var items: [[String]]? = nil
    var itemTypes: [[String]] { items ?? [types] }
```

Append inside `final class ClipCaptureTests`:

```swift
    // MARK: Screenshots

    func testOnlyASinglePNGItemIsAScreenshot() {
        let png = PasteboardImage(data: Data([9, 9, 9]), width: 4, height: 3)
        let shot = ClipCapture.capture(from: FakePasteboard(types: ["public.png"], image: png, text: nil), context: ctx())!
        XCTAssertEqual(shot.clip.kind, .screenshot)
        XCTAssertEqual(shot.clip.title, "Screenshot 4×3")
        XCTAssertEqual(shot.clip.sourceAppName, "Screenshot")
        XCTAssertEqual(shot.clip.sourceBundleID, "com.apple.screencapture")
        XCTAssertEqual(shot.blobData, png.data)

        let browser = ClipCapture.capture(from: FakePasteboard(types: ["public.png", "public.tiff"], image: png, text: nil), context: ctx())!
        XCTAssertEqual(browser.clip.kind, .image, "extra types mean a browser/Preview copy")
        let twoItems = ClipCapture.capture(from: FakePasteboard(types: ["public.png"], items: [["public.png"], ["public.png"]], image: png, text: nil), context: ctx())!
        XCTAssertEqual(twoItems.clip.kind, .image, "two items are never a screenshot")
        let withText = ClipCapture.capture(from: FakePasteboard(types: ["public.png", "public.utf8-plain-text"], image: png, text: "hello"), context: ctx())!
        XCTAssertEqual(withText.clip.kind, .text, "text still wins")
        XCTAssertTrue(ClipCapture.isScreenshotSignature(itemTypes: [["public.png"]]))
        XCTAssertFalse(ClipCapture.isScreenshotSignature(itemTypes: [["public.png", "public.tiff"]]))
        XCTAssertFalse(ClipCapture.isScreenshotSignature(itemTypes: []))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClipCaptureTests 2>&1 | grep -E 'error:' | head -3`
Expected: `extra argument 'items' in call` / `type 'ClipCapture' has no member 'isScreenshotSignature'`.

- [ ] **Step 3: Implement**

`Sources/ImperumCore/ClipCapture.swift`, change `private static func contentID(_ data: Data) -> UUID` to `public static func contentID(_ data: Data) -> UUID` (the screenshot importer in Task 5 derives ids the same way so a saved and a byte-identical copied screenshot share one id).

Add to `protocol PasteboardReading` after `var types: [String] { get }`:

```swift
    /// The types of each pasteboard item, in order (`types` is the flattened
    /// union). A native screenshot copy is exactly one item, `["public.png"]`.
    var itemTypes: [[String]] { get }
```

In `enum ClipCapture`, before `capture(from:context:now:excludedHosts:frontPageHost:)`:

```swift
    /// What `screencapture -c` (⌃⇧⌘3/4) puts on the pasteboard: one item whose
    /// only type is PNG. Browsers, Preview and Finder always add TIFF, HTML,
    /// URL or file-URL types, so this shape is a usable screenshot signature.
    public static func isScreenshotSignature(itemTypes: [[String]]) -> Bool {
        itemTypes.count == 1 && itemTypes[0] == ["public.png"]
    }

    public static let nativeScreenshotSource = (name: "Screenshot", bundle: "com.apple.screencapture")
```

Replace the image branch in `capture`:

```swift
        if !textWinsOverImage, let img = pb.imagePNG() {
            let id = contentID(img.data)
            let payload = ClipPayload.blob(id: id, utType: "public.png", width: img.width, height: img.height)
            if isScreenshotSignature(itemTypes: pb.itemTypes) {
                let clip = Clip(id: id, kind: .screenshot, capturedAt: now,
                                sourceAppName: nativeScreenshotSource.name, sourceBundleID: nativeScreenshotSource.bundle,
                                title: ClipClassifier.title(screenshotWidth: img.width, height: img.height), payload: payload)
                return CapturedClip(clip: clip, blobData: img.data)
            }
            let clip = Clip(id: id, kind: .image, capturedAt: now, sourceAppName: src.name, sourceBundleID: src.bundle,
                            title: ClipClassifier.title(imageWidth: img.width, height: img.height), payload: payload)
            return CapturedClip(clip: clip, blobData: img.data)
        }
```

`Sources/ImperumTool/PasteboardReader.swift`, after `var types: [String] { ... }`:

```swift
    var itemTypes: [[String]] { (pb.pasteboardItems ?? []).map { $0.types.map(\.rawValue) } }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClipCaptureTests 2>&1 | grep -E 'error:|failed|Executed' | head -3`
Expected: all pass (existing count + 1).

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | grep -E 'error:|Build complete'`
Expected: `Build complete!` (the only other `PasteboardReading` conformer is `NSPasteboardReader`).

- [ ] **Step 5: Commit**

```bash
git add Sources/ImperumCore/ClipCapture.swift Sources/ImperumTool/PasteboardReader.swift Tests/ImperumCoreTests/ClipCaptureTests.swift
git commit -m "feat(clipboard): classify a bare-PNG pasteboard as a screenshot" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01WjvQwPfzAtrMWx96uCLxNM"
```

---

### Task 3: `ScreenshotDetector` (pure): roots, file verdicts, dedupe

**Files:**
- Create: `Sources/ImperumCore/ScreenshotDetector.swift`
- Test: `Tests/ImperumCoreTests/ScreenshotDetectorTests.swift` (new)

**Interfaces:**
- Consumes: nothing from earlier tasks (pure Foundation).
- Produces (all `public`):
  - `enum ScreenshotSource: String, Codable, Equatable` — `native`, `cleanShot`; `title: String` ("Screenshot" / "CleanShot X"); `bundleID: String` ("com.apple.screencapture" / "pl.maketheweb.cleanshotx").
  - `struct ScreenshotRoot: Equatable` — `url: URL`, `source: ScreenshotSource`, `dedicated: Bool`; `init(url:source:dedicated:)`.
  - `struct FileEvent: Equatable` — `url: URL`, `root: ScreenshotRoot`, `createdAt: Date`, `byteSize: Int`, `isTaggedScreenCapture: Bool`; memberwise `init`.
  - `enum FileVerdict: Equatable` — `ignore`, `settle`, `accept(ScreenshotSource)`.
  - `struct ScreenshotDetector`:
    - `static let imageExtensions: Set<String>` (`png jpg jpeg heic`), `static let dedupeWindow: TimeInterval` (5), `static let settleDelay: TimeInterval` (0.3)
    - `static func roots(nativeLocation: String?, cleanShotExportPath: String?, home: URL) -> [ScreenshotRoot]`
    - `static func matchesNativeName(_ fileName: String) -> Bool`
    - `init(startedAt: Date)`; `let startedAt: Date`
    - `mutating func verdict(for: FileEvent) -> FileVerdict`
    - `mutating func isDuplicate(width: Int, height: Int, at: Date) -> Bool` (records the size when it is not a duplicate)

- [ ] **Step 1: Write the failing tests**

Create `Tests/ImperumCoreTests/ScreenshotDetectorTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ScreenshotDetectorTests 2>&1 | grep -E 'error:' | head -3`
Expected: `cannot find 'ScreenshotDetector' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/ImperumCore/ScreenshotDetector.swift`:

```swift
import Foundation

/// Which tool produced a screenshot. Used for the clip's source fields so a
/// shot taken while Safari was in front is not attributed to Safari.
public enum ScreenshotSource: String, Codable, Equatable {
    case native, cleanShot

    public var title: String {
        switch self {
        case .native: return "Screenshot"
        case .cleanShot: return "CleanShot X"
        }
    }

    public var bundleID: String {
        switch self {
        case .native: return "com.apple.screencapture"
        case .cleanShot: return "pl.maketheweb.cleanshotx"
        }
    }
}

/// A folder the app watches for new screenshot files.
public struct ScreenshotRoot: Equatable {
    public var url: URL
    public var source: ScreenshotSource
    /// True when every image written here is a screenshot (CleanShot's
    /// folders, a custom native location). False for the shared ~/Desktop,
    /// where only tagged files or native-named files count.
    public var dedicated: Bool
    public init(url: URL, source: ScreenshotSource, dedicated: Bool) {
        self.url = url; self.source = source; self.dedicated = dedicated
    }
}

/// One file-system sighting, already read by the caller (no I/O here).
public struct FileEvent: Equatable {
    public var url: URL
    public var root: ScreenshotRoot
    public var createdAt: Date
    public var byteSize: Int
    /// The `com.apple.metadata:kMDItemIsScreenCapture` xattr is present and true.
    public var isTaggedScreenCapture: Bool
    public init(url: URL, root: ScreenshotRoot, createdAt: Date, byteSize: Int, isTaggedScreenCapture: Bool) {
        self.url = url; self.root = root; self.createdAt = createdAt; self.byteSize = byteSize
        self.isTaggedScreenCapture = isTaggedScreenCapture
    }
}

/// `.settle` = ask again after `settleDelay` with a fresh byte size.
public enum FileVerdict: Equatable { case ignore, settle, accept(ScreenshotSource) }

/// Decides which file events are new screenshots and collapses a screenshot
/// that arrives twice (CleanShot save + copy). Pure: the app feeds it facts.
public struct ScreenshotDetector {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]
    public static let dedupeWindow: TimeInterval = 5
    public static let settleDelay: TimeInterval = 0.3
    public static let cleanShotMediaPath = "Library/Application Support/CleanShot/media"

    public let startedAt: Date
    /// Last byte size seen per URL, for the settle check.
    private var lastSize: [URL: Int] = [:]
    /// URLs already turned into clips; later events for them are ignored.
    private var accepted: Set<URL> = []
    /// Recent screenshot pixel sizes, for dedupe.
    private var recent: [(width: Int, height: Int, at: Date)] = []

    public init(startedAt: Date) { self.startedAt = startedAt }

    // MARK: Roots

    /// The folders to watch, from raw defaults values. Trailing whitespace in
    /// `nativeLocation` is real (folder names may end in a space); `~` is
    /// expanded; empty/absent falls back to ~/Desktop. Duplicate folders
    /// collapse to one root, keeping `dedicated` if either side had it.
    public static func roots(nativeLocation: String?, cleanShotExportPath: String?, home: URL) -> [ScreenshotRoot] {
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let nativeURL: URL = {
            guard let raw = nativeLocation, !raw.isEmpty else { return desktop }
            return expand(raw, home: home)
        }()
        var out: [ScreenshotRoot] = [
            ScreenshotRoot(url: nativeURL, source: .native, dedicated: !same(nativeURL, desktop)),
            ScreenshotRoot(url: home.appendingPathComponent(cleanShotMediaPath, isDirectory: true), source: .cleanShot, dedicated: true),
        ]
        if let raw = cleanShotExportPath, !raw.isEmpty {
            out.append(ScreenshotRoot(url: expand(raw, home: home), source: .cleanShot, dedicated: true))
        }
        var collapsed: [ScreenshotRoot] = []
        for r in out {
            if let i = collapsed.firstIndex(where: { same($0.url, r.url) }) {
                collapsed[i].dedicated = collapsed[i].dedicated || r.dedicated
            } else {
                collapsed.append(r)
            }
        }
        return collapsed
    }

    private static func expand(_ raw: String, home: URL) -> URL {
        if raw == "~" { return home }
        if raw.hasPrefix("~/") { return home.appendingPathComponent(String(raw.dropFirst(2)), isDirectory: true) }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    // MARK: Native file names

    private static let datePattern = try! NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}"#)
    private static let timePattern = try! NSRegularExpression(pattern: #"\d{2}\.\d{2}\.\d{2}"#)

    /// "Screenshot 2026-09-27 at 11.06.37.png", "Bildschirmfoto 2026-09-27 um
    /// 11.06.37.png": every locale keeps the `YYYY-MM-DD` date and the
    /// `HH.MM.SS` time, only the words change.
    public static func matchesNativeName(_ fileName: String) -> Bool {
        let range = NSRange(fileName.startIndex..., in: fileName)
        return datePattern.firstMatch(in: fileName, range: range) != nil && timePattern.firstMatch(in: fileName, range: range) != nil
    }

    // MARK: Verdicts

    public mutating func verdict(for e: FileEvent) -> FileVerdict {
        guard Self.imageExtensions.contains(e.url.pathExtension.lowercased()) else { return .ignore }
        guard e.createdAt >= startedAt else { return .ignore }
        guard !accepted.contains(e.url) else { return .ignore }
        let previous = lastSize[e.url]
        lastSize[e.url] = e.byteSize
        guard let previous, previous == e.byteSize, e.byteSize > 0 else { return .settle }
        let qualifies = e.isTaggedScreenCapture || e.root.dedicated
            || (e.root.source == .native && Self.matchesNativeName(e.url.lastPathComponent))
        guard qualifies else { return .ignore }
        accepted.insert(e.url)
        lastSize.removeValue(forKey: e.url)
        return .accept(e.root.source)
    }

    // MARK: Dedupe

    /// True when a screenshot of this pixel size was seen within
    /// `dedupeWindow`. Otherwise records this one and returns false.
    public mutating func isDuplicate(width: Int, height: Int, at now: Date) -> Bool {
        recent.removeAll { now.timeIntervalSince($0.at) > Self.dedupeWindow }
        if recent.contains(where: { $0.width == width && $0.height == height }) { return true }
        recent.append((width, height, now))
        return false
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ScreenshotDetectorTests 2>&1 | grep -E 'error:|failed|Executed' | head -3`
Expected: `Executed 11 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ImperumCore/ScreenshotDetector.swift Tests/ImperumCoreTests/ScreenshotDetectorTests.swift
git commit -m "feat(clipboard): ScreenshotDetector with root resolution, settle rules and dedupe" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01WjvQwPfzAtrMWx96uCLxNM"
```

---

### Task 4: `ClipboardSettings.captureScreenshotFiles`

**Files:**
- Modify: `Sources/ImperumCore/ClipboardSettings.swift`
- Test: `Tests/ImperumCoreTests/ClipboardSettingsTests.swift`

**Interfaces:**
- Produces: `ClipboardSettings.captureScreenshotFiles: Bool` (default `true`; JSON key `captureScreenshotFiles`; absent → `true`).

- [ ] **Step 1: Write the failing test**

Append inside `final class ClipboardSettingsTests`:

```swift
    // MARK: Screenshots

    func testCaptureScreenshotFilesDefaultsOnAndRoundTrips() throws {
        XCTAssertTrue(ClipboardSettings().captureScreenshotFiles)
        let absent = try JSONDecoder().decode(ClipboardSettings.self, from: #"{"maxStack":99}"#.data(using: .utf8)!)
        XCTAssertTrue(absent.captureScreenshotFiles)
        var s = ClipboardSettings()
        s.captureScreenshotFiles = false
        let back = try JSONDecoder().decode(ClipboardSettings.self, from: JSONEncoder().encode(s))
        XCTAssertFalse(back.captureScreenshotFiles)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClipboardSettingsTests 2>&1 | grep -E 'error:' | head -2`
Expected: `value of type 'ClipboardSettings' has no member 'captureScreenshotFiles'`.

- [ ] **Step 3: Implement**

In `Sources/ImperumCore/ClipboardSettings.swift`, after `public var shortcuts: PanelShortcuts = .defaults` add:

```swift
    /// Watch the macOS and CleanShot X screenshot folders and import new
    /// screenshot files as clips. Copied screenshots are captured regardless.
    public var captureScreenshotFiles = true
```

Add `captureScreenshotFiles` to the end of `CodingKeys`, and in `init(from:)` after the `s.shortcuts = ...` line:

```swift
        s.captureScreenshotFiles = try c.decodeIfPresent(Bool.self, forKey: .captureScreenshotFiles) ?? s.captureScreenshotFiles
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClipboardSettingsTests 2>&1 | grep -E 'error:|failed|Executed' | head -2`
Expected: `Executed 12 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ImperumCore/ClipboardSettings.swift Tests/ImperumCoreTests/ClipboardSettingsTests.swift
git commit -m "feat(clipboard): captureScreenshotFiles setting" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01WjvQwPfzAtrMWx96uCLxNM"
```

---

### Task 5: `ScreenshotWatcher` (FSEvents), `ScreenshotImporter`, controller wiring

**Files:**
- Create: `Sources/ImperumTool/ScreenshotWatcher.swift`
- Create: `Sources/ImperumTool/ScreenshotImporter.swift`
- Modify: `Sources/ImperumTool/PasteboardReader.swift` (end of file: `ImageFile` helper)
- Modify: `Sources/ImperumTool/ClipboardController.swift:17-30` (properties), `:79-124` (init), `:136-170` (`apply`), `:180-206` (`poll`)

**Interfaces:**
- Consumes: `ScreenshotDetector`, `ScreenshotRoot`, `FileEvent`, `FileVerdict`, `ScreenshotSource` (Task 3); `ClipboardSettings.captureScreenshotFiles` (Task 4); `ClipKind.screenshot`, `ClipClassifier.title(screenshotWidth:height:)` (Task 1); `CapturedClip`, `PasteboardImage` (existing).
- Produces:
  - `final class ScreenshotWatcher` — `init(onEvent: @escaping (String, Bool) -> Void)` (path, isRemoval); `func start(paths: [String]) -> Bool`; `func stop()`; `var isRunning: Bool`.
  - `final class ScreenshotImporter` — `init()`; `var onCaptured: ((CapturedClip) -> Void)?`; `func update(enabled: Bool)`; `func refreshRoots()`; `func isDuplicate(width: Int, height: Int) -> Bool`; `private(set) var status: String`; `var onStatusChanged: (() -> Void)?`.
  - `enum ImageFile` — `static func pngImage(at: URL) -> PasteboardImage?`.
  - `ClipboardController.screenshotWatchStatus: String` (`@Published private(set)`); `private func insertCaptured(_ captured: CapturedClip)` (the blob-cache + archive + store path, shared by `poll` and the importer).

No unit test (AppKit + FSEvents, app target). Verified by build, the full suite, and the manual checks in Step 5.

- [ ] **Step 1: `ImageFile` helper**

Append to `Sources/ImperumTool/PasteboardReader.swift`:

```swift
enum ImageFile {
    /// Decodes an image file (PNG/JPEG/HEIC) to PNG bytes plus pixel size,
    /// the same shape the pasteboard reader produces, so a saved screenshot
    /// goes through the identical blob/thumbnail/paste path as a copied one.
    static func pngImage(at url: URL) -> PasteboardImage? {
        guard let img = NSImage(contentsOf: url), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              rep.pixelsWide > 0, rep.pixelsHigh > 0,
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return PasteboardImage(data: png, width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}
```

- [ ] **Step 2: `ScreenshotWatcher`**

Create `Sources/ImperumTool/ScreenshotWatcher.swift`:

```swift
// Sources/ImperumTool/ScreenshotWatcher.swift
import CoreServices
import Foundation

/// Thin FSEvents adapter: reports file-level events under the given roots on
/// the main queue. Knows nothing about screenshots; `ScreenshotImporter`
/// decides what to do with each path.
final class ScreenshotWatcher {
    private let onEvent: (String, Bool) -> Void
    private var stream: FSEventStreamRef?

    /// `onEvent(path, isRemoval)` — `isRemoval` is true for a delete/rename-away.
    init(onEvent: @escaping (String, Bool) -> Void) { self.onEvent = onEvent }

    var isRunning: Bool { stream != nil }

    /// Returns false when the stream could not be created or started.
    @discardableResult
    func start(paths: [String]) -> Bool {
        stop()
        guard !paths.isEmpty else { return false }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, ScreenshotWatcher.callback, &ctx, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { return false }
        FSEventStreamSetDispatchQueue(s, .main)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            return false
        }
        stream = s
        return true
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let me = Unmanaged<ScreenshotWatcher>.fromOpaque(info).takeUnretainedValue()
        guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
        let flags = UnsafeBufferPointer(start: eventFlags, count: count)
        for (i, path) in paths.enumerated() {
            let f = Int(flags[i])
            guard f & kFSEventStreamEventFlagItemIsFile != 0 else { continue }
            let removed = f & kFSEventStreamEventFlagItemRemoved != 0
            me.onEvent(path, removed)
        }
    }
}
```

- [ ] **Step 3: `ScreenshotImporter`**

Create `Sources/ImperumTool/ScreenshotImporter.swift`:

```swift
// Sources/ImperumTool/ScreenshotImporter.swift
import AppKit
import ImperumCore

/// Owns the folder watcher and the pure detector. Turns new screenshot files
/// into `CapturedClip`s for the controller, and answers the pasteboard path's
/// "is this a duplicate of a screenshot we just imported?" question so a
/// CleanShot save+copy yields one clip.
final class ScreenshotImporter {
    var onCaptured: ((CapturedClip) -> Void)?
    var onStatusChanged: (() -> Void)?
    /// Human-readable state for the settings caption.
    private(set) var status = "" { didSet { if status != oldValue { onStatusChanged?() } } }

    private var detector = ScreenshotDetector(startedAt: Date())
    private lazy var watcher = ScreenshotWatcher { [weak self] path, removed in self?.handle(path: path, removed: removed) }
    private var roots: [ScreenshotRoot] = []
    private var enabled = false
    private var streamFailed = false

    // MARK: Lifecycle

    func update(enabled: Bool) {
        self.enabled = enabled
        if enabled { refreshRoots() } else { watcher.stop(); roots = []; status = "" }
    }

    /// Re-reads both apps' defaults, drops roots that don't exist, and
    /// restarts the stream if the set changed. Called on every settings
    /// apply and on volume mount/unmount.
    func refreshRoots() {
        guard enabled else { return }
        let native = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let export = UserDefaults(suiteName: "pl.maketheweb.cleanshotx")?.string(forKey: "exportPath")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let all = ScreenshotDetector.roots(nativeLocation: native, cleanShotExportPath: export, home: home)
        var isDir: ObjCBool = false
        let present = all.filter { FileManager.default.fileExists(atPath: $0.url.path, isDirectory: &isDir) && isDir.boolValue }
        let nativeMissing = all.contains { $0.source == .native } && !present.contains { $0.source == .native }
        if present != roots || !watcher.isRunning {
            roots = present
            detector = ScreenshotDetector(startedAt: Date())
            streamFailed = !present.isEmpty && !watcher.start(paths: present.map(\.url.path))
        }
        status = Self.statusText(watched: present, nativeMissing: nativeMissing, streamFailed: streamFailed)
    }

    static func statusText(watched: [ScreenshotRoot], nativeMissing: Bool, streamFailed: Bool) -> String {
        if streamFailed { return "Screenshot watching is unavailable this session" }
        var parts: [String] = []
        if !watched.isEmpty {
            parts.append("Watching: " + watched.map { ($0.url.path as NSString).abbreviatingWithTildeInPath }.joined(separator: ", "))
        }
        if nativeMissing { parts.append("Screenshot folder not available (volume not mounted)") }
        return parts.joined(separator: ". ")
    }

    // MARK: Pasteboard-side dedupe

    func isDuplicate(width: Int, height: Int) -> Bool {
        detector.isDuplicate(width: width, height: height, at: Date())
    }

    // MARK: File events

    private func handle(path: String, removed: Bool) {
        guard enabled, !removed else { return }
        let url = URL(fileURLWithPath: path)
        guard let root = roots.first(where: { url.path.hasPrefix($0.url.path) }) else { return }
        guard let event = Self.fileEvent(url: url, root: root) else { return }
        switch detector.verdict(for: event) {
        case .ignore: return
        case .settle:
            DispatchQueue.main.asyncAfter(deadline: .now() + ScreenshotDetector.settleDelay) { [weak self] in
                self?.handle(path: path, removed: false)
            }
        case .accept(let source):
            importFile(url, source: source)
        }
    }

    private static func fileEvent(url: URL, root: ScreenshotRoot) -> FileEvent? {
        guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return FileEvent(url: url, root: root, createdAt: values.creationDate ?? .distantPast,
                         byteSize: values.fileSize ?? 0, isTaggedScreenCapture: isTaggedScreenCapture(url))
    }

    /// `com.apple.metadata:kMDItemIsScreenCapture`, a bplist boolean written by
    /// CleanShot (and by some macOS versions). Present-but-undecodable counts
    /// as tagged: only screenshot tools write this attribute at all.
    private static func isTaggedScreenCapture(_ url: URL) -> Bool {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        return url.withUnsafeFileSystemRepresentation { fsPath -> Bool in
            guard let fsPath else { return false }
            let size = getxattr(fsPath, name, nil, 0, 0, 0)
            guard size > 0 else { return false }
            var buf = [UInt8](repeating: 0, count: size)
            guard getxattr(fsPath, name, &buf, size, 0, 0) == size else { return false }
            let value = try? PropertyListSerialization.propertyList(from: Data(buf), options: [], format: nil)
            return (value as? Bool) ?? true
        }
    }

    private func importFile(_ url: URL, source: ScreenshotSource) {
        guard let img = ImageFile.pngImage(at: url) else {
            NSLog("Imperum Tool screenshots: could not decode \(url.lastPathComponent)")
            return
        }
        guard !detector.isDuplicate(width: img.width, height: img.height, at: Date()) else { return }
        let id = ClipCapture.contentID(img.data)
        let clip = Clip(id: id, kind: .screenshot, capturedAt: Date(), sourceAppName: source.title, sourceBundleID: source.bundleID,
                        title: ClipClassifier.title(screenshotWidth: img.width, height: img.height),
                        payload: .blob(id: id, utType: "public.png", width: img.width, height: img.height))
        onCaptured?(CapturedClip(clip: clip, blobData: img.data))
    }
}
```

- [ ] **Step 4: Wire the controller**

`Sources/ImperumTool/ClipboardController.swift`:

After `@Published private(set) var hotkeyError: String?` add:

```swift
    /// What the screenshot folder watcher is doing, for the settings caption.
    @Published private(set) var screenshotWatchStatus = ""
```

After `private let tap = CmdVTap()` add:

```swift
    private let screenshots = ScreenshotImporter()
```

In `init`, after `tap.onOpenPanel = { ... }` add:

```swift
        screenshots.onCaptured = { [weak self] captured in self?.insertCaptured(captured) }
        screenshots.onStatusChanged = { [weak self] in
            guard let self else { return }
            self.screenshotWatchStatus = self.screenshots.status
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.screenshots.refreshRoots()
            }
        }
```

In `apply(_:)`, after `if s.enabled { startPolling() } else { stopPolling(); panel.hide() }` add:

```swift
        screenshots.update(enabled: s.enabled && s.captureScreenshotFiles)
```

In `poll()`, replace everything from `if let data = captured.blobData, let id = captured.clip.blobID {` through `store.insert(captured.clip, limits: settings.settings.limits)` with:

```swift
        if captured.clip.kind == .screenshot, case .blob(_, _, let w, let h) = captured.clip.payload,
           screenshots.isDuplicate(width: w, height: h) { return }
        insertCaptured(captured)
    }

    /// Shared by the pasteboard poll and the screenshot importer: cache the
    /// blob (and thumbnail), persist it unless session-only, insert the clip.
    private func insertCaptured(_ captured: CapturedClip) {
        if let data = captured.blobData, let id = captured.clip.blobID {
            let thumb = ImageThumbnail.png(from: data, maxEdge: 64)
            // Always cache in memory first: session-only mode (or an
            // unavailable archive) must not leave the paster/thumbnail code
            // with nothing to read.
            blobCache.set(data, thumb: thumb, for: id)
            if !settings.settings.clearOnQuit, !archiveUnavailable {
                try? archive?.saveBlob(data, id: id)
                if let thumb { try? archive?.saveBlob(thumb, id: id, suffix: "thumb.png") }
            }
        }
        store.insert(captured.clip, limits: settings.settings.limits)
```

(The original closing `}` of `poll()` now closes `insertCaptured`. Re-read the two functions after editing: `poll()` must end right after `insertCaptured(captured)`.)

- [ ] **Step 5: Build, run the suite, manual check**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | grep -E 'error:|Build complete'`
Expected: `Build complete!`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | grep -E "Test Suite '(ImperumCoreTests|CopyStackKitTests)\.xctest' (passed|failed)" -A1`
Expected: both pass.

Manual (needs a human; if none is available, record that in the ledger and move on): `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run ImperumTool`, then
1. `screencapture -x ~/Desktop/Screenshots/"probe $(date '+%H.%M.%S').png"` in a terminal (CleanShot's export folder, which is watched and dedicated; this Mac's native location is on an unmounted volume, so the Desktop itself is not watched) → within a second the Copy Stack has one Screenshots clip titled "Screenshot W×H", source "CleanShot X". Delete the probe file afterwards.
2. Take a CleanShot X capture with "copy to clipboard" on → exactly one clip, source "CleanShot X".
3. `screencapture -c -x -R0,0,20,20` → one clip (pasteboard path), source "Screenshot".
4. Paste a screenshot clip into Notes → the image appears.

- [ ] **Step 6: Commit**

```bash
git add Sources/ImperumTool/ScreenshotWatcher.swift Sources/ImperumTool/ScreenshotImporter.swift Sources/ImperumTool/PasteboardReader.swift Sources/ImperumTool/ClipboardController.swift
git commit -m "feat(clipboard): watch macOS and CleanShot X screenshot folders and import new shots" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01WjvQwPfzAtrMWx96uCLxNM"
```

---

### Task 6: Settings toggle and watch-status caption

**Files:**
- Modify: `Sources/ImperumTool/ClipboardSettingsTab.swift:56-57` (after "Show clip count in the menu bar")

**Interfaces:**
- Consumes: `ClipboardSettings.captureScreenshotFiles` (Task 4); `ClipboardController.screenshotWatchStatus` (Task 5); the tab already observes `controller`.

- [ ] **Step 1: Add the toggle and caption**

In `Sources/ImperumTool/ClipboardSettingsTab.swift`, directly after `Toggle("Show clip count in the menu bar", isOn: $store.settings.showBadge)` insert:

```swift
                Toggle("Capture screenshots saved to disk (macOS and CleanShot X)", isOn: $store.settings.captureScreenshotFiles)
                if store.settings.captureScreenshotFiles {
                    Text(controller.screenshotWatchStatus.isEmpty ? "Copied screenshots are always captured." : controller.screenshotWatchStatus)
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Screenshot files are ignored. Copied screenshots are still captured, under Screenshots.")
                        .font(.caption).foregroundStyle(.secondary)
                }
```

- [ ] **Step 2: Build and snapshot**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | grep -E 'error:|Build complete'`
Expected: `Build complete!`

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run ImperumTool --snapshot-settings /private/tmp/claude-501/-Users-deepdark-WSMonitor/90e31544-00ed-4f46-9d5a-a9574eeb837f/scratchpad/clipboard-tab-shots.png clipboard
```
Open the PNG with the Read tool. Expected: under "Show clip count in the menu bar", the new toggle (on) and a caption starting "Watching: ~/Desktop, ~/Library/Application Support/CleanShot/media, ~/Desktop/Screenshots" (this Mac's native location is on an unmounted volume, so the caption also ends with "Screenshot folder not available (volume not mounted)"). The "Limit per category" group, when expanded in a real run, lists Screenshots between Images and Videos.

- [ ] **Step 3: Run the suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | grep -E "Test Suite '(ImperumCoreTests|CopyStackKitTests)\.xctest' (passed|failed)" -A1`
Expected: both pass; ImperumCore 181 + 2 (T1) + 1 (T2) + 11 (T3) + 1 (T4) = 196, CopyStackKit 265.

- [ ] **Step 4: Commit**

```bash
git add Sources/ImperumTool/ClipboardSettingsTab.swift
git commit -m "feat(clipboard): screenshot-file capture toggle and watch status in Settings" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01WjvQwPfzAtrMWx96uCLxNM"
```

---

### Task 7: Documentation

**Files:**
- Modify: `README.md:46-59` (Copy Stack intro), `:167` (test count)
- Modify: `docs/superpowers/specs/2026-09-26-clipboard-history-design.md:280-284` (config keys)

- [ ] **Step 1: README**

Replace `←→ for category (Text · Links · Emails · Images · Videos · Files), ↑↓ to` with `←→ for category (Text · Links · Emails · Images · Screenshots · Videos · Files), ↑↓ to`.

After the paragraph that ends `count.` (the per-category limits paragraph) insert:

```markdown
Screenshots get their own category. Whether you copy one (⌃⇧⌘3/4, or
CleanShot X with copy-after-capture) or save it to a file (⇧⌘3/4, or any
CleanShot X capture), it lands in the stack automatically, attributed to
"Screenshot" or "CleanShot X" rather than the app that was in front, ready
to paste as an image. The tool watches the macOS screenshot location (the
Desktop unless you changed it) and CleanShot's media and export folders; it
never moves or deletes the files, and it never imports shots taken before
it was running. Settings › Clipboard › "Capture screenshots saved to disk"
turns the folder watching off; copied screenshots are captured regardless.
```

Update the test count on the `swift test` line: `(445 tests)` → the real total from Task 6 Step 3 (expected 461).

- [ ] **Step 2: Old spec's config keys**

In `docs/superpowers/specs/2026-09-26-clipboard-history-design.md`, after the line `and \`clipboardShortcuts\` (the \`PanelShortcuts\` map, default = the keys above).` add:

```markdown
Added 2026-09-27 (see `2026-09-27-screenshots-category-design.md`):
`captureScreenshotFiles` (Bool, default true) — watch the macOS and CleanShot X
screenshot folders and import new shots into the Screenshots category.
```

- [ ] **Step 3: Final verification**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | grep -E "Test Suite '(ImperumCoreTests|CopyStackKitTests)\.xctest' (passed|failed)" -A1`
Expected: both pass; fix the README count if the totals differ.

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build.sh 2>&1 | tail -1`
Expected: `Built + signed: build/Imperum Tool.app`.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/superpowers/specs/2026-09-26-clipboard-history-design.md
git commit -m "docs(clipboard): document the Screenshots category" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01WjvQwPfzAtrMWx96uCLxNM"
```

---

## Manual checklist (from the spec, after Task 7)

Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run ImperumTool`:
1. Native ⇧⌘4 to the configured folder (mount the volume first, or point `defaults write com.apple.screencapture location ~/Desktop` temporarily) → one Screenshots clip "Screenshot W×H", source "Screenshot".
2. Native ⌃⇧⌘4 → one clip, none duplicated.
3. CleanShot capture with copy-after-capture off → one clip, source "CleanShot X".
4. CleanShot capture with copy-after-capture on → still one clip.
5. Paste a screenshot clip into Notes and into Slack as an image.
6. Unmount the native volume → caption says the folder is not available; mount it → caption lists it again.
7. Toggle "Capture screenshots saved to disk" off → saved files are ignored, ⌃⇧⌘4 copies still arrive under Screenshots.
8. Limit per category → Screenshots = 10; take 12 shots; the two oldest unpinned are gone.
9. `copystack` shows the Screenshots chip and pastes a screenshot clip.

# Screenshots Category — Design

**Date:** 2026-09-27
**Status:** Approved in conversation (pending spec review)
**Extends:** `2026-09-26-clipboard-history-design.md` (Copy Stack),
`2026-09-27-clipboard-limits-and-shortcuts-design.md` (per-category limits)

## Problem

Screenshots are the thing people most often want to paste right after
taking them, and the Copy Stack handles them badly:

- A screenshot **copied** to the clipboard (native ⌃⇧⌘3/4, or CleanShot X
  with "copy after capture") is captured, but as an anonymous "Image W×H"
  under Images, indistinguishable from an image copied out of Safari.
- A screenshot **saved to disk** (native ⇧⌘3/4 to the screenshot folder, or
  any CleanShot X capture, which always writes a file) never touches the
  clipboard and so never reaches the stack at all.

## Goal

Screenshots get their own category. Whether copied or saved to a file, and
whether taken with macOS or CleanShot X, a screenshot lands in the Copy
Stack automatically, ready to paste as image pixels. On this Mac that means
native shots (configured location, ~/Desktop fallback) and CleanShot X
captures (its media folder and its export folder).

## Non-goals

- Backfilling captures taken before the watcher started (CleanShot's media
  folder holds thousands).
- Screen recordings and other video captures.
- CleanShot cloud uploads, annotations history, or its overlay state.
- Reveal-in-Finder or any link back to the original file. The clip is a
  self-contained copy; the file on disk is never read again, moved or
  deleted.
- Pasting a saved screenshot as a *file*. Screenshots always paste as image
  pixels, the same as a copied screenshot today.

## Data model (`ImperumCore`)

- `ClipKind` gains `case screenshot`. Payload is `.blob(id:utType:width:height)`
  exactly like `.image`; the blob id is the SHA-256 of the PNG bytes as
  today, so byte-identical shots still dedupe through `ClipContentKey`.
- `ClipClassifier.title(screenshotWidth:height:)` returns `"Screenshot W×H"`.
- `ClipCategory` gains `case screenshots`, declared between `images` and
  `videos` so the chip order becomes All · Text · Links · Emails · Images ·
  Screenshots · Videos · Files. `kind` maps `.screenshots → .screenshot` and
  `init(kind:)` maps `.screenshot → .screenshots`. Per-category limits,
  chips, `ClipFilter` and the terminal picker's chip row all follow from the
  mapping; no special cases.
- `Clip.sourceAppName` for a screenshot is the *capturing tool* ("Screenshot"
  for native, "CleanShot X" for CleanShot), with `sourceBundleID`
  `com.apple.screencapture` / `pl.maketheweb.cleanshotx`. A shot taken while
  Safari was in front is not attributed to Safari.
- Archives written before this change decode unchanged; existing `.image`
  clips stay Images. The `copystack` wire protocol carries `ClipKind` by raw
  value; the CLI ships inside the app bundle at the same version, so no
  compatibility shim is needed.

## Detection (`ImperumCore/ScreenshotDetector.swift`, pure)

`ScreenshotDetector` is a value type fed two kinds of evidence and asked
"make a screenshot clip or not". It has no file-system or AppKit
dependency: the app passes it already-read facts.

### Watched roots

```swift
public enum ScreenshotSource: String, Codable { case native, cleanShot }

public struct ScreenshotRoot: Equatable {
    public var url: URL
    public var source: ScreenshotSource
    /// True when every image written here is a screenshot (CleanShot's
    /// folders). False for a shared folder like ~/Desktop, where only files
    /// matching the native name pattern count.
    public var dedicated: Bool
}

/// Resolves the roots from raw defaults values. Pure: takes the strings,
/// returns the candidates; the caller drops any that don't exist on disk.
public static func roots(nativeLocation: String?, cleanShotExportPath: String?,
                         home: URL) -> [ScreenshotRoot]
```

- Native: `nativeLocation` is the `com.apple.screencapture` `location`
  default. Trailing whitespace is preserved (this Mac's value ends in a
  space and that is the real folder name). `~` is expanded. Empty or absent
  → `~/Desktop`. `dedicated` is true exactly when the resolved folder is
  something other than `~/Desktop`: a custom native location is by
  definition a screenshot folder, while the Desktop is shared.
- CleanShot media: always `<home>/Library/Application Support/CleanShot/media`,
  dedicated. Captures land in a per-capture subfolder, so the watcher must
  report events recursively.
- CleanShot export: `cleanShotExportPath` from the `pl.maketheweb.cleanshotx`
  `exportPath` default, dedicated. Absent → not watched.
- Duplicate URLs (e.g. native location set to CleanShot's export folder)
  collapse to one root, keeping `dedicated = true`.

### File events

```swift
public struct FileEvent: Equatable {
    public var url: URL
    public var root: ScreenshotRoot
    public var createdAt: Date
    public var byteSize: Int
    public var isTaggedScreenCapture: Bool   // kMDItemIsScreenCapture xattr present and true
}

/// nil = ignore. `.settle` = ask again after 300 ms with a fresh byteSize.
public enum FileVerdict: Equatable { case ignore, settle, accept(ScreenshotSource) }

public mutating func verdict(for event: FileEvent, now: Date) -> FileVerdict
```

A file is accepted when all of these hold:

1. Extension is `png`, `jpg`, `jpeg` or `heic` (case-insensitive).
2. `createdAt >= watcherStartedAt` (set on `init`), so pre-existing files
   and Spotlight re-index churn are ignored.
3. It has settled: the detector remembers the last `byteSize` seen per URL;
   the first sighting and any sighting whose size differs from the previous
   one return `.settle`; a sighting equal to the previous size (and > 0)
   passes.
4. Either `isTaggedScreenCapture`, or `root.dedicated`, or (native root
   only) the file name matches the native pattern: contains a
   `YYYY-MM-DD` date and an `HH.MM.SS` time, which holds across macOS
   locales ("Screenshot 2026-09-27 at 11.06.37", "Bildschirmfoto 2026-09-27
   um 11.06.37").
5. It is not a duplicate (below).

Accepted URLs are remembered so a later event for the same file (Finder
tagging, Spotlight touching xattrs) is ignored, not re-imported.

### Pasteboard signature

`ClipCapture.capture` already produces `.image` clips. It gains one rule:
when the pasteboard has exactly one item whose types are exactly
`["public.png"]`, the clip is `kind: .screenshot` with source "Screenshot".
Verified on this Mac: `screencapture -c` writes exactly that shape; images
copied from browsers, Preview and Finder always carry additional types
(TIFF, HTML, URL, file URL). `PasteboardReading` gains
`var itemTypes: [[String]]` to expose the per-item shape (the existing
`types` is the flattened union).

CleanShot's copy-after-capture needs no signature: CleanShot always writes
the media file, so the watcher produces the clip and the clipboard copy is
handled by dedupe.

### Dedupe

```swift
public mutating func isDuplicate(width: Int, height: Int, at: Date) -> Bool
```

The detector keeps the last few `(width, height, seenAt)` triples. A
screenshot whose pixel size matches one seen within the last 5 seconds is
a duplicate and is dropped, whichever source came second. Both the file path
and the pasteboard path call this before inserting, so CleanShot's
save-plus-copy yields one clip, and a native ⌃⇧⌘4 (clipboard only) still
yields one.

## Watcher (`ImperumTool/ScreenshotWatcher.swift`, AppKit + CoreServices)

- Owns one FSEvents stream (`kFSEventStreamCreateFlagFileEvents |
  kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer`,
  latency 0.2 s) over the resolved roots that exist on disk. Events are
  delivered on the main queue.
- For each created/modified/renamed path it builds a `FileEvent` (creation
  date and size from `URL.resourceValues`, tag from the
  `com.apple.metadata:kMDItemIsScreenCapture` xattr via `getxattr`) and
  asks the detector. `.settle` schedules a re-check after 300 ms.
  `.accept` reads the file once, decodes it to PNG bytes with the existing
  image pipeline (`PasteboardImage`-shaped: data, width, height), asks
  `isDuplicate`, then hands `CapturedClip` to the controller's existing
  insert path (blob cache + archive + store).
- `refresh(roots:)` restarts the stream when the root set changes. The
  controller calls it on every settings apply and on
  `NSWorkspace.didMountNotification` / `didUnmountNotification`, so a
  native location on an external volume starts working when the volume
  appears.
- Defaults are read through `UserDefaults(suiteName:)` for
  `com.apple.screencapture` and `pl.maketheweb.cleanshotx`; a missing
  CleanShot domain simply yields no CleanShot export root.

## Settings

- `ClipboardSettings.captureScreenshotFiles: Bool`, default `true`, JSON key
  `captureScreenshotFiles`, absent → `true`.
- Settings › Clipboard › Capture & trigger gains, after "Show clip count in
  the menu bar":
  - `Toggle("Capture screenshots saved to disk (macOS and CleanShot X)")`
  - a caption listing the folders currently watched, e.g. "Watching:
    ~/Desktop, ~/Library/Application Support/CleanShot/media,
    ~/Desktop/Screenshots", or "Screenshot folder not available (volume not
    mounted)" when the native root is missing, or "Screenshot watching is
    unavailable this session" when FSEvents failed to start. The controller
    publishes `screenshotWatchStatus: String` for this.
- The "Limit per category" group gains the Screenshots row automatically
  through `ClipCategory.allCases`.
- Turning the toggle off stops the watcher. Copied screenshots keep arriving
  through the clipboard and are still categorised as Screenshots; the toggle
  is only about files.

## Error handling

- Root missing or unmounted: skipped without a log line; retried on mount
  and on every apply.
- File unreadable, undecodable, or zero bytes after settling: skipped with
  one `NSLog` line naming the file; never retried.
- FSEvents stream fails to create or start: watcher disabled for the
  session, status string says so, everything else unaffected.
- Blob archive unavailable (existing `archiveUnavailable` state): the clip
  still enters the session cache exactly as a copied image does today.
- The watcher never writes, moves or deletes anything under the roots.
- No new permissions: the roots are in the user's home. If the native
  location points somewhere the app cannot read, the root is treated as
  missing and the status caption says "not available".

## Testing

`ImperumCoreTests`:
- `ScreenshotDetectorTests`: roots from raw defaults (absent → ~/Desktop
  non-dedicated; custom path dedicated; trailing space preserved; `~`
  expansion; CleanShot export absent → no root; duplicate URLs collapse);
  every accept rule in isolation (extension, created-before-start ignored,
  settle sequence 0→N→N, tag, dedicated, native name pattern in two
  locales, non-dedicated Desktop file without pattern ignored); accepted
  file re-event ignored; dedupe by size within 5 s in both orders, and not
  after 5 s or with a different size.
- `ClipCaptureTests`: single-item `["public.png"]` pasteboard → `.screenshot`
  with source "Screenshot"; `["public.png","public.tiff"]` or two items →
  `.image`; string + PNG still follows the existing text-wins rule.
- `ClipQueryTests`: `ClipCategory(kind: .screenshot) == .screenshots`,
  `.screenshots.kind == .screenshot`, chip order, filter by category.
- `ClipStoreTests`: a Screenshots cap drops only screenshots.
- `ClipboardSettingsTests`: `captureScreenshotFiles` default, absent-key
  decode, round trip.

`CopyStackKitTests`: chip row renders the Screenshots chip in order; a
`screenshot` kind round-trips through the protocol and renders with the
image glyph.

Manual checklist (goes into the plan): native ⇧⌘4 to the configured folder
→ one Screenshots clip named "Screenshot W×H", source "Screenshot"; native
⌃⇧⌘4 → one clip, none duplicated; CleanShot capture with copy-after-capture
off → one clip, source "CleanShot X"; the same with copy on → still one
clip; paste it into Notes and Slack as an image; unmount the native volume
and confirm the caption; toggle off and confirm files are ignored while
copies still arrive; per-category cap on Screenshots drops the oldest
unpinned; `copystack` shows the chip and pastes the clip.

## Documentation

- README "Copy Stack" section: add Screenshots to the category list and a
  sentence on saved screenshots (macOS and CleanShot X) landing
  automatically, with the toggle's location.
- The 2026-09-26 spec's "Config keys" list gains `captureScreenshotFiles`
  by reference to this document.

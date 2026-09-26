// Sources/ImperumTool/ClipPaster.swift
import AppKit
import ImperumCore

/// Writes a clip to the general pasteboard in its native form and posts ⌘V.
/// The panel is non-activating, so the app the user was in still has focus.
final class ClipPaster {
    /// Cache-first, then archive lookup: `(id, suffix)` (e.g. "png",
    /// "thumb.png") -> the sealed blob's plaintext, if available anywhere.
    private let blobLookup: (UUID, String) -> Data?
    /// The change count our write produced; the watcher skips it.
    private(set) var lastOwnChangeCount: Int?

    init(blobLookup: @escaping (UUID, String) -> Data?) { self.blobLookup = blobLookup }

    /// Writes `clip` to the general pasteboard in its native form. Returns
    /// `false` (and shows a HUD) if an image clip's blob is missing, leaving
    /// the pasteboard untouched; otherwise always returns `true`.
    @discardableResult
    func write(_ clip: Clip) -> Bool {
        // Resolve everything that can fail before touching the pasteboard, so a
        // missing blob leaves the user's existing clipboard contents untouched.
        let write: (NSPasteboard) -> Void
        switch clip.payload {
        case .text(let s):
            // A legacy .color clip (round 10 removed the Colors category)
            // falls into this branch too and pastes its hex string as text.
            if let rtf = clip.richText {
                // Both representations: RTF-capable apps (Word, Pages, Mail,
                // TextEdit) take the formatting, plain-text apps take the string.
                write = { pb in
                    pb.setData(rtf, forType: .rtf)
                    pb.setString(s, forType: .string)
                }
            } else {
                write = { pb in pb.setString(s, forType: .string) }
            }
        case .fileURLs(let urls):
            write = { pb in pb.writeObjects(urls.map { $0 as NSURL }) }
        case .blob(let id, _, _, _):
            guard let png = blobLookup(id, "png"), let img = NSImage(data: png) else {
                HUD.shared.show("That image is no longer in the archive", symbol: "photo.badge.exclamationmark")
                return false
            }
            write = { pb in
                pb.setData(png, forType: .png)
                if let tiff = img.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            }
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        write(pb)
        lastOwnChangeCount = pb.changeCount
        return true
    }

    /// Posts ⌘V via the event tap, if Accessibility is granted.
    static func postPaste() {
        guard ActionRunner.ensureAccessibility() else { return }
        CmdVTap.postKey(9, flags: .maskCommand)
    }

    /// Writes `clip` to the pasteboard and, on success, posts ⌘V. Returns the
    /// write result (identical semantics to the old combined `paste`).
    @discardableResult
    func paste(_ clip: Clip) -> Bool {
        let wrote = write(clip)
        if wrote { Self.postPaste() }
        return wrote
    }
}

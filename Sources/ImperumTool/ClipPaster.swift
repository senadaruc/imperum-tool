// Sources/ImperumTool/ClipPaster.swift
import AppKit
import ImperumCore

/// Writes a clip to the general pasteboard in its native form and posts ⌘V.
/// The panel is non-activating, so the app the user was in still has focus.
final class ClipPaster {
    private let archive: () -> ClipArchive?
    /// The change count our write produced; the watcher skips it.
    private(set) var lastOwnChangeCount: Int?

    init(archive: @escaping () -> ClipArchive?) { self.archive = archive }

    @discardableResult
    func paste(_ clip: Clip) -> Bool {
        // Resolve everything that can fail before touching the pasteboard, so a
        // missing blob leaves the user's existing clipboard contents untouched.
        let write: (NSPasteboard) -> Void
        switch clip.payload {
        case .text(let s):
            if clip.kind == .color, let color = NSColor(hex: s) {
                write = { pb in
                    pb.writeObjects([color])
                    pb.setString(s, forType: .string)
                }
            } else {
                write = { pb in pb.setString(s, forType: .string) }
            }
        case .fileURLs(let urls):
            write = { pb in pb.writeObjects(urls.map { $0 as NSURL }) }
        case .blob(let id, _, _, _):
            guard let png = archive()?.loadBlob(id: id), let img = NSImage(data: png) else {
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
        guard ActionRunner.ensureAccessibility() else { return true }   // clip is on the pasteboard; user can ⌘V
        CmdVTap.postKey(9, flags: .maskCommand)
        return true
    }
}

extension NSColor {
    /// "#RRGGBB" → sRGB colour.
    convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard h.hasPrefix("#") else { return nil }
        h.removeFirst()
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

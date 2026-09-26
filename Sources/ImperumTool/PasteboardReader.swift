// Sources/ImperumTool/PasteboardReader.swift
import AppKit
import ImperumCore

/// `PasteboardReading` on the real general pasteboard. Reads are lazy so a
/// vetoed change never touches content.
final class NSPasteboardReader: PasteboardReading {
    private let pb: NSPasteboard
    init(pasteboard: NSPasteboard = .general) { pb = pasteboard }

    var changeCount: Int { pb.changeCount }
    var types: [String] { (pb.types ?? []).map(\.rawValue) }

    func fileURLs() -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Relies on `ClipCapture.capture` checking `fileURLs()` before this: a
    /// Finder copy of an image file also answers `canReadObject` for
    /// `NSImage` (AppKit resolves the file URL and decodes it), so without
    /// that ordering a Finder copy would be captured as an image blob here
    /// instead of the `.file` clip it should be.
    ///
    /// Not captured: file promises (e.g. dragging out of Photos.app), which
    /// need `NSFilePromiseReceiver` — out of scope for this fix.
    func imagePNG() -> PasteboardImage? {
        guard pb.canReadObject(forClasses: [NSImage.self], options: nil), let img = NSImage(pasteboard: pb),
              let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        guard rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        return PasteboardImage(data: png, width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    func colorHex() -> String? {
        guard pb.types?.contains(.color) == true, let c = NSColor(from: pb)?.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    func string() -> String? { pb.string(forType: .string) }

    /// Only `public.rtf`. If the pasteboard offers rich text solely as
    /// `com.apple.flat-rtfd` (RTFD, which can embed attachments), this
    /// returns nil — RTFD is out of scope for now; the plain string is
    /// still captured.
    func rtf() -> Data? { pb.data(forType: .rtf) }
}

enum ImageThumbnail {
    /// Downscale PNG bytes so the longest edge is `maxEdge` px.
    static func png(from data: Data, maxEdge: Int) -> Data? {
        guard let src = NSImage(data: data), let rep = NSBitmapImageRep(data: data) else { return nil }
        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        let scale = min(1, CGFloat(maxEdge) / max(w, h))
        let size = NSSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        src.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return out.representation(using: .png, properties: [:])
    }
}

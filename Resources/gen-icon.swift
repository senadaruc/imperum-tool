import AppKit

// Renders WSMonitor's app icon: an Apple-style squircle with an indigo→violet
// gradient and a white gauge glyph, then builds AppIcon.icns. Native CoreGraphics.

let S: CGFloat = 1024
let inset: CGFloat = 100                       // transparent grid margin
let rect = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let radius = rect.width * 0.2237               // continuous-corner approximation

func render() -> NSImage {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle path.
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()

    // Diagonal gradient background.
    let c0 = NSColor(srgbRed: 0.36, green: 0.55, blue: 0.94, alpha: 1) // blue
    let c1 = NSColor(srgbRed: 0.49, green: 0.23, blue: 0.93, alpha: 1) // violet
    let grad = NSGradient(starting: c0, ending: c1)!
    grad.draw(in: rect, angle: -55)

    // Subtle top highlight.
    let hi = NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
    hi.draw(in: rect, angle: -90)

    img.unlockFocus()

    // White gauge glyph, tinted in its OWN bitmap (so sourceAtop is scoped to it),
    // then composited onto the gradient.
    let cfg = NSImage.SymbolConfiguration(pointSize: 540, weight: .semibold)
    if let base = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
                          accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let gs = base.size
        let white = NSImage(size: gs)
        white.lockFocus()
        base.draw(at: .zero, from: NSRect(origin: .zero, size: gs), operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: gs).fill(using: .sourceAtop)
        white.unlockFocus()

        img.lockFocus()
        let gr = NSRect(x: (S - gs.width) / 2, y: (S - gs.height) / 2, width: gs.width, height: gs.height)
        white.draw(in: gr, from: NSRect(origin: .zero, size: gs), operation: .sourceOver, fraction: 0.95)
        img.unlockFocus()
    }
    _ = ctx
    return img
}

func png(_ image: NSImage, _ side: Int) -> Data {
    let target = NSImage(size: NSSize(width: side, height: side))
    target.lockFocus()
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    target.unlockFocus()
    let tiff = target.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    return rep.representation(using: .png, properties: [:])!
}

let icon = render()
let dir = "Resources/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let specs: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, side) in specs {
    try! png(icon, side).write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}
print("iconset written to \(dir)")

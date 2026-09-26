// Sources/ImperumTool/CopyStackModel.swift
import AppKit
import Combine
import ImperumCore

/// Panel view model: `PanelState` + the store's clips, thumbnails, favicons,
/// and the key commands. `onPaste` / `onClose` are wired by the controller.
final class CopyStackModel: ObservableObject {
    enum KeyCommand { case up, down, left, right, enter, escape, digit(Int), pin, delete }

    @Published private(set) var state = PanelState()
    @Published private(set) var sections: [ClipSection] = []
    @Published private(set) var flat: [Clip] = []
    @Published private(set) var indexByID: [UUID: Int] = [:]
    @Published private(set) var focusGeneration = 0

    var onPaste: ((Clip) -> Void)?
    var onClose: (() -> Void)?

    let store: ClipStore
    let settings: ClipboardSettingsStore
    /// Cache-first, then archive lookup: `(id, suffix)` -> the blob's
    /// plaintext, if available anywhere (works in session-only mode).
    private let blobLookup: (UUID, String) -> Data?
    /// Where the favicon disk cache lives, or nil to stay memory-only for
    /// the rest of this launch (the controller returns nil in session-only
    /// mode, so no host list is ever written to disk).
    private let faviconCacheDir: () -> URL?
    private var thumbs: [UUID: NSImage] = [:]
    /// Rendered RTF preview per clip id. A miss caches `nil` too (wrapped in
    /// `.some(nil)`), so a clip whose RTF fails to parse isn't re-parsed on
    /// every render.
    private var richPreviews: [UUID: NSImage?] = [:]
    private let favicons = FaviconLoader()
    private var bag = Set<AnyCancellable>()

    /// RTF above this size isn't rendered as a preview (the row is small;
    /// this is meant for a short formatted snippet, not a whole document).
    private static let maxRichPreviewBytes = 200_000
    private static let richPreviewSize = NSSize(width: 144, height: 48)
    private static let richPreviewPadding: CGFloat = 6

    init(store: ClipStore, settings: ClipboardSettingsStore, blobLookup: @escaping (UUID, String) -> Data?,
         faviconCacheDir: @escaping () -> URL?) {
        self.store = store; self.settings = settings; self.blobLookup = blobLookup; self.faviconCacheDir = faviconCacheDir
        store.$clips.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.recompute() }.store(in: &bag)
        favicons.onLoaded = { [weak self] in self?.objectWillChange.send() }
    }

    var query: String { state.query }
    var category: ClipCategory { state.category }
    var selectedID: UUID? { flat.indices.contains(state.selectedIndex) ? flat[state.selectedIndex].id : nil }
    var totalCount: Int { flat.count }

    func reset() { state.reset(); thumbs.removeAll(); richPreviews.removeAll(); focusGeneration += 1; recompute() }

    func setQuery(_ q: String) { state.setQuery(q); recompute() }

    func select(_ id: UUID) {
        if let i = flat.firstIndex(where: { $0.id == id }) { state.selectedIndex = i }
    }

    func setCategory(_ c: ClipCategory) {
        while state.category != c { state.cycleCategory(by: 1) }
        recompute()
    }

    /// Returns true when the key was consumed.
    func handle(key: KeyCommand) -> Bool {
        switch key {
        case .up: state.moveSelection(by: -1, count: flat.count)
        case .down: state.moveSelection(by: 1, count: flat.count)
        case .left: state.cycleCategory(by: -1); recompute()
        case .right: state.cycleCategory(by: 1); recompute()
        case .enter: if let id = selectedID, let c = store.clip(id: id) { onPaste?(c) }
        case .digit(let n): if flat.indices.contains(n - 1) { onPaste?(flat[n - 1]) }
        case .pin: if let id = selectedID { store.togglePin(id) }
        case .delete: if let id = selectedID { store.delete(id) }
        case .escape: onClose?()
        }
        return true
    }

    func thumbnail(for clip: Clip) -> NSImage? {
        guard let id = clip.blobID else { return nil }
        if let t = thumbs[id] { return t }
        guard let data = blobLookup(id, "thumb.png") ?? blobLookup(id, "png"),
              let img = NSImage(data: data) else { return nil }
        thumbs[id] = img
        return img
    }

    /// A small rendered preview of a clip's `richText` (its own fonts and
    /// colours, unstripped), for rows that carry formatting. Nil for any
    /// clip without `richText`, oversized RTF, or RTF that fails to parse.
    func richPreview(for clip: Clip) -> NSImage? {
        if let cached = richPreviews[clip.id] { return cached }
        guard let data = clip.richText, data.count <= Self.maxRichPreviewBytes,
              let attributed = NSAttributedString(rtf: data, documentAttributes: nil) else {
            richPreviews[clip.id] = .some(nil)
            return nil
        }
        let img = Self.renderRichPreview(attributed)
        richPreviews[clip.id] = .some(img)
        return img
    }

    private static func renderRichPreview(_ attributed: NSAttributedString) -> NSImage? {
        let size = richPreviewSize
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size   // logical size at 2x backing scale
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let drawRect = NSRect(x: richPreviewPadding, y: richPreviewPadding,
                              width: size.width - richPreviewPadding * 2, height: size.height - richPreviewPadding * 2)
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: drawRect).addClip()
        attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: NSStringDrawingContext())
        NSGraphicsContext.current?.restoreGraphicsState()
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }

    func favicon(for clip: Clip) -> NSImage? {
        guard settings.settings.showFavicons, clip.kind == .link, case .text(let s) = clip.payload,
              let host = URL(string: s)?.host else { return nil }
        return favicons.icon(forHost: host, cacheDir: faviconCacheDir())
    }

    private func recompute() {
        let v = state.visible(from: store.clips, now: Date(), calendar: .current)
        sections = v.sections; flat = v.flat
        var index: [UUID: Int] = [:]
        for (i, c) in flat.enumerated() { index[c.id] = i }
        indexByID = index
        state.clampSelection(count: flat.count)
    }
}

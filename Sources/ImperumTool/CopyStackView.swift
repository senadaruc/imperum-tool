// Sources/ImperumTool/CopyStackView.swift
import SwiftUI
import ImperumCore

/// Spacing and type for the two presentations (see `PanelLayout`). The
/// compact set is what makes the caret bubble read as a small system
/// popover rather than a shrunken window.
private struct LayoutMetrics {
    let size: CGSize
    let hPad: CGFloat
    let headerTop: CGFloat
    let headerBottom: CGFloat
    let headerFont: Font
    let rowLeading: CGFloat
    let rowTitleFont: Font
    let rowVPad: CGFloat
    let footerFont: Font

    static let full = LayoutMetrics(size: CopyStackPanel.fullSize, hPad: 16, headerTop: 14, headerBottom: 10, headerFont: .title3,
                                    rowLeading: 32, rowTitleFont: .body, rowVPad: 8, footerFont: .caption)
    static let compact = LayoutMetrics(size: CopyStackPanel.compactSize, hPad: 12, headerTop: 10, headerBottom: 8, headerFont: .body,
                                       rowLeading: 28, rowTitleFont: .callout, rowVPad: 6, footerFont: .caption2)
}

struct CopyStackView: View {
    @ObservedObject var model: CopyStackModel
    @FocusState private var searchFocused: Bool

    private var queryBinding: Binding<String> {
        Binding(get: { model.query }, set: { model.setQuery($0) })
    }

    private var m: LayoutMetrics { model.layout.isCompact ? .compact : .full }

    var body: some View {
        let arrow = CopyStackPanel.arrowHeight
        VStack(spacing: 0) {
            // Nothing draws under the arrow strip: the mask clips it to the
            // triangle, so content there would look torn off.
            if case .compact(.top, _) = model.layout { Color.clear.frame(height: arrow) }
            header
            Divider().opacity(0.4)
            list
            Divider().opacity(0.4)
            footer
            if case .compact(.bottom, _) = model.layout { Color.clear.frame(height: arrow) }
        }
        .frame(width: m.size.width, height: m.size.height + (model.layout.isCompact ? arrow : 0))
        .onAppear { searchFocused = true }
        .onChange(of: model.focusGeneration) { _, _ in searchFocused = true }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(m.headerFont)
                TextField("Type to search…", text: queryBinding)
                    .textFieldStyle(.plain).font(m.headerFont)
                    .focused($searchFocused)
                Text("\(model.totalCount) clips").font(.caption).foregroundStyle(.secondary)
            }
            // Horizontal scroll, no indicator: the eight chips fit at both
            // widths today, and a longer localisation or a new category can
            // never clip them.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ClipCategory.allCases, id: \.self) { c in
                        Text(c.title)
                            .font(.caption).fontWeight(.medium)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(model.category == c ? Color.primary.opacity(0.18) : Color.primary.opacity(0.07)))
                            .onTapGesture { model.setCategory(c) }
                    }
                }
            }
        }
        .padding(.horizontal, m.hPad).padding(.top, m.headerTop).padding(.bottom, m.headerBottom)
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    if model.flat.isEmpty {
                        Text(model.query.isEmpty ? "Nothing copied yet" : "No clips match “\(model.query)”")
                            .foregroundStyle(.secondary).padding(30).frame(maxWidth: .infinity)
                    }
                    ForEach(model.sections, id: \.title) { section in
                        Text(section.title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                            .padding(.horizontal, m.hPad).padding(.top, 10).padding(.bottom, 4)
                        ForEach(section.clips) { clip in
                            let index = model.indexByID[clip.id] ?? 0
                            ClipRow(clip: clip, index: index, selected: model.selectedID == clip.id,
                                    quickPickPrefix: PanelShortcuts.modifierGlyphs(model.shortcuts.quickPickModifiers),
                                    thumbnail: model.thumbnail(for: clip), favicon: model.favicon(for: clip),
                                    richPreview: model.richPreview(for: clip),
                                    leading: m.rowLeading, titleFont: m.rowTitleFont, vPad: m.rowVPad)
                                .id(clip.id)
                                .onTapGesture { model.onPaste?(clip) }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: model.selectedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    // MARK: Footer

    private var footer: some View {
        let s = model.shortcuts
        return HStack(spacing: 14) {
            hint(s.combo(for: .up).display + s.combo(for: .down).display, "Navigate")
            hint(s.combo(for: .previousCategory).display + s.combo(for: .nextCategory).display, "Category")
            hint(s.combo(for: .paste).display, "Paste")
            hint(s.combo(for: .pin).display, "Pin")
            hint(s.combo(for: .delete).display, "Delete")
            Spacer()
            hint(s.combo(for: .close).display, "Close")
        }
        .font(m.footerFont).foregroundStyle(.secondary)
        .padding(.horizontal, m.hPad).padding(.vertical, model.layout.isCompact ? 8 : 10)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(keys).font(.caption2.monospaced())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.1)))
            Text(label)
        }
    }
}

private struct ClipRow: View {
    let clip: Clip
    let index: Int
    let selected: Bool
    let quickPickPrefix: String
    let thumbnail: NSImage?
    let favicon: NSImage?
    let richPreview: NSImage?
    let leading: CGFloat
    let titleFont: Font
    let vPad: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            leadingView.frame(width: leading, height: leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.title.isEmpty ? " " : clip.title).lineLimit(1).font(titleFont)
                Text("\(clip.sourceAppName) · \(clip.capturedAt, format: .dateTime.hour().minute())")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let richPreview {
                Image(nsImage: richPreview).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 72, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
            }
            if clip.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
            if index < 9 { Text("\(quickPickPrefix)\(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12).padding(.vertical, vPad)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.primary.opacity(0.16) : .clear))
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var leadingView: some View {
        switch clip.kind {
        case .image, .screenshot:
            if let t = thumbnail {
                Image(nsImage: t).resizable().aspectRatio(contentMode: .fill).frame(width: leading, height: leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else { glyph("photo") }
        // Legacy: round 10 removed the Colors category. A .color clip from
        // an old archive shows the plain text glyph, like .text.
        case .color, .text: glyph("text.alignleft")
        case .link:
            if let f = favicon { Image(nsImage: f).resizable().frame(width: 20, height: 20) } else { glyph("link") }
        case .email: glyph("envelope")
        case .video: glyph("film")
        case .file: glyph("doc")
        }
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name).font(.title3).foregroundStyle(.secondary)
    }
}

import Foundation

public enum ClipKind: String, Codable, CaseIterable, Hashable {
    case text, link, email
    /// Legacy: no longer produced (round 10 removed the Colors category —
    /// a colour-shaped string is now just `.text`). Kept so archives written
    /// before round 10 still decode; `ClipCategory.text` also matches this
    /// kind so old colour clips stay reachable in the panel.
    case color
    case image, video, file
}

/// What a clip carries. Text-family kinds (text/link/email/color) store the
/// string inline; files store URLs; images store a reference to an encrypted
/// blob on disk so the index stays small.
public enum ClipPayload: Codable, Equatable, Hashable {
    case text(String)
    case fileURLs([URL])
    case blob(id: UUID, utType: String, width: Int, height: Int)
}

/// Dedupe identity: same kind + same content, regardless of id, time, source or pin.
public struct ClipContentKey: Hashable {
    public let kind: ClipKind
    public let payload: ClipPayload
}

public struct Clip: Codable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let kind: ClipKind
    public var capturedAt: Date
    public var sourceAppName: String
    public var sourceBundleID: String?
    public var isPinned: Bool
    public let title: String
    public let payload: ClipPayload
    /// Optional RTF companion for text-family clips, written back to the
    /// pasteboard alongside the plain string on paste so formatting survives
    /// a round trip into Word/Pages/Mail/TextEdit. Plain text stays the
    /// master representation: search, titles, dedupe (`contentKey`) and the
    /// panel all key off `payload`, never this. Decodes as nil for any
    /// archive written before this property existed.
    public var richText: Data?

    public init(id: UUID = UUID(), kind: ClipKind, capturedAt: Date = Date(),
                sourceAppName: String, sourceBundleID: String?, isPinned: Bool = false,
                title: String, payload: ClipPayload, richText: Data? = nil) {
        self.id = id; self.kind = kind; self.capturedAt = capturedAt
        self.sourceAppName = sourceAppName; self.sourceBundleID = sourceBundleID
        self.isPinned = isPinned; self.title = title; self.payload = payload
        self.richText = richText
    }

    public var contentKey: ClipContentKey { ClipContentKey(kind: kind, payload: payload) }

    /// The blob id for image clips, nil otherwise.
    public var blobID: UUID? {
        if case .blob(let id, _, _, _) = payload { return id } else { return nil }
    }
}

public struct ClipLimits: Equatable {
    public var maxStack: Int
    public var retentionDays: Int
    public init(maxStack: Int, retentionDays: Int) { self.maxStack = maxStack; self.retentionDays = retentionDays }
}

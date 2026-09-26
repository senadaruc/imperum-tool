import Combine
import Foundation

/// In-memory stack, newest first. Dedupes on content, enforces the stack and
/// retention limits, never drops a pinned clip. Persistence is the owner's job
/// (`onChange`); blob cleanup too (`onBlobsDropped`).
public final class ClipStore: ObservableObject {
    @Published public private(set) var clips: [Clip]
    public var onChange: (() -> Void)?
    public var onBlobsDropped: (([UUID]) -> Void)?

    public init(clips: [Clip] = []) { self.clips = clips }

    public func clip(id: UUID) -> Clip? { clips.first { $0.id == id } }

    /// Load from the archive; no callbacks fire.
    public func replaceAll(_ loaded: [Clip]) {
        clips = loaded.sorted { $0.capturedAt > $1.capturedAt }
    }

    @discardableResult
    public func insert(_ incoming: Clip, limits: ClipLimits, now: Date = Date()) -> Clip {
        var stored = incoming
        if let i = clips.firstIndex(where: { $0.contentKey == incoming.contentKey }) {
            let old = clips.remove(at: i)
            stored = Clip(id: old.id, kind: old.kind, capturedAt: incoming.capturedAt,
                          sourceAppName: incoming.sourceAppName, sourceBundleID: incoming.sourceBundleID,
                          isPinned: old.isPinned, title: old.title, payload: old.payload)
            if let dup = incoming.blobID, dup != old.blobID { onBlobsDropped?([dup]) }
        }
        clips.insert(stored, at: 0)
        enforce(limits: limits, now: now, notify: false)
        onChange?()
        return stored
    }

    public func togglePin(_ id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[i].isPinned.toggle()
        onChange?()
    }

    public func delete(_ id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let removed = clips.remove(at: i)
        if let b = removed.blobID { onBlobsDropped?([b]) }
        onChange?()
    }

    public func clearAll() {
        let blobs = clips.compactMap(\.blobID)
        clips.removeAll()
        if !blobs.isEmpty { onBlobsDropped?(blobs) }
        onChange?()
    }

    /// Drop unpinned clips beyond `maxStack` (oldest first) and unpinned clips
    /// older than `retentionDays`. A clip stamped in the future is never "old".
    public func enforce(limits: ClipLimits, now: Date = Date(), notify: Bool = true) {
        let cutoff = now.addingTimeInterval(-TimeInterval(limits.retentionDays) * 86_400)
        var unpinnedSeen = 0
        var dropped: [UUID] = []
        clips = clips.filter { c in
            if c.isPinned { return true }
            unpinnedSeen += 1
            let keep = unpinnedSeen <= limits.maxStack && c.capturedAt >= cutoff
            if !keep, let b = c.blobID { dropped.append(b) }
            return keep
        }
        if !dropped.isEmpty { onBlobsDropped?(dropped) }
        if notify { onChange?() }
    }
}

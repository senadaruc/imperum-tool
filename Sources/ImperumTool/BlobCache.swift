// Sources/ImperumTool/BlobCache.swift
import Foundation

/// In-memory cache of image clip data for the current session, keyed by
/// clip id. Ensures pastes and thumbnails work even when the archive never
/// writes the blob to disk (session-only mode, or an unavailable archive).
///
/// Main-thread only: the controller is the sole owner and every call happens
/// on the main thread, so no internal locking is needed.
final class BlobCache {
    private var store: [UUID: (png: Data, thumb: Data?)] = [:]

    /// The full-size PNG for `id`, if cached.
    subscript(id: UUID) -> Data? { store[id]?.png }

    /// The thumbnail PNG for `id`, if one was captured.
    func thumb(for id: UUID) -> Data? { store[id]?.thumb }

    func set(_ data: Data, thumb: Data?, for id: UUID) { store[id] = (data, thumb) }

    func remove(_ ids: [UUID]) { for id in ids { store.removeValue(forKey: id) } }

    func removeAll() { store.removeAll() }
}

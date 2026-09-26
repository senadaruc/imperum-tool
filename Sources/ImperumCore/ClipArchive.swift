import CryptoKit
import Foundation

public protocol ArchiveKeyProvider {
    func key() throws -> SymmetricKey
}

public struct StaticKeyProvider: ArchiveKeyProvider {
    let k: SymmetricKey
    public init(key: SymmetricKey) { k = key }
    public func key() throws -> SymmetricKey { k }
}

public enum ClipArchiveError: Error, Equatable { case corrupt }

/// On-disk layout: `<dir>/index.bin` (AES-GCM sealed JSON `[Clip]`) and
/// `<dir>/blobs/<uuid>.<suffix>` (each AES-GCM sealed). Writes are atomic
/// (temp + rename) with mode 0600. The key comes from the provider each call
/// so the Keychain-backed provider can rotate it.
///
/// Thread-safety: an instance has no shared mutable state (the Keychain
/// provider caches its own key internally), so it is safe to call from any
/// single queue at a time. It is not safe to call concurrently from two
/// queues at once; the controller serialises saves onto one background
/// queue.
public final class ClipArchive {
    public let directory: URL
    private let keys: ArchiveKeyProvider
    private let fm = FileManager.default

    public init(directory: URL, keyProvider: ArchiveKeyProvider) {
        self.directory = directory; self.keys = keyProvider
    }

    private var indexURL: URL { directory.appendingPathComponent("index.bin") }
    private var blobsDir: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
    private func blobURL(_ id: UUID, _ suffix: String) -> URL { blobsDir.appendingPathComponent("\(id.uuidString).\(suffix)") }

    // MARK: Index

    public func saveIndex(_ clips: [Clip]) throws {
        let json = try JSONEncoder().encode(clips)
        try writeSealed(json, to: indexURL)
    }

    public func loadIndex() throws -> [Clip] {
        guard fm.fileExists(atPath: indexURL.path) else { return [] }
        let plain = try readSealed(indexURL)
        do { return try JSONDecoder().decode([Clip].self, from: plain) } catch { throw ClipArchiveError.corrupt }
    }

    // MARK: Blobs

    public func saveBlob(_ data: Data, id: UUID, suffix: String = "png") throws {
        try writeSealed(data, to: blobURL(id, suffix))
    }

    public func loadBlob(id: UUID, suffix: String = "png") -> Data? {
        try? readSealed(blobURL(id, suffix))
    }

    public func deleteBlobs(_ ids: [UUID]) {
        for id in ids { for s in ["png", "thumb.png"] { try? fm.removeItem(at: blobURL(id, s)) } }
    }

    /// Remove every blob whose uuid is not in `keeping`.
    public func sweepBlobs(keeping ids: Set<UUID>) {
        guard let names = try? fm.contentsOfDirectory(atPath: blobsDir.path) else { return }
        for name in names {
            let stem = String(name.prefix(36))
            if let id = UUID(uuidString: stem), !ids.contains(id) { try? fm.removeItem(at: blobsDir.appendingPathComponent(name)) }
        }
    }

    public func deleteAll() throws {
        try? fm.removeItem(at: indexURL)
        if fm.fileExists(atPath: blobsDir.path) { try fm.removeItem(at: blobsDir) }
        try fm.createDirectory(at: blobsDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
    }

    // MARK: Sealing

    private func writeSealed(_ plain: Data, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let sealed = try AES.GCM.seal(plain, using: try keys.key()).combined!
        let tmp = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try sealed.write(to: tmp, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func readSealed(_ url: URL) throws -> Data {
        let raw = try Data(contentsOf: url)
        let key = try keys.key()
        do {
            let box = try AES.GCM.SealedBox(combined: raw)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw ClipArchiveError.corrupt
        }
    }
}

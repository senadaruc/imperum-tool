// Sources/ImperumTool/CopyStackServer.swift
import Foundation
import ImperumCore
import CopyStackKit

/// Adapts `ClipStore` (ImperumCore) to `RequestHandler`'s `ClipBackend`.
final class StoreBackend: ClipBackend {
    private let store: ClipStore
    init(store: ClipStore) { self.store = store }
    var clips: [Clip] { store.clips }
    func clip(id: UUID) -> Clip? { store.clip(id: id) }
    func togglePin(_ id: UUID) { store.togglePin(id) }
    func delete(_ id: UUID) { store.delete(id) }
}

/// Owns the Unix socket for the `copystack` CLI. All handler work runs on the main thread.
final class CopyStackServer {
    private let store: ClipStore
    private let settings: ClipboardSettingsStore
    private let paster: ClipPaster
    private let commitPasted: (Clip) -> Void

    // `lazy` so the closures below can capture `self` weakly only once it's
    // fully initialized.
    private lazy var handler = RequestHandler(
        backend: StoreBackend(store: store),
        isEnabled: { [weak self] in
            guard let self else { return false }
            return self.settings.settings.enabled && self.settings.settings.allowCLI
        },
        onPaste: { [weak self] clip, session in self?.handlePaste(clip, session: session) ?? .failure(.disabled) },
        onCopy: { [weak self] clip in self?.handleCopy(clip) ?? false })
    private var socketServer: SocketServer?
    /// Set on main just before `handler.handle` is invoked, from the same
    /// `DispatchQueue.main.sync` call that reads it back inside `onPaste`, so
    /// concurrent connections never see each other's value.
    private var currentConnection: SocketServer.ConnectionID = -1
    /// A standalone `--paste` (no session) whose ⌘V and top-of-stack move
    /// are deferred to the CLI's disconnect, so the pasteboard write lands
    /// before the CLI process exits and steals focus back.
    private var pendingStandalonePaste: [SocketServer.ConnectionID: Clip] = [:]

    /// Task 10 sets this; when nil, a session paste behaves like a standalone paste.
    var onSessionPaste: ((SessionID, Clip) -> Void)?
    /// Task 10 uses it for EOF.
    var onConnectionClosed: ((ConnectionID, SessionID?) -> Void)?

    init(store: ClipStore, settings: ClipboardSettingsStore, paster: ClipPaster, commitPasted: @escaping (Clip) -> Void) {
        self.store = store
        self.settings = settings
        self.paster = paster
        self.commitPasted = commitPasted
    }

    var isRunning: Bool { socketServer?.isRunning ?? false }

    /// Resolves the socket path, creates its parent directory (mode 0700) if
    /// needed, and starts `SocketServer`. Logs and stays stopped on error.
    func start() {
        guard !isRunning else { return }
        let path = SocketPath.resolve(home: NSHomeDirectory(), tmp: NSTemporaryDirectory())
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                      attributes: [.posixPermissions: 0o700])
        } catch {
            NSLog("Imperum Tool copystack: failed to create socket directory \(dir): \(error)")
            return
        }
        let server = SocketServer(
            path: path,
            onConnect: { _ in },
            onLine: { [weak self] connection, data in self?.handleLine(connection: connection, data: data) },
            onClose: { [weak self] connection in self?.handleClose(connection: connection) })
        do {
            try server.start()
            socketServer = server
        } catch {
            NSLog("Imperum Tool copystack: failed to start socket server: \(error)")
        }
    }

    func stop() {
        socketServer?.stop()
        socketServer = nil
    }

    // MARK: - Socket callbacks (arrive on the server's own threads)

    private func handleLine(connection: SocketServer.Connection, data: Data) -> Data? {
        DispatchQueue.main.sync {
            switch ProtocolCodec.decodeRequest(data) {
            case .failure(let code):
                return try? ProtocolCodec.encode(.error(code: code, message: "malformed request"))
            case .success(let request):
                currentConnection = connection.id
                let response = handler.handle(request, connection: connection.id)
                return try? ProtocolCodec.encode(response)
            }
        }
    }

    private func handleClose(connection: SocketServer.Connection) {
        DispatchQueue.main.sync {
            let session = handler.session(for: connection.id)
            handler.connectionClosed(connection.id)
            onConnectionClosed?(connection.id, session)
            guard let clip = pendingStandalonePaste.removeValue(forKey: connection.id) else { return }
            // Give the CLI process time to exit and yield focus back to the
            // app the user was in before we post ⌘V.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                ClipPaster.postPaste()
                self?.commitPasted(clip)
            }
        }
    }

    // MARK: - Request handling (already on main, via handleLine's sync hop)

    private func handlePaste(_ clip: Clip, session: SessionID?) -> Result<Void, PasteError> {
        guard paster.write(clip) else { return .failure(.imageMissing) }
        if let session, let onSessionPaste {
            onSessionPaste(session, clip)
        } else {
            pendingStandalonePaste[currentConnection] = clip
        }
        return .success(())
    }

    private func handleCopy(_ clip: Clip) -> Bool {
        guard paster.write(clip) else { return false }
        commitPasted(clip)
        return true
    }
}

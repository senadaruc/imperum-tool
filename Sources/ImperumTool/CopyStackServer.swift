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
    /// Everything that belongs to one running instance of the socket server:
    /// its `RequestHandler` (session-by-connection state) and the standalone
    /// pastes it has queued, keyed by connection id.
    ///
    /// `SocketServer` connection ids restart at 0 on every `start()`, and a
    /// stopped server's `onClose` may still fire after `stop()` has already
    /// returned (see `SocketServer.stop()`'s doc comment). Without this,
    /// such a late callback from an old, already-replaced server instance
    /// could clear a brand-new connection's session or post an unrelated
    /// pending paste. Each `start()` creates a fresh `Generation`, and the
    /// socket callbacks for that server capture it directly (not
    /// `self.currentGeneration`), so a callback from a stopped server always
    /// keeps operating on its own, by-then-orphaned `Generation` and can
    /// never touch a newer one's state.
    private final class Generation {
        var handler: RequestHandler!
        var currentConnection: ConnectionID = -1
        var pendingStandalonePaste: [ConnectionID: Clip] = [:]
    }

    private let store: ClipStore
    private let settings: ClipboardSettingsStore
    private let paster: ClipPaster
    private let commitPasted: (Clip) -> Void

    private var socketServer: SocketServer?

    /// Task 10 sets this; when nil, a session paste behaves like a standalone paste.
    var onSessionPaste: ((SessionID, Clip) -> Void)?
    /// Task 10 uses it for EOF.
    var onConnectionClosed: ((ConnectionID, SessionID?) -> Void)?
    /// Task 10 uses it to know a picker's `hello{session}` arrived, i.e. the
    /// picker connected over the socket. Called on main.
    var onSessionConnected: ((SessionID) -> Void)?

    init(store: ClipStore, settings: ClipboardSettingsStore, paster: ClipPaster, commitPasted: @escaping (Clip) -> Void) {
        self.store = store
        self.settings = settings
        self.paster = paster
        self.commitPasted = commitPasted
    }

    var isRunning: Bool { socketServer?.isRunning ?? false }

    private var isEnabledNow: Bool { settings.settings.enabled && settings.settings.allowCLI }

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

        let generation = Generation()
        generation.handler = RequestHandler(
            backend: StoreBackend(store: store),
            isEnabled: { [weak self] in self?.isEnabledNow ?? false },
            onPaste: { [weak self, weak generation] clip, session in
                guard let self, let generation else { return .failure(.disabled) }
                return self.handlePaste(clip, session: session, generation: generation)
            },
            onCopy: { [weak self] clip in self?.handleCopy(clip) ?? false })

        // `generation` is captured strongly here (not weakly, unlike the
        // RequestHandler closures above): these closures are held by
        // `SocketServer`, which outlives `stop()` until its own threads
        // finish, and this `Generation` must stay alive for that whole
        // lifetime so a late callback still has valid (if by-then-orphaned)
        // state to operate on instead of silently becoming a no-op.
        let server = SocketServer(
            path: path,
            onConnect: { _ in },
            onLine: { [weak self] connection, data in
                self?.handleLine(connection: connection, data: data, generation: generation)
            },
            onClose: { [weak self] connection in
                self?.handleClose(connection: connection, generation: generation)
            })
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

    private func handleLine(connection: SocketServer.Connection, data: Data, generation: Generation) -> Data? {
        DispatchQueue.main.sync {
            switch ProtocolCodec.decodeRequest(data) {
            case .failure(let code):
                return try? ProtocolCodec.encode(.error(code: code, message: "malformed request"))
            case .success(let request):
                generation.currentConnection = connection.id
                if case .hello(let session) = request, let session {
                    onSessionConnected?(session)
                }
                let response = generation.handler.handle(request, connection: connection.id)
                return try? ProtocolCodec.encode(response)
            }
        }
    }

    private func handleClose(connection: SocketServer.Connection, generation: Generation) {
        DispatchQueue.main.sync {
            let session = generation.handler.session(for: connection.id)
            generation.handler.connectionClosed(connection.id)
            onConnectionClosed?(connection.id, session)
            guard let clip = generation.pendingStandalonePaste.removeValue(forKey: connection.id) else { return }
            // Give the CLI process time to exit and yield focus back to the
            // app the user was in before we post ⌘V.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.isEnabledNow else { return }
                ClipPaster.postPaste()
                // Re-read the clip: a pin toggle (or delete) in the 150ms gap
                // must be reflected, and a deleted clip must not be
                // resurrected by committing a stale copy of it.
                guard let current = self.store.clip(id: clip.id) else { return }
                self.commitPasted(current)
            }
        }
    }

    // MARK: - Request handling (already on main, via handleLine's sync hop)

    private func handlePaste(_ clip: Clip, session: SessionID?, generation: Generation) -> Result<Void, PasteError> {
        guard paster.write(clip) else { return .failure(.imageMissing) }
        if let session, let onSessionPaste {
            onSessionPaste(session, clip)
        } else {
            generation.pendingStandalonePaste[generation.currentConnection] = clip
        }
        return .success(())
    }

    private func handleCopy(_ clip: Clip) -> Bool {
        guard paster.write(clip) else { return false }
        commitPasted(clip)
        return true
    }
}

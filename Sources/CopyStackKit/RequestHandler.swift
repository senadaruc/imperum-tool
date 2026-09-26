import Foundation
import ImperumCore

/// What the app exposes to the socket layer. ClipStore (ImperumCore)
/// conforms to this via `StoreBackend`, a small adapter in `ImperumTool`.
public protocol ClipBackend: AnyObject {
    /// Newest first, as ClipStore.clips.
    var clips: [Clip] { get }
    func clip(id: UUID) -> Clip?
    func togglePin(_ id: UUID)
    func delete(_ id: UUID)
}

public typealias SessionID = String
public typealias ConnectionID = Int

public enum PasteError: Error, Equatable {
    case imageMissing
    case disabled
}

/// Pure request -> response mapping. Owns no threads; the caller
/// (`ImperumTool`'s `CopyStackServer`) invokes handle() on the main thread.
public final class RequestHandler {
    private let backend: ClipBackend
    private let isEnabled: () -> Bool
    private let onPaste: (Clip, SessionID?) -> Result<Void, PasteError>
    private let onCopy: (Clip) -> Bool
    private let previewLimit: Int

    private var sessionsByConnection: [ConnectionID: SessionID] = [:]
    private var pickerPIDsByConnection: [ConnectionID: Int32] = [:]

    public init(backend: ClipBackend,
                isEnabled: @escaping () -> Bool,
                onPaste: @escaping (Clip, SessionID?) -> Result<Void, PasteError>,
                onCopy: @escaping (Clip) -> Bool,
                previewLimit: Int = ClipSummary.defaultPreviewLimit) {
        self.backend = backend
        self.isEnabled = isEnabled
        self.onPaste = onPaste
        self.onCopy = onCopy
        self.previewLimit = previewLimit
    }

    /// Session bound by `hello` on this connection, if any (used by Task
    /// 5/10 to match a picker to a PickSession).
    public func session(for connection: ConnectionID) -> SessionID? {
        sessionsByConnection[connection]
    }

    /// The pid a session-bound picker reported in its `hello` on this
    /// connection, if any. Only recorded alongside a session: a standalone
    /// `copystack` is never a candidate for being signalled by the app.
    public func pickerPID(for connection: ConnectionID) -> Int32? {
        pickerPIDsByConnection[connection]
    }

    /// The connection whose `hello` bound `session`, if it's still open.
    public func connection(for session: SessionID) -> ConnectionID? {
        sessionsByConnection.first { $0.value == session }?.key
    }

    public func connectionClosed(_ connection: ConnectionID) {
        sessionsByConnection.removeValue(forKey: connection)
        pickerPIDsByConnection.removeValue(forKey: connection)
    }

    public func handle(_ request: Request, connection: ConnectionID) -> Response {
        if case .hello(let session, let pid) = request {
            if let session {
                sessionsByConnection[connection] = session
                if let pid { pickerPIDsByConnection[connection] = pid }
            }
            return .ok
        }

        guard isEnabled() else {
            return .error(code: .disabled, message: "copystack is disabled")
        }

        switch request {
        case .hello:
            // Handled above; unreachable.
            return .ok
        case .list:
            return .clips(currentSummaries())
        case .get(let id):
            guard let clip = backend.clip(id: id) else {
                return .error(code: .notFound, message: "no clip with that id")
            }
            return .content(content(for: clip))
        case .paste(let id):
            guard let clip = backend.clip(id: id) else {
                return .error(code: .notFound, message: "no clip with that id")
            }
            switch onPaste(clip, session(for: connection)) {
            case .success:
                return .ok
            case .failure(.imageMissing):
                return .error(code: .imageMissing, message: "image data is missing")
            case .failure(.disabled):
                return .error(code: .disabled, message: "copystack is disabled")
            }
        case .copy(let id):
            guard let clip = backend.clip(id: id) else {
                return .error(code: .notFound, message: "no clip with that id")
            }
            return onCopy(clip) ? .ok : .error(code: .imageMissing, message: "image data is missing")
        case .pin(let id):
            guard backend.clip(id: id) != nil else {
                return .error(code: .notFound, message: "no clip with that id")
            }
            backend.togglePin(id)
            return .clips(currentSummaries())
        case .delete(let id):
            guard backend.clip(id: id) != nil else {
                return .error(code: .notFound, message: "no clip with that id")
            }
            backend.delete(id)
            return .clips(currentSummaries())
        }
    }

    private func currentSummaries() -> [ClipSummary] {
        backend.clips.map { ClipSummary(clip: $0, previewLimit: previewLimit) }
    }

    private func content(for clip: Clip) -> ClipContent {
        switch clip.kind {
        case .text, .link, .email, .color:
            if case .text(let text) = clip.payload {
                return .text(text)
            }
            return .text("")
        case .file, .video:
            if case .fileURLs(let urls) = clip.payload {
                return .files(urls.map(\.path))
            }
            return .files([])
        case .image:
            if case .blob(_, _, let width, let height) = clip.payload {
                return .image(width: width, height: height)
            }
            return .image(width: 0, height: 0)
        }
    }
}

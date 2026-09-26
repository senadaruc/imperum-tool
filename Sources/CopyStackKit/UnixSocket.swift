import Foundation
import Darwin

/// Errors raised by `SocketServer` and `SocketClient`.
public enum SocketError: Error, Equatable {
    /// `start()` was called on an instance that is already running.
    case alreadyStarted
    case socketCreate(errno: Int32)
    case bind(errno: Int32)
    case chmod(errno: Int32)
    case listen(errno: Int32)
    case connect(errno: Int32)
    case closed
    case tooLong
    case badResponse
}

/// Reads once into `buffer`, retrying automatically on `EINTR`. Returns the
/// number of bytes read (0 = EOF, negative = a real error, with `errno` set).
private func readRetryingEINTR(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) -> Int {
    while true {
        let n = read(fd, buffer.baseAddress, buffer.count)
        if n < 0 && errno == EINTR { continue }
        return n
    }
}

/// Writes `data` followed by a trailing `"\n"` to `fd`, retrying on `EINTR`
/// and looping over partial writes. Returns `false` on any real error or
/// short write that can't be recovered from (e.g. the peer closed).
private func writeLineRetryingEINTR(fd: Int32, data: Data) -> Bool {
    var payload = data
    payload.append(0x0A)
    return payload.withUnsafeBytes { rawBuffer -> Bool in
        guard let base = rawBuffer.baseAddress else { return true }
        var totalWritten = 0
        let count = rawBuffer.count
        while totalWritten < count {
            let n = write(fd, base + totalWritten, count - totalWritten)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            totalWritten += n
        }
        return true
    }
}

/// A Unix-domain socket server speaking the copystack newline-delimited
/// JSON protocol. Accepts connections on a background thread, one thread
/// per connection, and rejects peers whose uid doesn't match ours.
public final class SocketServer {
    public struct Connection {
        public let id: ConnectionID
        public let peerUID: uid_t
    }

    public typealias ConnectionID = Int

    private let path: String
    private let onConnect: (Connection) -> Void
    private let onLine: (Connection, Data) -> Data?
    private let onClose: (Connection) -> Void
    private let maxLineLength: Int

    private let stateLock = NSLock()
    private var listenerFD: Int32 = -1
    private var nextConnectionID: ConnectionID = 0
    private var openConnectionFDs: [ConnectionID: Int32] = [:]
    private var running = false

    public init(
        path: String,
        onConnect: @escaping (Connection) -> Void,
        onLine: @escaping (Connection, Data) -> Data?,
        onClose: @escaping (Connection) -> Void,
        maxLineLength: Int = 65_536
    ) {
        self.path = path
        self.onConnect = onConnect
        self.onLine = onLine
        self.onClose = onClose
        self.maxLineLength = maxLineLength
    }

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    /// Starts listening. Throws `.alreadyStarted` if this instance is already
    /// running (call `stop()` first to restart it).
    public func start() throws {
        stateLock.lock()
        guard !running else {
            stateLock.unlock()
            throw SocketError.alreadyStarted
        }
        stateLock.unlock()

        // A file already at `path` might be a live instance's socket, not
        // debris from a crash. Probe it with connect(): success means
        // someone is actually listening, so refuse to steal the path
        // (EADDRINUSE); a failed probe (ECONNREFUSED: nothing listening,
        // ENOENT: raced away, or any other odd failure) means it's safe to
        // remove and rebind.
        if FileManager.default.fileExists(atPath: path) {
            if SocketServer.probeExistingSocketIsLive(path: path) {
                throw SocketError.bind(errno: EADDRINUSE)
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.socketCreate(errno: errno)
        }
        SocketServer.setNoSigPipe(fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bound = SocketServer.withSockaddrPointer(path: path, addr: &addr) { sockPtr, len in
            bind(fd, sockPtr, len)
        }
        guard bound == 0 else {
            let bindErrno = errno
            close(fd)
            throw SocketError.bind(errno: bindErrno)
        }

        guard chmod(path, 0o600) == 0 else {
            let chmodErrno = errno
            close(fd)
            unlink(path)
            throw SocketError.chmod(errno: chmodErrno)
        }

        guard listen(fd, 8) == 0 else {
            let listenErrno = errno
            close(fd)
            unlink(path)
            throw SocketError.listen(errno: listenErrno)
        }

        stateLock.lock()
        listenerFD = fd
        running = true
        stateLock.unlock()

        let thread = Thread { [weak self] in
            self?.acceptLoop(listenerFD: fd)
        }
        thread.name = "copystack.socket.accept"
        thread.start()
    }

    /// Stops accepting new connections and shuts down every currently open
    /// one, then removes the socket file. Idempotent.
    ///
    /// Note: this only guarantees fds are shut down and the accept loop
    /// stops promptly (see the test that asserts it returns within a
    /// second) — it does not block until every connection thread has
    /// finished delivering its `onClose` callback, which may therefore
    /// fire slightly after `stop()` has already returned to its caller.
    public func stop() {
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        running = false
        let fd = listenerFD
        listenerFD = -1
        // Shut down every still-open connection while holding the lock, but
        // leave their entries in `openConnectionFDs` in place. Each
        // connection's own thread removes its entry (also under this lock)
        // immediately before it closes its fd — see `handleConnection` —
        // so serializing on this lock rules out a window where a fd number
        // could be closed and reused elsewhere in the process before we've
        // finished signalling every connection we know about here.
        for connFD in openConnectionFDs.values {
            shutdown(connFD, SHUT_RDWR)
        }
        stateLock.unlock()

        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        unlink(path)
    }

    // MARK: - Accept loop

    private func acceptLoop(listenerFD: Int32) {
        while true {
            stateLock.lock()
            let stillRunning = running
            stateLock.unlock()
            guard stillRunning else { return }

            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
                accept(listenerFD, ptr, &len)
            }

            if clientFD < 0 {
                switch errno {
                case EINTR, ECONNABORTED:
                    // Transient: a signal, or a peer that reset before we
                    // finished accepting it. Just try again.
                    continue
                case EMFILE, ENFILE:
                    // Out of file descriptors process- or system-wide; back
                    // off briefly rather than spinning, then retry.
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                default:
                    stateLock.lock()
                    let stillRunningAfterError = running
                    stateLock.unlock()
                    if stillRunningAfterError {
                        // An unexpected accept() failure while we're still
                        // supposed to be up (not one of the recoverable
                        // cases above, and not the listener being closed by
                        // stop(), which sets running = false first). Back
                        // off and keep trying rather than leaving the
                        // server silently dead.
                        Thread.sleep(forTimeInterval: 0.05)
                        continue
                    }
                    // Listener was closed by stop(); nothing more to do.
                    return
                }
            }

            SocketServer.setNoSigPipe(clientFD)

            guard SocketServer.peerUIDMatches(clientFD) else {
                close(clientFD)
                continue
            }

            stateLock.lock()
            guard running else {
                stateLock.unlock()
                close(clientFD)
                continue
            }
            let connectionID = nextConnectionID
            nextConnectionID += 1
            openConnectionFDs[connectionID] = clientFD
            stateLock.unlock()

            // peerUIDMatches already confirmed the peer's uid equals ours.
            let connection = Connection(id: connectionID, peerUID: getuid())
            let thread = Thread { [weak self] in
                self?.handleConnection(connection, fd: clientFD)
            }
            thread.name = "copystack.socket.conn.\(connectionID)"
            thread.start()
        }
    }

    private func handleConnection(_ connection: Connection, fd: Int32) {
        onConnect(connection)

        var framer = LineFramer(maxLineLength: maxLineLength)
        let bufferSize = 65_536
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        readLoop: while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                readRetryingEINTR(fd, into: rawBuffer)
            }
            if bytesRead <= 0 {
                // EOF (0) or a real error (<0, includes being interrupted by
                // stop()'s shutdown()); EINTR is already retried internally.
                break readLoop
            }

            let chunk = Data(bytes: buffer, count: bytesRead)
            let lines = framer.feed(chunk)
            for line in lines {
                guard let response = onLine(connection, line) else { continue }
                if !writeLineRetryingEINTR(fd: fd, data: response) {
                    break readLoop
                }
            }
            if framer.overflowed {
                if let errorResponse = try? ProtocolCodec.encode(
                    .error(code: .badRequest, message: "line too long")
                ) {
                    _ = writeLineRetryingEINTR(fd: fd, data: errorResponse)
                }
                break readLoop
            }
        }

        stateLock.lock()
        openConnectionFDs.removeValue(forKey: connection.id)
        stateLock.unlock()

        close(fd)
        onClose(connection)
    }

    // MARK: - Helpers

    fileprivate static func setNoSigPipe(_ fd: Int32) {
        var value: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Whether `fd`'s connected peer has the same uid as this process,
    /// checked via `getpeereid`.
    fileprivate static func peerUIDMatches(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == getuid()
    }

    /// Probes an existing socket file at `path` by attempting to connect to
    /// it. Returns `true` only when a live listener actually accepted the
    /// connection.
    fileprivate static func probeExistingSocketIsLive(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let result = SocketServer.withSockaddrPointer(path: path, addr: &addr) { sockPtr, len in
            connect(fd, sockPtr, len)
        }
        return result == 0
    }

    /// Builds a `sockaddr_un` for `path` and invokes `body` with a `sockaddr`
    /// pointer and its length, as `bind`/`connect` expect.
    fileprivate static func withSockaddrPointer<T>(
        path: String,
        addr: inout sockaddr_un,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T {
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: sunPathPtr.pointee)) { cPtr in
                _ = path.withCString { strncpy(cPtr, $0, 103) }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { ptr -> T in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                body(sockPtr, len)
            }
        }
    }
}

/// A client for the copystack Unix-domain socket protocol: connects, sends
/// one request, and reads exactly one newline-delimited response line.
public final class SocketClient {
    /// List responses can carry up to ~2000 clip previews of a couple KB
    /// each, so the default response limit is well above the server's
    /// request-side default.
    public static let defaultMaxResponseLength = 8 * 1024 * 1024

    private let fd: Int32
    private var framer: LineFramer
    private var closed = false
    private let lock = NSLock()

    private init(fd: Int32, maxResponseLength: Int) {
        self.fd = fd
        self.framer = LineFramer(maxLineLength: maxResponseLength)
    }

    public static func connect(
        path: String,
        maxResponseLength: Int = SocketClient.defaultMaxResponseLength
    ) throws -> SocketClient {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.connect(errno: errno)
        }
        SocketServer.setNoSigPipe(fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let result = SocketServer.withSockaddrPointer(path: path, addr: &addr) { sockPtr, len in
            Darwin.connect(fd, sockPtr, len)
        }
        guard result == 0 else {
            let connectErrno = errno
            Darwin.close(fd)
            throw SocketError.connect(errno: connectErrno)
        }
        return SocketClient(fd: fd, maxResponseLength: maxResponseLength)
    }

    public func send(_ request: Request) throws -> Response {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw SocketError.closed }

        let payload = try ProtocolCodec.encode(request)
        guard writeLineRetryingEINTR(fd: fd, data: payload) else {
            throw SocketError.closed
        }

        let bufferSize = 65_536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                readRetryingEINTR(fd, into: rawBuffer)
            }
            guard bytesRead > 0 else {
                throw SocketError.closed
            }
            let chunk = Data(bytes: buffer, count: bytesRead)
            let lines = framer.feed(chunk)
            if framer.overflowed {
                throw SocketError.tooLong
            }
            if let line = lines.first {
                return try ProtocolCodec.decodeResponse(line)
            }
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

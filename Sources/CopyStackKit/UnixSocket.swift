import Foundation
import Darwin

/// Errors raised by `SocketServer` and `SocketClient`.
public enum SocketError: Error, Equatable {
    case bind(errno: Int32)
    case listen(errno: Int32)
    case connect(errno: Int32)
    case closed
    case tooLong
    case badResponse
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
    private var acceptThread: Thread?
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

    public func start() throws {
        // Remove a stale socket file left behind by a previous run.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.bind(errno: errno)
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
            throw SocketError.bind(errno: chmodErrno)
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
        acceptThread = thread
        thread.start()
    }

    public func stop() {
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        running = false
        let fd = listenerFD
        listenerFD = -1
        let fdsToClose = Array(openConnectionFDs.values)
        openConnectionFDs.removeAll()
        stateLock.unlock()

        if fd >= 0 {
            // A client's connect() can succeed and sit in the kernel accept
            // backlog before our accept loop thread calls accept() on it.
            // Drain any such pending connections here so their onConnect/
            // onClose still fire, before we stop accepting altogether.
            drainPendingConnections(listenerFD: fd)
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        for connFD in fdsToClose {
            shutdown(connFD, SHUT_RDWR)
        }
        unlink(path)
    }

    /// Non-blocking accept loop used only from `stop()`, to pull any
    /// already-established connections out of the backlog before the
    /// listener socket is torn down. Setting the fd non-blocking here also
    /// unblocks a concurrent blocking `accept()` call in `acceptLoop`, since
    /// the flag applies to the shared open file description.
    private func drainPendingConnections(listenerFD: Int32) {
        let flags = fcntl(listenerFD, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(listenerFD, F_SETFL, flags | O_NONBLOCK)

        while true {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
                accept(listenerFD, ptr, &len)
            }
            guard clientFD >= 0 else { break }

            SocketServer.setNoSigPipe(clientFD)
            var peerCred = xucred()
            var credLen = socklen_t(MemoryLayout<xucred>.size)
            let credResult = getsockopt(clientFD, 0 /* SOL_LOCAL */, 1 /* LOCAL_PEERCRED */, &peerCred, &credLen)
            guard credResult == 0, peerCred.cr_uid == getuid() else {
                close(clientFD)
                continue
            }

            stateLock.lock()
            let connectionID = nextConnectionID
            nextConnectionID += 1
            stateLock.unlock()

            let connection = Connection(id: connectionID, peerUID: peerCred.cr_uid)
            onConnect(connection)
            shutdown(clientFD, SHUT_RDWR)
            close(clientFD)
            onClose(connection)
        }
    }

    // MARK: - Accept loop

    private func acceptLoop(listenerFD: Int32) {
        while true {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
                accept(listenerFD, ptr, &len)
            }
            guard clientFD >= 0 else {
                // Listener was closed (stop()) or a real error; either way, exit.
                return
            }

            stateLock.lock()
            let stillRunning = running
            stateLock.unlock()
            guard stillRunning else {
                close(clientFD)
                return
            }

            SocketServer.setNoSigPipe(clientFD)

            var peerCred = xucred()
            var credLen = socklen_t(MemoryLayout<xucred>.size)
            let credResult = getsockopt(clientFD, 0 /* SOL_LOCAL */, 1 /* LOCAL_PEERCRED */, &peerCred, &credLen)
            let peerUID: uid_t
            if credResult == 0 {
                peerUID = peerCred.cr_uid
            } else {
                // Fall back: cannot verify identity, treat as untrusted.
                close(clientFD)
                continue
            }

            guard peerUID == getuid() else {
                close(clientFD)
                continue
            }

            stateLock.lock()
            let connectionID = nextConnectionID
            nextConnectionID += 1
            openConnectionFDs[connectionID] = clientFD
            stateLock.unlock()

            let connection = Connection(id: connectionID, peerUID: peerUID)
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
                read(fd, rawBuffer.baseAddress, bufferSize)
            }
            if bytesRead <= 0 {
                // EOF (0) or error (<0, includes being interrupted by stop()'s shutdown()).
                break readLoop
            }

            let chunk = Data(bytes: buffer, count: bytesRead)
            let lines = framer.feed(chunk)
            for line in lines {
                guard let response = onLine(connection, line) else { continue }
                if !writeLine(fd: fd, data: response) {
                    break readLoop
                }
            }
            if framer.overflowed {
                if let errorResponse = try? ProtocolCodec.encode(
                    .error(code: .badRequest, message: "line too long")
                ) {
                    _ = writeLine(fd: fd, data: errorResponse)
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

    private func writeLine(fd: Int32, data: Data) -> Bool {
        var payload = data
        payload.append(0x0A)
        let written = payload.withUnsafeBytes { rawBuffer -> Int in
            write(fd, rawBuffer.baseAddress, rawBuffer.count)
        }
        return written == payload.count
    }

    // MARK: - Helpers

    fileprivate static func setNoSigPipe(_ fd: Int32) {
        var value: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
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
    private let fd: Int32
    private var framer = LineFramer(maxLineLength: 65_536)
    private var closed = false
    private let lock = NSLock()

    private init(fd: Int32) {
        self.fd = fd
    }

    public static func connect(path: String) throws -> SocketClient {
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
        return SocketClient(fd: fd)
    }

    public func send(_ request: Request) throws -> Response {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw SocketError.closed }

        var payload = try ProtocolCodec.encode(request)
        payload.append(0x0A)
        let written = payload.withUnsafeBytes { rawBuffer -> Int in
            write(fd, rawBuffer.baseAddress, rawBuffer.count)
        }
        guard written == payload.count else {
            throw SocketError.closed
        }

        let bufferSize = 65_536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                read(fd, rawBuffer.baseAddress, bufferSize)
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

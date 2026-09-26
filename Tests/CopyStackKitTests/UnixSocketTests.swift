import XCTest
import Darwin
@testable import CopyStackKit

final class UnixSocketTests: XCTestCase {
    private var socketPaths: [String] = []
    private var rawFDs: [Int32] = []

    override func tearDown() {
        for fd in rawFDs {
            close(fd)
        }
        rawFDs.removeAll()
        for path in socketPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        socketPaths.removeAll()
        super.tearDown()
    }

    /// Short path under the temp dir; sun_path max is 103 bytes.
    private func makeSocketPath() -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs-\(UUID().uuidString.prefix(8)).sock")
            .path
        socketPaths.append(path)
        return path
    }

    private func makeServer(
        path: String,
        onConnect: @escaping (SocketServer.Connection) -> Void = { _ in },
        onLine: @escaping (SocketServer.Connection, Data) -> Data? = { _, _ in nil },
        onClose: @escaping (SocketServer.Connection) -> Void = { _ in },
        maxLineLength: Int = 65_536
    ) -> SocketServer {
        SocketServer(
            path: path,
            onConnect: onConnect,
            onLine: onLine,
            onClose: onClose,
            maxLineLength: maxLineLength
        )
    }

    /// Connects a raw AF_UNIX socket to `path`, bypassing `SocketClient`, for
    /// tests that need to observe the wire protocol or connection lifecycle
    /// directly. The fd is closed automatically in `tearDown`.
    private func connectRawSocket(path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        rawFDs.append(fd)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: ptr.pointee)) { cptr in
                _ = path.withCString { strncpy(cptr, $0, 103) }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, addrLen)
            }
        }
        XCTAssertEqual(connectResult, 0)
        return fd
    }

    // MARK: - Round trip

    func testRoundTripHelloAndList() throws {
        let path = makeSocketPath()
        let server = makeServer(path: path, onLine: { _, line in
            let result = ProtocolCodec.decodeRequest(line)
            switch result {
            case .success(.hello):
                return try? ProtocolCodec.encode(Response.ok)
            case .success(.list):
                return try? ProtocolCodec.encode(Response.clips([]))
            default:
                return try? ProtocolCodec.encode(Response.error(code: .badRequest, message: "unexpected"))
            }
        })
        try server.start()
        defer { server.stop() }

        let client = try SocketClient.connect(path: path)
        defer { client.close() }

        let helloResponse = try client.send(.hello(session: nil))
        XCTAssertEqual(helloResponse, .ok)

        let listResponse = try client.send(.list)
        XCTAssertEqual(listResponse, .clips([]))
    }

    // MARK: - File mode / lifecycle

    func testSocketFileModeAndCleanup() throws {
        let path = makeSocketPath()
        let server = makeServer(path: path)
        try server.start()

        var statInfo = stat()
        XCTAssertEqual(stat(path, &statInfo), 0)
        XCTAssertEqual(statInfo.st_mode & 0o777, 0o600)

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testStaleSocketFileIsReplaced() throws {
        let path = makeSocketPath()
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))

        let server = makeServer(path: path)
        try server.start()
        defer { server.stop() }

        var statInfo = stat()
        XCTAssertEqual(stat(path, &statInfo), 0)
        XCTAssertEqual(statInfo.st_mode & S_IFMT, S_IFSOCK)
    }

    func testStartTwiceOnSameInstanceThrows() throws {
        let path = makeSocketPath()
        let server = makeServer(path: path)
        try server.start()
        defer { server.stop() }

        XCTAssertThrowsError(try server.start()) { error in
            guard case SocketError.alreadyStarted = error else {
                XCTFail("expected .alreadyStarted, got \(error)")
                return
            }
        }
    }

    func testSecondServerOnSamePathWhileFirstIsRunningThrows() throws {
        let path = makeSocketPath()
        let server1 = makeServer(path: path)
        try server1.start()
        defer { server1.stop() }

        let server2 = makeServer(path: path)
        XCTAssertThrowsError(try server2.start()) { error in
            guard case SocketError.bind = error else {
                XCTFail("expected .bind, got \(error)")
                return
            }
        }

        // The flock-based single-instance guard must reject server2 before it
        // ever probes/unlinks the socket path, so server1's socket file (and
        // therefore server1 itself) must be completely unaffected.
        var statInfo = stat()
        XCTAssertEqual(stat(path, &statInfo), 0, "server1's socket file should still exist")
        XCTAssertEqual(statInfo.st_mode & S_IFMT, S_IFSOCK)
    }

    // MARK: - Stale-socket errno classification

    func testShouldReplaceStaleSocketClassifiesErrnos() {
        XCTAssertTrue(SocketServer.shouldReplaceStaleSocket(errno: ECONNREFUSED))
        XCTAssertTrue(SocketServer.shouldReplaceStaleSocket(errno: ENOENT))
        XCTAssertTrue(SocketServer.shouldReplaceStaleSocket(errno: ENOTSOCK))

        XCTAssertFalse(SocketServer.shouldReplaceStaleSocket(errno: EACCES))
        XCTAssertFalse(SocketServer.shouldReplaceStaleSocket(errno: EPERM))
    }

    // MARK: - onConnect / onClose

    func testOnConnectAndOnCloseFireOnceForGracefulClose() throws {
        let path = makeSocketPath()
        let connectExpectation = expectation(description: "onConnect")
        let closeExpectation = expectation(description: "onClose")

        let server = makeServer(
            path: path,
            onConnect: { _ in connectExpectation.fulfill() },
            onClose: { _ in closeExpectation.fulfill() }
        )
        try server.start()
        defer { server.stop() }

        let client = try SocketClient.connect(path: path)
        wait(for: [connectExpectation], timeout: 2)
        client.close()
        wait(for: [closeExpectation], timeout: 2)
    }

    func testOnConnectAndOnCloseFireOnceForAbruptClose() throws {
        let path = makeSocketPath()
        let connectExpectation = expectation(description: "onConnect")
        let closeExpectation = expectation(description: "onClose")

        let server = makeServer(
            path: path,
            onConnect: { _ in connectExpectation.fulfill() },
            onClose: { _ in closeExpectation.fulfill() }
        )
        try server.start()
        defer { server.stop() }

        let fd = connectRawSocket(path: path)

        wait(for: [connectExpectation], timeout: 2)
        close(fd)
        wait(for: [closeExpectation], timeout: 2)
    }

    // MARK: - Overflow

    func testOversizedLineYieldsBadRequestAndCloses() throws {
        let path = makeSocketPath()
        let closeExpectation = expectation(description: "onClose")
        let server = makeServer(
            path: path,
            onLine: { _, _ in try? ProtocolCodec.encode(Response.ok) },
            onClose: { _ in closeExpectation.fulfill() },
            maxLineLength: 65_536
        )
        try server.start()
        defer { server.stop() }

        let fd = connectRawSocket(path: path)

        // 70 KB request line: exceeds the 64 KB limit.
        let hugeSession = String(repeating: "x", count: 70 * 1024)
        var payload = try ProtocolCodec.encode(Request.hello(session: hugeSession))
        payload.append(0x0A)
        let written = payload.withUnsafeBytes { rawBuffer -> Int in
            write(fd, rawBuffer.baseAddress, rawBuffer.count)
        }
        XCTAssertEqual(written, payload.count)

        // Read exactly one response line, byte by byte, up to the newline.
        var responseData = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            XCTAssertGreaterThan(n, 0, "expected a badRequest response line before EOF")
            guard n > 0 else { break }
            if byte == 0x0A { break }
            responseData.append(byte)
        }
        let response = try ProtocolCodec.decodeResponse(responseData)
        if case .error(let code, _) = response {
            XCTAssertEqual(code, .badRequest)
        } else {
            XCTFail("expected badRequest error, got \(response)")
        }

        // The server closes the connection right after: next read is EOF.
        let eofResult = read(fd, &byte, 1)
        XCTAssertEqual(eofResult, 0, "expected EOF after the badRequest response")

        wait(for: [closeExpectation], timeout: 2)
    }

    // MARK: - Concurrency

    func testTwoClientsGetOwnRepliesConcurrently() throws {
        let path = makeSocketPath()
        let server = makeServer(path: path, onLine: { _, line in
            guard case .success(.get(let id)) = ProtocolCodec.decodeRequest(line) else {
                return try? ProtocolCodec.encode(Response.error(code: .badRequest, message: "unexpected"))
            }
            return try? ProtocolCodec.encode(Response.content(.text(id.uuidString)))
        })
        try server.start()
        defer { server.stop() }

        let client1 = try SocketClient.connect(path: path)
        let client2 = try SocketClient.connect(path: path)
        defer {
            client1.close()
            client2.close()
        }

        let id1 = UUID()
        let id2 = UUID()
        var response1: Response?
        var response2: Response?

        DispatchQueue.concurrentPerform(iterations: 2) { index in
            if index == 0 {
                response1 = try? client1.send(.get(id: id1))
            } else {
                response2 = try? client2.send(.get(id: id2))
            }
        }

        XCTAssertEqual(response1, .content(.text(id1.uuidString)))
        XCTAssertEqual(response2, .content(.text(id2.uuidString)))
    }

    // MARK: - No listener

    func testConnectWithNoListenerThrows() throws {
        let path = makeSocketPath()
        XCTAssertThrowsError(try SocketClient.connect(path: path)) { error in
            guard case SocketError.connect = error else {
                XCTFail("expected .connect, got \(error)")
                return
            }
        }
    }

    // MARK: - Client response length

    func testCustomMaxResponseLengthIsHonored() throws {
        let path = makeSocketPath()
        let bigText = String(repeating: "y", count: 2048)
        let server = makeServer(path: path, onLine: { _, _ in
            try? ProtocolCodec.encode(Response.content(.text(bigText)))
        })
        try server.start()
        defer { server.stop() }

        let client = try SocketClient.connect(path: path, maxResponseLength: 100)
        defer { client.close() }

        XCTAssertThrowsError(try client.send(.list)) { error in
            guard case SocketError.tooLong = error else {
                XCTFail("expected .tooLong, got \(error)")
                return
            }
        }
    }

    // MARK: - stop() promptness

    func testStopWhileClientConnectedReturnsPromptlyAndFiresOnClose() throws {
        let path = makeSocketPath()
        let connectExpectation = expectation(description: "onConnect")
        let closeExpectation = expectation(description: "onClose")
        let server = makeServer(
            path: path,
            onConnect: { _ in connectExpectation.fulfill() },
            onClose: { _ in closeExpectation.fulfill() }
        )
        try server.start()

        let client = try SocketClient.connect(path: path)
        defer { client.close() }
        wait(for: [connectExpectation], timeout: 2)

        let start = Date()
        server.stop()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0)

        wait(for: [closeExpectation], timeout: 1)
    }
}

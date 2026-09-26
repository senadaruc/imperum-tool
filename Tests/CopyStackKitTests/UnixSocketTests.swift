import XCTest
import Darwin
@testable import CopyStackKit

final class UnixSocketTests: XCTestCase {
    private var socketPaths: [String] = []

    override func tearDown() {
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

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
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

        let client = try SocketClient.connect(path: path)
        defer { client.close() }

        // 70 KB request line: exceeds the 64 KB limit.
        let hugeSession = String(repeating: "x", count: 70 * 1024)
        do {
            let response = try client.send(.hello(session: hugeSession))
            if case .error(let code, _) = response {
                XCTAssertEqual(code, .badRequest)
            } else {
                XCTFail("expected badRequest error, got \(response)")
            }
        } catch {
            // Connection may also just close before a full response is read;
            // that is an acceptable observation of "connection closes".
        }
        wait(for: [closeExpectation], timeout: 2)
    }

    // MARK: - Concurrency

    func testTwoClientsGetOwnReplies() throws {
        let path = makeSocketPath()
        let server = makeServer(path: path, onLine: { _, line in
            let result = ProtocolCodec.decodeRequest(line)
            if case .success(.hello) = result {
                return try? ProtocolCodec.encode(Response.ok)
            }
            if case .success(.list) = result {
                return try? ProtocolCodec.encode(Response.clips([]))
            }
            return try? ProtocolCodec.encode(Response.error(code: .badRequest, message: "unexpected"))
        })
        try server.start()
        defer { server.stop() }

        let client1 = try SocketClient.connect(path: path)
        let client2 = try SocketClient.connect(path: path)
        defer {
            client1.close()
            client2.close()
        }

        let response1 = try client1.send(.hello(session: nil))
        let response2 = try client2.send(.list)
        XCTAssertEqual(response1, .ok)
        XCTAssertEqual(response2, .clips([]))
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

    // MARK: - stop() promptness

    func testStopWhileClientConnectedReturnsPromptlyAndFiresOnClose() throws {
        let path = makeSocketPath()
        let closeExpectation = expectation(description: "onClose")
        let server = makeServer(path: path, onClose: { _ in closeExpectation.fulfill() })
        try server.start()

        let client = try SocketClient.connect(path: path)
        defer { client.close() }

        let start = Date()
        server.stop()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0)

        wait(for: [closeExpectation], timeout: 1)
    }
}

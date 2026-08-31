import XCTest
@testable import WLKit

/// Exercises `HerdrClient.request`'s failure branches and the socket line
/// reassembly against an in-process Unix-socket server — no Herdr needed.
/// Every branch here surfaces to the user as `lastError` in the menu bar, so
/// the wrong branch means the wrong message.
final class HerdrRequestTests: XCTestCase {

    private var server: FakeUnixServer!
    private var savedPath: String?

    override func setUp() {
        super.setUp()
        savedPath = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
    }

    override func tearDown() {
        server?.close()
        server = nil
        if let savedPath { setenv("HERDR_SOCKET_PATH", savedPath, 1) } else { unsetenv("HERDR_SOCKET_PATH") }
        super.tearDown()
    }

    private func serve(_ handler: @escaping (Int32) -> Void) throws {
        server = try FakeUnixServer(handler: handler)
        setenv("HERDR_SOCKET_PATH", server.path, 1)
    }

    private func requestError(timeout: TimeInterval = 5) async -> HerdrError? {
        do {
            _ = try await HerdrClient.request("test.method", timeout: timeout)
            return nil
        } catch {
            return error as? HerdrError
        }
    }

    func testSuccessCarriesTheResultObject() async throws {
        try serve { fd in
            FakeUnixServer.readLine(fd)
            FakeUnixServer.write(fd, "{\"id\":\"x\",\"result\":{\"answer\":42}}\n")
        }
        let result = try await HerdrClient.request("test.method")
        XCTAssertEqual(result["answer"] as? Int, 42)
    }

    func testNonJSONLineIsABadResponse() async throws {
        try serve { fd in
            FakeUnixServer.readLine(fd)
            FakeUnixServer.write(fd, "not json\n")
        }
        guard case .badResponse(let detail)? = await requestError() else {
            return XCTFail("expected badResponse")
        }
        XCTAssertEqual(detail, "not json")
    }

    func testErrorEnvelopeBecomesAnAPIError() async throws {
        try serve { fd in
            FakeUnixServer.readLine(fd)
            FakeUnixServer.write(fd, "{\"id\":\"x\",\"error\":{\"message\":\"agent_not_found\"}}\n")
        }
        guard case .api(let message)? = await requestError() else {
            return XCTFail("expected api error")
        }
        XCTAssertEqual(message, "agent_not_found")
    }

    func testNoReplyTimesOut() async throws {
        try serve { fd in
            FakeUnixServer.readLine(fd)
            // Hold the connection open without answering.
            Thread.sleep(forTimeInterval: 2)
            Darwin.close(fd)
        }
        guard case .timeout? = await requestError(timeout: 0.3) else {
            return XCTFail("expected timeout")
        }
    }

    func testCloseWithoutReplyReportsClosed() async throws {
        try serve { fd in
            FakeUnixServer.readLine(fd)
            Darwin.close(fd)
        }
        guard case .closed? = await requestError() else {
            return XCTFail("expected closed")
        }
    }

    /// One logical line delivered in three writes must arrive as one response
    /// — partial reads are the normal case on a busy socket, and merging them
    /// wrongly shows up as a pad that stops updating.
    func testLineSplitAcrossWritesReassembles() async throws {
        try serve { fd in
            FakeUnixServer.readLine(fd)
            FakeUnixServer.write(fd, "{\"id\":\"x\",\"resu")
            Thread.sleep(forTimeInterval: 0.05)
            FakeUnixServer.write(fd, "lt\":{\"agents\"")
            Thread.sleep(forTimeInterval: 0.05)
            FakeUnixServer.write(fd, ":[]}}\n")
        }
        let result = try await HerdrClient.request("test.method")
        XCTAssertEqual((result["agents"] as? [Any])?.count, 0)
    }

    /// A multi-byte character split across two reads must survive intact —
    /// agent working directories are arbitrary paths.
    func testUTF8SplitAcrossWritesSurvives() async throws {
        let payload = "{\"id\":\"x\",\"result\":{\"name\":\"café\"}}\n"
        let bytes = Array(payload.utf8)
        // Split inside the two-byte "é".
        let split = bytes.count - 4
        try serve { fd in
            FakeUnixServer.readLine(fd)
            FakeUnixServer.write(fd, Array(bytes[..<split]))
            Thread.sleep(forTimeInterval: 0.05)
            FakeUnixServer.write(fd, Array(bytes[split...]))
        }
        let result = try await HerdrClient.request("test.method")
        XCTAssertEqual(result["name"] as? String, "café")
    }

    /// Two lines in one packet: the request takes the first and the latch
    /// swallows the second without a second resume (which would crash).
    func testSecondLineOnTheSameConnectionIsIgnored() async throws {
        try serve { fd in
            FakeUnixServer.readLine(fd)
            FakeUnixServer.write(fd, "{\"id\":\"x\",\"result\":{\"n\":1}}\n{\"id\":\"y\",\"result\":{\"n\":2}}\n")
        }
        let result = try await HerdrClient.request("test.method")
        XCTAssertEqual(result["n"] as? Int, 1)
    }
}

/// A minimal in-process AF_UNIX listener. Each accepted connection is handed
/// to `handler` on a background queue; the handler owns the client fd.
final class FakeUnixServer {
    let path: String
    private let listenFD: Int32
    private let queue = DispatchQueue(label: "fake-herdr-server", attributes: .concurrent)
    private let closedLock = NSLock()
    private var isClosed = false

    init(handler: @escaping (Int32) -> Void) throws {
        path = NSTemporaryDirectory() + "wl-\(UInt32.random(in: 0..<UInt32.max)).sock"
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else { throw POSIXError(.ENAMETOOLONG) }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self), source, maxLength - 1)
            }
        }
        unlink(path)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listenFD, $0, size) }
        }
        guard bound == 0, listen(listenFD, 4) == 0 else {
            Darwin.close(listenFD)
            throw POSIXError(.EIO)
        }

        queue.async { [listenFD, queue] in
            while true {
                let client = accept(listenFD, nil, nil)
                guard client >= 0 else { break }
                queue.async { handler(client) }
            }
        }
    }

    func close() {
        closedLock.lock(); defer { closedLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(listenFD)
        unlink(path)
    }

    deinit { close() }

    /// Reads until a newline or EOF; the servers here only need to consume
    /// the request before answering.
    static func readLine(_ fd: Int32) {
        var byte: UInt8 = 0
        while Darwin.read(fd, &byte, 1) == 1, byte != UInt8(ascii: "\n") {}
    }

    static func write(_ fd: Int32, _ text: String) {
        write(fd, Array(text.utf8))
    }

    static func write(_ fd: Int32, _ bytes: [UInt8]) {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress, raw.count)
            }
            if n <= 0 { break }
            sent += n
        }
    }
}

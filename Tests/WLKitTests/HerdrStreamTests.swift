import XCTest
@testable import WLKit

/// The subscription stream and the socket layer's failure behaviour, against
/// the in-process fake server.
final class HerdrStreamTests: XCTestCase {

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

    func testAckThenEventsFlowInOrder() throws {
        try serve { fd in
            FakeUnixServer.readLine(fd)
            FakeUnixServer.write(fd, "{\"id\":\"wl_sub\",\"result\":{}}\n")
            FakeUnixServer.write(fd, "{\"type\":\"pane.created\",\"pane_id\":\"p9\"}\n")
        }

        let ready = expectation(description: "ready")
        let event = expectation(description: "event")
        let stream = HerdrEventStream(subscriptions: [["type": "pane.created"]])
        stream.onReady = { ready.fulfill() }
        stream.onEvent = { object in
            XCTAssertEqual(object["pane_id"] as? String, "p9")
            event.fulfill()
        }
        stream.start()
        wait(for: [ready, event], timeout: 3, enforceOrder: true)
        stream.stop()
    }

    /// A rejected subscription must close the stream with the error — the
    /// old code took any first line as the acknowledgement, so the bridge
    /// believed it had live events for a pane it did not.
    func testRejectedSubscriptionClosesWithTheError() throws {
        try serve { fd in
            FakeUnixServer.readLine(fd)
            // The rejection and a trailing line in one packet: the trailing
            // line is already buffered when the rejection closes the stream,
            // and must be swallowed rather than surfaced as an event.
            FakeUnixServer.write(
                fd,
                "{\"id\":\"wl_sub\",\"error\":{\"message\":\"unknown event type\"}}\n"
                + "{\"type\":\"pane.created\"}\n"
            )
        }

        let closed = expectation(description: "closed with the api error")
        let stream = HerdrEventStream(subscriptions: [["type": "bogus"]])
        stream.onReady = { XCTFail("a rejection is not an acknowledgement") }
        stream.onEvent = { _ in XCTFail("no event may follow a rejection") }
        stream.onClosed = { error in
            guard case HerdrError.api(let message)? = error as? HerdrError else {
                return XCTFail("expected HerdrError.api, got \(String(describing: error))")
            }
            XCTAssertEqual(message, "unknown event type")
            closed.fulfill()
        }
        stream.start()
        wait(for: [closed], timeout: 3)
    }

    /// The peer closing before the request is even written must surface as an
    /// error — without SO_NOSIGPIPE that write raises SIGPIPE and kills the
    /// whole process instead.
    func testPeerClosingImmediatelyDoesNotKillTheProcess() async throws {
        try serve { fd in
            Darwin.close(fd)
        }
        do {
            _ = try await HerdrClient.request("test.method", timeout: 2)
            XCTFail("expected an error")
        } catch {
            // Any HerdrError is fine — the point is surviving to throw one.
            XCTAssertNotNil(error as? HerdrError)
        }
    }

    /// A peer that streams bytes with no newline must be dropped, not
    /// buffered without bound.
    func testEndlessLineDropsTheConnection() throws {
        try serve { fd in
            let junk = [UInt8](repeating: UInt8(ascii: "x"), count: 64 * 1024)
            // Well past the 1 MB cap.
            for _ in 0..<20 { FakeUnixServer.write(fd, junk) }
            // Keep the connection open: the *client* must be the one to give up.
            var byte: UInt8 = 0
            while Darwin.read(fd, &byte, 1) == 1 {}
            Darwin.close(fd)
        }

        let closed = expectation(description: "connection dropped")
        let conn = SocketConnection(path: server.path)
        conn.onLine = { _ in XCTFail("no line should ever complete") }
        conn.onClosed = { _ in closed.fulfill() }
        try conn.open()
        wait(for: [closed], timeout: 5)
        conn.close()
    }
}

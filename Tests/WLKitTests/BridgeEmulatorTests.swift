import XCTest
@testable import WLKit

/// Drives the whole bridge over the PadEmulator (and, where Herdr is needed,
/// an in-process fake server) — the first tests `BridgeController` has ever
/// had, over the seams that were built for exactly this.
@MainActor
final class BridgeEmulatorTests: XCTestCase {

    private var server: FakeUnixServer?
    private var savedPath: String?

    override func setUp() {
        super.setUp()
        savedPath = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
        // Point Herdr at nowhere by default: a developer's live server must
        // not leak agents into these tests.
        setenv("HERDR_SOCKET_PATH", "/nonexistent/herdr.sock", 1)
    }

    override func tearDown() {
        server?.close()
        server = nil
        if let savedPath { setenv("HERDR_SOCKET_PATH", savedPath, 1) } else { unsetenv("HERDR_SOCKET_PATH") }
        super.tearDown()
    }

    // MARK: - Contending-client detection

    func testForeignResponseFlagsContendingClient() {
        let bridge = BridgeController()
        bridge.device.onResponse?(500, ["ok": 1], nil)
        XCTAssertTrue(bridge.contendingClient)
    }

    /// 999 of our own calls walk the id counter through its full 1…998 wrap.
    /// Every reply balances its issue, so the alarm must stay quiet.
    func testOwnTrafficAcrossTheIDWrapStaysUncontended() async {
        let bridge = BridgeController()
        await bridge.useEmulator(true)
        try? bridge.device.connect()
        // Awaited one at a time, as real bridge traffic is — the ledger is a
        // set, so ids may only recur once their previous flight has landed.
        for _ in 0..<999 {
            await withCheckedContinuation { done in
                _ = bridge.device.call("sys.version", params: nil) { _, _ in done.resume() }
            }
        }
        XCTAssertFalse(bridge.contendingClient)
    }

    /// A timed-out id is dropped from the ledger, so its reuse after the wrap
    /// balances cleanly instead of raising a phantom alarm.
    func testTimedOutIDIsForgotten() {
        let bridge = BridgeController()
        bridge.device.onTX?("sys.version", nil, 42)
        bridge.device.onTimeout?(42)
        // The counter wrapped and id 42 went out again; its reply must match
        // the new issue, not double-count against the stale one.
        bridge.device.onTX?("sys.version", nil, 42)
        bridge.device.onResponse?(42, ["ok": 1], nil)
        XCTAssertFalse(bridge.contendingClient)
        // Only now is a second reply to the same id genuinely foreign.
        bridge.device.onResponse?(42, ["ok": 1], nil)
        XCTAssertTrue(bridge.contendingClient)
    }

    // MARK: - Keymap verification

    /// The firmware answers {"ok":1} to a keymap it did not apply; the
    /// read-back is the only thing that catches it. This is the module's
    /// stated reason to exist, previously untested.
    func testApplyThrowsWhenTheFirmwareLies() async throws {
        let pad = PadEmulator()
        pad.ignoreWrites = true
        let device = WLDevice(emulator: pad)
        try device.connect()
        do {
            _ = try await KeymapManager.apply(device)
            XCTFail("expected notAccepted")
        } catch KeymapManager.Failure.notAccepted {
            // expected
        }
    }

    func testBridgeReportsKeymapNotReadyWhenTheFirmwareLies() async {
        let bridge = BridgeController()
        await bridge.useEmulator(true)
        bridge.emulator?.ignoreWrites = true
        await bridge.start()
        XCTAssertTrue(bridge.isRunning)
        XCTAssertTrue(bridge.deviceConnected)
        XCTAssertFalse(bridge.keymapReady)
        await bridge.stop()
    }

    // MARK: - Lifecycle

    func testStopClearsEveryThreadIDAndTheZones() async {
        let bridge = BridgeController()
        await bridge.useEmulator(true)
        await bridge.start()
        let pad = try! XCTUnwrap(bridge.emulator)
        await bridge.stop()

        for id in 0...Pad.maxThreadID {
            XCTAssertFalse(pad.keys[id]?.isLit ?? false, "key \(id) still lit after stop")
        }
        XCTAssertEqual(pad.keysZone, .dark)
        XCTAssertEqual(pad.ambientZone, .dark)
        XCTAssertFalse(bridge.isRunning)
        XCTAssertFalse(bridge.deviceConnected)
    }

    /// A start racing a stop must resolve to a consistent end state — the old
    /// unserialised pair could finish with isRunning true and a disconnected
    /// device.
    func testFastToggleLandsInAConsistentState() async {
        let bridge = BridgeController()
        await bridge.useEmulator(true)
        async let first: Void = bridge.start()
        async let second: Void = bridge.stop()
        _ = await (first, second)
        XCTAssertEqual(bridge.isRunning, bridge.device.isConnected,
                       "running flag and device connection must agree")
        await bridge.stop()
    }

    // MARK: - Errors

    /// A voice/tune error noted from the app layer must survive the poll; the
    /// poll's own error may be cleared by the next healthy poll.
    func testNotedErrorsSurviveASuccessfulPoll() async {
        let box = AgentBox([])
        server = try? herdrServer(box)
        var config = BridgeConfig()
        config.pollInterval = 0.05
        let bridge = BridgeController(config: config)
        await bridge.useEmulator(true)
        await bridge.start()

        bridge.noteError("Accessibility permission is missing.")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(bridge.lastError, "Accessibility permission is missing.")
        await bridge.stop()
    }

    // MARK: - End to end over a fake Herdr

    func testAgentStatusReachesKeysAndUnderglow() async throws {
        let box = AgentBox([
            ["agent": "claude", "agent_status": "working", "pane_id": "p1"],
            ["agent": "claude", "agent_status": "idle", "pane_id": "p2"],
        ])
        server = try herdrServer(box)
        var config = BridgeConfig()
        config.pollInterval = 0.1
        let bridge = BridgeController(config: config)
        await bridge.useEmulator(true)
        await bridge.start()
        let pad = try XCTUnwrap(bridge.emulator)

        // Slot 0 lights Pad.agentKeyIDs[0] = key 1, slot 1 lights key 0.
        XCTAssertEqual(pad.keys[Pad.agentKeyIDs[0]]?.color, 0xFFA000, "working is amber")
        XCTAssertEqual(pad.keys[Pad.agentKeyIDs[1]]?.color, 0x00C853, "idle is green")
        XCTAssertEqual(pad.ambientZone.color, 0xFFA000, "underglow carries the worst state")

        // One agent finishes: the aggregate stays "working", but the changed
        // key must still repaint — the fingerprint covers the whole picture,
        // not just the aggregate.
        box.set([
            ["agent": "claude", "agent_status": "working", "pane_id": "p1"],
            ["agent": "claude", "agent_status": "done", "pane_id": "p2"],
        ])
        try await waitUntil("done turns the second key blue") {
            pad.keys[Pad.agentKeyIDs[1]]?.color == 0x00B0FF
        }
        XCTAssertEqual(pad.ambientZone.color, 0xFFA000, "aggregate unchanged")

        // The worst state worsens: underglow follows.
        box.set([
            ["agent": "claude", "agent_status": "blocked", "pane_id": "p1"],
            ["agent": "claude", "agent_status": "done", "pane_id": "p2"],
        ])
        try await waitUntil("blocked reaches the underglow") {
            pad.ambientZone.color == 0xFF2D2D
        }
        XCTAssertEqual(pad.keys[Pad.agentKeyIDs[0]]?.effect, .breath, "blocked breathes")

        // All agents gone: keys clear rather than going stale.
        box.set([])
        try await waitUntil("vanished agents clear their keys") {
            !(pad.keys[Pad.agentKeyIDs[0]]?.isLit ?? false)
        }
        await bridge.stop()
    }

    // MARK: - Helpers

    private func waitUntil(
        _ what: String,
        deadline: TimeInterval = 3,
        _ condition: () -> Bool
    ) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > deadline {
                return XCTFail("timed out waiting until \(what)")
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// A fake Herdr: answers `agent.list` from the box, acknowledges any
    /// subscription and then holds its connection open, and answers anything
    /// else with an empty result.
    private func herdrServer(_ box: AgentBox) throws -> FakeUnixServer {
        let server = try FakeUnixServer { fd in
            var request = [UInt8]()
            var byte: UInt8 = 0
            while Darwin.read(fd, &byte, 1) == 1, byte != UInt8(ascii: "\n") { request.append(byte) }
            let text = String(bytes: request, encoding: .utf8) ?? ""

            if text.contains("agent.list") {
                let payload: [String: Any] = ["id": "x", "result": ["agents": box.agents]]
                if let data = try? JSONSerialization.data(withJSONObject: payload) {
                    FakeUnixServer.write(fd, [UInt8](data) + [UInt8(ascii: "\n")])
                }
                Darwin.close(fd)
            } else if text.contains("events.subscribe") {
                FakeUnixServer.write(fd, "{\"id\":\"wl_sub\",\"result\":{}}\n")
                // Hold the subscription open until the client hangs up.
                while Darwin.read(fd, &byte, 1) == 1 {}
                Darwin.close(fd)
            } else {
                FakeUnixServer.write(fd, "{\"id\":\"x\",\"result\":{}}\n")
                Darwin.close(fd)
            }
        }
        setenv("HERDR_SOCKET_PATH", server.path, 1)
        return server
    }
}

/// Mutable agent state shared with the fake server's handler threads.
final class AgentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [[String: Any]]

    init(_ agents: [[String: Any]]) { value = agents }

    var agents: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ agents: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        value = agents
    }
}

import XCTest
@testable import WLKit

/// The raw-HID framing layer, fed through the `ingest` seam — the emulator
/// answers above this code, so these tests are the only thing that exercises
/// it without hardware.
final class WLDeviceFramingTests: XCTestCase {

    private func rpcReport(_ payload: [UInt8]) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 64)
        report[0] = 2               // channel: RPC (report id arrives out of band)
        report[1] = UInt8(payload.count)
        report.replaceSubrange(2..<(2 + payload.count), with: payload)
        return report
    }

    private func responses(after reports: [[UInt8]]) -> [(id: Int, result: Any?, error: String?)] {
        var seen: [(Int, Any?, String?)] = []
        let device = WLDevice()
        device.onResponse = { id, result, error in seen.append((id, result, error)) }
        reports.forEach { device.ingest(report: $0) }
        return seen
    }

    private func reports(for message: String, chunk: Int = 61) -> [[UInt8]] {
        let bytes = Array(message.utf8)
        return stride(from: 0, to: bytes.count, by: chunk).map {
            rpcReport(Array(bytes[$0..<min($0 + chunk, bytes.count)]))
        }
    }

    // MARK: - Reassembly

    func testResponseInOneReport() {
        let seen = responses(after: reports(for: "{\"id\":1,\"result\":{\"ok\":1}}"))
        XCTAssertEqual(seen.map(\.id), [1])
    }

    func testResponseSplitAcrossThreeReports() {
        let message = "{\"id\":7,\"result\":{\"version\":\"" + String(repeating: "x", count: 120) + "\"}}"
        let seen = responses(after: reports(for: message, chunk: 50))
        XCTAssertEqual(seen.map(\.id), [7])
    }

    func testTwoResponsesInOneReport() {
        let seen = responses(after: reports(for: "{\"id\":1,\"result\":{}}{\"id\":2,\"result\":{}}"))
        XCTAssertEqual(seen.map(\.id), [1, 2])
    }

    /// A multi-byte character split across two reports. The old string-based
    /// accumulator dropped the whole fragment when it ended mid-codepoint,
    /// corrupting every message after it — any response carrying a path or an
    /// agent name with a non-ASCII character killed the connection's RPC.
    func testUTF8SplitAcrossReportsSurvives() {
        let message = "{\"id\":3,\"result\":{\"name\":\"café\"}}"
        let bytes = Array(message.utf8)
        // Split inside the two-byte "é".
        let split = bytes.count - 4
        let seen = responses(after: [
            rpcReport(Array(bytes[..<split])),
            rpcReport(Array(bytes[split...])),
        ])
        XCTAssertEqual(seen.map(\.id), [3])
        XCTAssertEqual((seen.first?.result as? [String: Any])?["name"] as? String, "café")
    }

    func testFollowingMessageStillParsesAfterASplitCodepoint() {
        let first = Array("{\"id\":4,\"result\":{\"n\":\"é\"}}".utf8)
        let seen = responses(after: [
            rpcReport(Array(first[..<(first.count - 4)])),
            rpcReport(Array(first[(first.count - 4)...])),
        ] + reports(for: "{\"id\":5,\"result\":{}}"))
        XCTAssertEqual(seen.map(\.id), [4, 5])
    }

    /// Braces and escaped quotes inside JSON string values must not confuse
    /// the brace scanner — an error message or a keymap payload looks exactly
    /// like this.
    func testBracesInsideStringValues() {
        let seen = responses(after: reports(for: #"{"id":6,"result":{"m":"}{ \" {"}}"#))
        XCTAssertEqual(seen.map(\.id), [6])
        XCTAssertEqual((seen.first?.result as? [String: Any])?["m"] as? String, "}{ \" {")
    }

    func testGarbageBeforeTheFirstBraceIsSkipped() {
        let seen = responses(after: reports(for: "\u{0}\u{0}garbage{\"id\":8,\"result\":{}}"))
        XCTAssertEqual(seen.map(\.id), [8])
    }

    // MARK: - Notifications

    /// The device abbreviates its notification envelope — {"m": …, "p": …} —
    /// while responses spell out "method". Matching only the long form drops
    /// every key press.
    func testAbbreviatedNotificationEnvelope() {
        var seen: [(String, Any?)] = []
        let device = WLDevice()
        device.onNotification = { method, params in seen.append((method, params)) }
        reports(for: #"{"m":"v.oai.hid","p":{"k":"AG06","act":1}}"#).forEach { device.ingest(report: $0) }
        reports(for: #"{"method":"v.oai.hid","params":{"k":"AG07","act":1}}"#).forEach { device.ingest(report: $0) }

        XCTAssertEqual(seen.map(\.0), ["v.oai.hid", "v.oai.hid"])
        XCTAssertEqual((seen.first?.1 as? [String: Any])?["k"] as? String, "AG06")
        XCTAssertEqual((seen.last?.1 as? [String: Any])?["k"] as? String, "AG07")
    }

    // MARK: - Alignment and channels

    /// Some HID stacks hand back the report id in-band; the parser accepts
    /// the shifted alignment too.
    func testReportIDInBandStillParses() {
        let payload = Array("{\"id\":9,\"result\":{}}".utf8)
        var report = [UInt8](repeating: 0, count: 64)
        report[0] = 0x06
        report[1] = 2
        report[2] = UInt8(payload.count)
        report.replaceSubrange(3..<(3 + payload.count), with: payload)
        let seen = responses(after: [report])
        XCTAssertEqual(seen.map(\.id), [9])
    }

    func testDebugChannelLinesSurviveSplits() {
        var lines: [String] = []
        let device = WLDevice()
        device.onDeviceLog = { lines.append($0) }
        var report = [UInt8](repeating: 0, count: 64)
        let text = Array("boot ok\nbattery 8".utf8)
        report[0] = 1               // channel: firmware debug log
        report[1] = UInt8(text.count)
        report.replaceSubrange(2..<(2 + text.count), with: text)
        device.ingest(report: report)
        let rest = Array("0%\n".utf8)
        var second = [UInt8](repeating: 0, count: 64)
        second[0] = 1
        second[1] = UInt8(rest.count)
        second.replaceSubrange(2..<(2 + rest.count), with: rest)
        device.ingest(report: second)

        XCTAssertEqual(lines, ["boot ok", "battery 80%"])
    }

    /// Junk that never completes an object must not grow the accumulator
    /// without bound. (Messages arriving while the stream is poisoned may be
    /// lost — the guarantee is memory, not recovery.)
    func testUnfinishedGarbageStaysBounded() {
        let device = WLDevice()
        // 400 reports of an object that never closes: > 20 KB of junk.
        let junk = rpcReport(Array("{\"open\":\"".utf8) + Array(repeating: UInt8(ascii: "x"), count: 50))
        for _ in 0..<400 { device.ingest(report: junk) }
        XCTAssertLessThanOrEqual(device.rpcBacklogBytes, 8192 + 61)
    }

    // MARK: - Outbound frames

    func testFramesCarryHeaderAndZeroPadding() {
        let payload = Array(repeating: UInt8(ascii: "a"), count: 100)
        let frames = WLDevice.frames(for: payload)

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.map(\.count), [64, 64])
        XCTAssertEqual(Array(frames[0][0..<3]), [0x06, 0x02, 61])
        XCTAssertEqual(Array(frames[1][0..<3]), [0x06, 0x02, 39])
        XCTAssertEqual(Array(frames[0][3...]), Array(payload[0..<61]))
        XCTAssertEqual(Array(frames[1][3..<42]), Array(payload[61...]))
        XCTAssertTrue(frames[1][42...].allSatisfy { $0 == 0 }, "tail must be zero padding")
    }

    func testExactly61BytesIsOneFullFrame() {
        let frames = WLDevice.frames(for: Array(repeating: 7, count: 61))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0][2], 61)
    }

    // MARK: - Call ids

    /// The firmware rejects ids of 1000 and above, so the counter walks
    /// 1…998 and wraps.
    @MainActor
    func testCallIDsStayBelow999AndWrap() {
        let device = WLDevice(emulator: PadEmulator())
        try? device.connect()
        var ids: [Int] = []
        device.onTX = { _, _, id in ids.append(id) }
        for _ in 0..<999 { _ = device.call("sys.version", params: nil) }

        XCTAssertEqual(ids.count, 999)
        XCTAssertEqual(ids.first, 1)
        XCTAssertEqual(ids.max(), 998)
        XCTAssertEqual(ids.last, 1, "999th call must reuse id 1")
    }
}

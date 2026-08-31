import XCTest
@testable import WLKit

/// Pins the key-dispatch table in `BridgeController.handleKeyPress`. The
/// switch is the one place that has to agree with `Pad`, and a one-off in a
/// key constant silently rewires the whole pad — this is the test that
/// notices.
@MainActor
final class BridgeDispatchTests: XCTestCase {

    private var savedXDG: String?

    /// The dispatch consults the user's macro config (a configured text wins
    /// over a key's built-in role), so point the loader at an empty temp
    /// directory — the test must not change behaviour with the developer's
    /// own `~/.config/micromanager/config.json`.
    override func setUp() {
        super.setUp()
        savedXDG = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let temp = NSTemporaryDirectory() + "wl-dispatch-\(UUID().uuidString)"
        setenv("XDG_CONFIG_HOME", temp, 1)
    }

    override func tearDown() {
        if let savedXDG { setenv("XDG_CONFIG_HOME", savedXDG, 1) } else { unsetenv("XDG_CONFIG_HOME") }
        super.tearDown()
    }

    private enum Action: Equatable {
        case stack, land, voice
        case dial(Int)
        case joystick(Pad.JoystickDirection)
    }

    private func recordingBridge(into actions: NSMutableArray) -> BridgeController {
        let bridge = BridgeController()
        bridge.onStackKey = { actions.add(Action.stack) }
        bridge.onLandKey = { actions.add(Action.land) }
        bridge.onVoiceKey = { actions.add(Action.voice) }
        bridge.onDial = { actions.add(Action.dial($0)) }
        bridge.onJoystick = { actions.add(Action.joystick($0)) }
        return bridge
    }

    private func actions(after key: Int) -> [Action] {
        let recorded = NSMutableArray()
        let bridge = recordingBridge(into: recorded)
        bridge.handleKeyPress(key)
        return recorded.compactMap { $0 as? Action }
    }

    func testActionKeysReachTheirClosures() {
        XCTAssertEqual(actions(after: Pad.stackKeyID), [.stack])
        XCTAssertEqual(actions(after: Pad.landKeyID), [.land])
        for key in Pad.voiceKeyIDs {
            XCTAssertEqual(actions(after: key), [.voice], "voice key \(key)")
        }
        XCTAssertEqual(actions(after: Pad.dialUpID), [.dial(1)])
        XCTAssertEqual(actions(after: Pad.dialDownID), [.dial(-1)])
        XCTAssertEqual(actions(after: Pad.joyNorthID), [.joystick(.north)])
        XCTAssertEqual(actions(after: Pad.joySouthID), [.joystick(.south)])
        XCTAssertEqual(actions(after: Pad.joyEastID), [.joystick(.east)])
        XCTAssertEqual(actions(after: Pad.joyWestID), [.joystick(.west)])
    }

    /// Agent keys, the tab key, and macro keys route to async work, not to
    /// these closures — a press must not leak into an unrelated action.
    func testOtherKeysFireNoneOfTheClosures() {
        for key in Pad.agentKeyIDs + [Pad.tabCycleKeyID] + Pad.macroKeyIDs {
            XCTAssertEqual(actions(after: key), [], "key \(key)")
        }
    }

    /// While a land confirmation is up, the intercept turns every key into
    /// "cancel" — nothing else may fire, not even the land key's own closure
    /// when the intercept claims it.
    func testInterceptConsumesThePress() {
        let recorded = NSMutableArray()
        let bridge = recordingBridge(into: recorded)
        var intercepted: [Int] = []
        bridge.onKeyIntercept = { index in
            intercepted.append(index)
            return true
        }
        for key in 0...Pad.joyEastID { bridge.handleKeyPress(key) }
        XCTAssertEqual(recorded.count, 0)
        XCTAssertEqual(intercepted, Array(0...Pad.joyEastID))
    }

    /// An intercept that declines must leave normal dispatch untouched.
    func testDecliningInterceptLeavesDispatchAlone() {
        let recorded = NSMutableArray()
        let bridge = recordingBridge(into: recorded)
        bridge.onKeyIntercept = { _ in false }
        bridge.handleKeyPress(Pad.stackKeyID)
        XCTAssertEqual(recorded.compactMap { $0 as? Action }, [.stack])
    }

    /// A macro configured on a voice key repurposes it: the text wins and the
    /// voice closure must not fire.
    func testConfiguredMacroWinsOverTheVoiceRole() throws {
        let dir = try XCTUnwrap(ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"])
        let folder = dir + "/micromanager"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let key = Pad.voiceKeyIDs[0]
        try Data("{\"keys\": {\"\(key)\": \"hello\"}}".utf8)
            .write(to: URL(fileURLWithPath: folder + "/config.json"))

        XCTAssertEqual(actions(after: key), [])
    }
}

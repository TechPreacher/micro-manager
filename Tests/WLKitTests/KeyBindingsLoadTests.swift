import XCTest
@testable import WLKit

/// `KeyBindings.load()` — the file-reading path, which the parse-only tests
/// never touch.
final class KeyBindingsLoadTests: XCTestCase {

    private var savedXDG: String?
    private var directory: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedXDG = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        directory = NSTemporaryDirectory() + "wl-bindings-\(UUID().uuidString)"
        setenv("XDG_CONFIG_HOME", directory, 1)
    }

    override func tearDown() {
        if let savedXDG { setenv("XDG_CONFIG_HOME", savedXDG, 1) } else { unsetenv("XDG_CONFIG_HOME") }
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    private func writeConfig(_ text: String) throws {
        let folder = directory + "/micromanager"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: folder + "/config.json"))
    }

    func testConfigPathHonoursXDGOverride() {
        XCTAssertEqual(KeyBindings.configPath(), directory + "/micromanager/config.json")
    }

    func testMissingFileLoadsTheDefaults() {
        XCTAssertEqual(KeyBindings.load(), KeyBindings())
    }

    /// A malformed file must fall back to the defaults, not to a dead pad.
    func testMalformedFileLoadsTheDefaults() throws {
        try writeConfig("this is not json {")
        XCTAssertEqual(KeyBindings.load(), KeyBindings())
    }

    func testTopLevelArrayLoadsTheDefaults() throws {
        try writeConfig("[1, 2, 3]")
        XCTAssertEqual(KeyBindings.load(), KeyBindings())
    }

    func testConfiguredKeysMergeOverTheDefaults() throws {
        try writeConfig(#"{"keys": {"9": "custom", "10+11": "wide"}}"#)
        let bindings = KeyBindings.load()
        XCTAssertEqual(bindings.text(for: 9), "custom")
        XCTAssertEqual(bindings.text(for: 10), "wide")
        XCTAssertEqual(bindings.text(for: 11), "wide")
        XCTAssertEqual(bindings.text(for: 12), KeyBindings.defaults[12], "unmentioned keys keep their defaults")
    }

    func testNonStringAndUnparseableKeysAreSkipped() throws {
        try writeConfig(#"{"keys": {"9": 42, "wat": "x"}}"#)
        let bindings = KeyBindings.load()
        XCTAssertEqual(bindings.text(for: 9), KeyBindings.defaults[9], "a non-string value must not clobber the default")
    }

    func testEmptyStringUnbindsAKey() throws {
        try writeConfig(#"{"keys": {"9": ""}}"#)
        XCTAssertNil(KeyBindings.load().text(for: 9))
    }

    func testEmptyModelListsFallBackToTheDefaults() throws {
        try writeConfig(#"{"claude": {"models": ["", ""], "efforts": []}}"#)
        let bindings = KeyBindings.load()
        XCTAssertEqual(bindings.claudeModels, KeyBindings.defaultClaudeModels)
        XCTAssertEqual(bindings.claudeEfforts, KeyBindings.defaultClaudeEfforts)
    }
}

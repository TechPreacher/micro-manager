import XCTest
@testable import WLKit

/// `activeProfileId` is an id, not an array position. On a pad whose
/// profiles have been deleted or reordered the two diverge — and because the
/// read-back verification used the same wrong lookup as the write, binding
/// the wrong profile used to verify as success and leave every key dark.
final class KeymapProfileTests: XCTestCase {

    /// A device config where id-as-index picks the wrong profile: the active
    /// profile (id 0) sits at position 1, behind a decoy whose id is 1.
    private func reorderedConfig() -> [String: Any] {
        var config = PadEmulator.stockKeymap()
        let profiles = config["profiles"] as! [[String: Any]]
        var decoy = profiles[0]
        decoy["id"] = 1
        decoy["name"] = "Decoy"
        var active = profiles[0]
        active["id"] = 0
        active["name"] = "Active"
        config["profiles"] = [decoy, active]
        config["activeProfileId"] = 0
        return config
    }

    private func keymap(ofProfileAt index: Int, in config: [String: Any]) -> [[String]] {
        let profiles = config["profiles"] as! [[String: Any]]
        let layers = profiles[index]["layers"] as! [[String: Any]]
        let layout = layers[0]["layout"] as! [String: Any]
        return layout["keymap"] as! [[String]]
    }

    private func hasAgentBindings(_ keymap: [[String]]) -> Bool {
        keymap.flatMap { $0 }.contains { $0.hasPrefix("KV_OAI_AG") }
    }

    func testWithAgentKeymapBindsTheProfileTheIDNames() throws {
        let next = try KeymapManager.withAgentKeymap(reorderedConfig())

        XCTAssertTrue(hasAgentBindings(keymap(ofProfileAt: 1, in: next)),
                      "the profile whose id is 0 — the active one — must get the bindings")
        XCTAssertFalse(hasAgentBindings(keymap(ofProfileAt: 0, in: next)),
                       "the decoy at the id-as-index position must stay untouched")
    }

    func testVerificationAgreesWithTheWrite() throws {
        let config = reorderedConfig()
        XCTAssertFalse(KeymapManager.isAgentKeymapApplied(config))
        let next = try KeymapManager.withAgentKeymap(config)
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(next),
                      "read and write must resolve the same profile")
    }

    func testUnknownActiveIDFallsBackToTheFirstProfile() throws {
        var config = reorderedConfig()
        config["activeProfileId"] = 99
        let next = try KeymapManager.withAgentKeymap(config)
        XCTAssertTrue(hasAgentBindings(keymap(ofProfileAt: 0, in: next)))
    }

    /// The emulator resolves the active profile the same way, so a reordered
    /// keymap applied through it binds — and lights — the right keys.
    func testEmulatorResolvesProfilesByIDToo() throws {
        let pad = PadEmulator()
        let bound = try KeymapManager.withAgentKeymap(reorderedConfig())
        let data = try JSONSerialization.data(withJSONObject: bound)
        _ = pad.handle("fs.write", params: ["file": "keymap.json", "data": String(data: data, encoding: .utf8)!])
        XCTAssertTrue(pad.bound.contains(Pad.stackKeyID))
    }

    /// The double-encoded envelope's content, not just its presence.
    func testParseSurfacesTheInnerConfig() throws {
        let inner = try JSONSerialization.data(withJSONObject: reorderedConfig())
        let parsed = try KeymapManager.parse(["data": String(data: inner, encoding: .utf8)!])
        XCTAssertEqual(parsed["activeProfileId"] as? Int, 0)
        XCTAssertEqual((parsed["profiles"] as? [[String: Any]])?.count, 2)
    }
}

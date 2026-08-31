import XCTest
@testable import WLKit

/// The non-agent key threads — stack, tabs, land, voice, macro. Their colours
/// and transitions are the pad's entire feedback vocabulary for the action
/// keys, and (as with the agent statuses) a silent change is otherwise found
/// only by staring at hardware.
final class StatusMapperActionKeyTests: XCTestCase {

    private let cfg = BridgeConfig()

    func testActionKeyColoursArePinned() {
        XCTAssertEqual(StatusMapper.stackThread(open: false).color, 0x7C4DFF)
        XCTAssertEqual(StatusMapper.tabCycleThread().color, 0x00BFA5)
        XCTAssertEqual(StatusMapper.landThread(open: false).color, 0xE91E63)
        XCTAssertEqual(StatusMapper.voiceThread(id: 10, active: false).color, 0xECEFF1)
        XCTAssertEqual(StatusMapper.voiceThread(id: 10, active: true).color, 0xFF3B30)
        XCTAssertEqual(StatusMapper.macroThread(id: 9).color, 0x90A4AE)
    }

    /// Two action keys sharing a colour would read as the same key — mirrors
    /// the distinct-colours guarantee the agent statuses already have.
    func testRestingActionColoursAreDistinct() {
        let colors = [
            StatusMapper.stackThread(open: false).color,
            StatusMapper.tabCycleThread().color,
            StatusMapper.landThread(open: false).color,
            StatusMapper.voiceThread(id: 10, active: false).color,
            StatusMapper.macroThread(id: 9).color,
        ]
        XCTAssertEqual(Set(colors).count, colors.count)
    }

    /// The stack and land keys breathe at full brightness while their window
    /// is up, and sit dim and solid otherwise — dim so a bound key never
    /// reads as broken, breathing so the key that dismisses is the lit one.
    func testWindowKeysBreatheWhileOpen() {
        for open in [StatusMapper.stackThread(open: true), StatusMapper.landThread(open: true)] {
            XCTAssertEqual(open.effect, .breath)
            XCTAssertEqual(open.brightness, cfg.brightness)
        }
        for closed in [StatusMapper.stackThread(open: false), StatusMapper.landThread(open: false)] {
            XCTAssertEqual(closed.effect, .solid)
            XCTAssertEqual(closed.brightness, cfg.brightness * 0.3)
        }
    }

    func testVoiceKeySwitchesColourAndEffectWhileRecording() {
        let resting = StatusMapper.voiceThread(id: 11, active: false)
        XCTAssertEqual(resting.effect, .solid)
        XCTAssertEqual(resting.brightness, cfg.brightness * 0.25)

        let recording = StatusMapper.voiceThread(id: 11, active: true)
        XCTAssertEqual(recording.effect, .breath)
        XCTAssertEqual(recording.brightness, cfg.brightness)
        XCTAssertEqual(recording.id, 11, "each half keeps its own id")
    }

    func testMacroKeyIsDimAndSolid() {
        let thread = StatusMapper.macroThread(id: 12)
        XCTAssertEqual(thread.id, 12)
        XCTAssertEqual(thread.effect, .solid)
        XCTAssertEqual(thread.brightness, cfg.brightness * 0.25)
    }

    func testNilStateSwitchesTheZoneOff() {
        XCTAssertNil(StatusMapper.zone(for: nil))
    }
}

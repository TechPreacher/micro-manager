import XCTest
@testable import WLKit

/// Exercises the real `but` binary. Skipped where it is not installed, so the
/// suite still passes on a machine without GitButler.
final class LiveGitButlerTests: XCTestCase {

    /// Skip, don't fail: a machine without GitButler — a CI runner, say — has
    /// nothing to say about whether this code is correct. `XCTUnwrap` here
    /// would report a red suite for an absent dependency.
    private func binary() throws -> String {
        guard let path = GitButler.locateBinary() else {
            throw XCTSkip("no `but` binary on this machine")
        }
        return path
    }

    /// Not live — the override behaviour is deterministic. An executable
    /// `WL_BUT_PATH` wins the search outright; a bogus one must be ignored
    /// rather than trusted.
    func testExplicitOverrideWinsTheSearch() throws {
        let saved = ProcessInfo.processInfo.environment["WL_BUT_PATH"]
        defer { if let saved { setenv("WL_BUT_PATH", saved, 1) } else { unsetenv("WL_BUT_PATH") } }

        let dir = NSTemporaryDirectory() + "wl-but-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fake = dir + "/but"
        FileManager.default.createFile(
            atPath: fake,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )

        setenv("WL_BUT_PATH", fake, 1)
        XCTAssertEqual(GitButler.searchForBinary(), fake)

        // Non-executable: the override is ignored and the search moves on.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fake)
        XCTAssertNotEqual(GitButler.searchForBinary(), fake)
    }

    func testStatusOfThisRepoRendersToHTML() async throws {
        _ = try binary()
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WLKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .path

        let output = try await GitButler.status(in: repo)
        print("--- but status ---\n\(output.text)")
        XCTAssertFalse(output.text.isEmpty, "`but status` said nothing")

        let html = AnsiHTML.render(output.text)
        print("--- html ---\n\(html)")
        XCTAssertFalse(html.contains("\u{1B}"), "escapes must not reach the document")
        XCTAssertEqual(
            html.components(separatedBy: "<span").count,
            html.components(separatedBy: "</span>").count,
            "spans must balance"
        )
    }

    /// A directory GitButler knows nothing about must come back as a message
    /// to show, not a thrown error the panel would render as a blank window.
    func testNonProjectDirectoryReportsRatherThanThrows() async throws {
        _ = try binary()
        let output = try await GitButler.status(in: NSTemporaryDirectory())
        XCTAssertFalse(output.succeeded)
        XCTAssertFalse(output.text.isEmpty, "the failure has to say something")
    }
}

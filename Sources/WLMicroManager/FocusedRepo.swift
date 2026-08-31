import Foundation
import WLKit

/// Resolves the focused Herdr agent to the repository directory a panel
/// should work in. The stack and land panels ask the identical questions and
/// show the identical messages when the answer is no — one copy of both.
enum FocusedRepo {

    /// Why there is no directory to work in, in the shape the panels render:
    /// a window title, an optional subtitle, and the message for the body.
    struct Blocked: Error {
        var title: String
        var subtitle = ""
        var message: String
    }

    struct Resolved {
        var directory: String
        /// Last path component — what a person recognises the repo by.
        var title: String
        /// The abbreviated full path, for the subtitle line.
        var subtitle: String
    }

    static func resolve() async -> Result<Resolved, Blocked> {
        let agent: HerdrAgent?
        do {
            agent = try await HerdrClient.focusedAgent()
        } catch {
            return .failure(Blocked(title: "Herdr", message: error.localizedDescription))
        }
        guard let agent else {
            return .failure(Blocked(
                title: "No focused agent",
                message: "Nothing has focus in Herdr right now."
            ))
        }
        guard let directory = agent.workingDirectory else {
            return .failure(Blocked(
                title: agent.shortName,
                message: "Herdr did not report a working directory for this agent."
            ))
        }
        return .success(Resolved(
            directory: directory,
            title: (directory as NSString).lastPathComponent,
            subtitle: PanelHTML.abbreviate(directory)
        ))
    }
}

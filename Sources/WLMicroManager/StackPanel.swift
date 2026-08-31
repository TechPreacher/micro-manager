import Foundation
import WLKit

/// The GitButler stack, floating in the middle of the screen.
///
/// Pressing the stack key opens it for whichever agent has focus in Herdr;
/// pressing it again puts it away.
@MainActor
final class StackPanelController {

    static let shared = StackPanelController()

    /// Fires whenever the window appears or disappears, so the key light can
    /// follow it.
    var onVisibilityChange: ((Bool) -> Void)? {
        get { panel.onVisibilityChange }
        set { panel.onVisibilityChange = newValue }
    }

    private let panel = FloatingPanel()
    private var loadGeneration = 0

    init() {
        panel.onDismissRequested = { [weak self] in self?.close() }
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - Toggle

    func toggle() {
        if isVisible {
            close()
        } else {
            open()
        }
    }

    func open() {
        panel.present()
        // The window goes up straight away with a placeholder rather than
        // after `but status` returns: a key press that does nothing for a beat
        // reads as a key press that did not register.
        render(Payload(title: "…", subtitle: "", body: PanelHTML.note("Reading stack…")))
        loadGeneration += 1
        let generation = loadGeneration
        Task { [weak self] in
            let payload = await Self.buildPayload()
            guard let self, self.loadGeneration == generation, self.isVisible else { return }
            self.render(payload)
        }
    }

    func close() {
        panel.close()
    }

    // MARK: - Content

    private struct Payload {
        var title: String
        var subtitle: String
        /// HTML, already escaped and styled.
        var body: String
    }

    private func render(_ payload: Payload) {
        panel.render(
            title: payload.title,
            subtitle: payload.subtitle,
            body: payload.body,
            footer: "press the stack key again to dismiss"
        )
    }

    private static func buildPayload() async -> Payload {
        let repo: FocusedRepo.Resolved
        switch await FocusedRepo.resolve() {
        case .failure(let blocked):
            return Payload(
                title: blocked.title,
                subtitle: blocked.subtitle,
                body: PanelHTML.note(blocked.message)
            )
        case .success(let resolved):
            repo = resolved
        }

        do {
            let output = try await GitButler.status(in: repo.directory)
            return Payload(title: repo.title, subtitle: repo.subtitle, body: PanelHTML.output(output))
        } catch {
            return Payload(
                title: repo.title,
                subtitle: repo.subtitle,
                body: PanelHTML.note(error.localizedDescription)
            )
        }
    }
}

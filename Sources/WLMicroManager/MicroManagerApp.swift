import SwiftUI
import AppKit
import WLKit

/// Owns the bridge and its wiring for the whole process.
///
/// This cannot live in the menu content's `.task`: with
/// `.menuBarExtraStyle(.window)` the content view is built lazily, on the
/// first click — so a login-item launch would never start the bridge, and
/// the action keys would stay inert until someone happened to open the menu.
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()
    let bridge = BridgeController()

    private var started = false

    /// Wires the bridge to the window controllers and resumes it in whatever
    /// state it was left. Runs once, from `applicationDidFinishLaunching`.
    func startUp() {
        guard !started else { return }
        started = true

        // The stack and land keys open windows, which the bridge knows
        // nothing about, so the two are joined here.
        let stack = StackPanelController.shared
        stack.onVisibilityChange = { [weak bridge] open in
            Task { await bridge?.setStackPanelOpen(open) }
        }
        bridge.onStackKey = { stack.toggle() }

        let land = LandPanelController.shared
        land.onVisibilityChange = { [weak bridge] open in
            Task { await bridge?.setLandPanelOpen(open) }
        }
        bridge.onLandKey = { land.handleLandKey() }

        let voice = VoiceController.shared
        voice.onActiveChange = { [weak bridge] active in
            Task { await bridge?.setVoiceActive(active) }
        }
        voice.onError = { [weak bridge] message in
            bridge?.noteError(message)
        }
        bridge.onVoiceKey = { voice.handleVoiceKey() }

        let tune = TuneController.shared
        tune.onError = { [weak bridge] message in
            bridge?.noteError(message)
        }
        tune.bindings = { [weak bridge] in
            bridge?.keyBindings ?? KeyBindings()
        }
        bridge.onDial = { step in tune.handleDial(step) }
        bridge.onJoystick = { direction in tune.handleJoystick(direction) }
        // While a land confirmation is up, every key that is not the land key
        // means "cancel", nothing else.
        bridge.onKeyIntercept = { index in
            guard index != Pad.landKeyID else { return false }
            return land.handleOtherKey()
        }

        Task {
            // Choose the transport before starting: `useEmulator` rebuilds
            // the device, so doing it after would tear down a connection we
            // just made.
            await bridge.useEmulator(BridgeSettings.emulate)

            // Come back up in whatever state it was left in, so a login-item
            // launch resumes rather than sitting idle. Defaults to on for a
            // first run.
            if BridgeSettings.enabled, !bridge.isRunning {
                await bridge.start()
            }
        }
    }

    /// The pad must go dark before the process goes away — but quit must not
    /// hang behind a wedged lifecycle chain (a start mid-flight against an
    /// unresponsive pad holds the chain through 8-second call timeouts), so
    /// the wait is bounded: past the deadline the app quits with whatever
    /// state the pad is in, which is no worse than the old immediate exit.
    func shutDown(completion: @escaping () -> Void) {
        var replied = false
        let finish = {
            guard !replied else { return }
            replied = true
            completion()
        }
        Task {
            await bridge.stop()
            finish()
        }
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            finish()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no app-switcher entry. The bundled app
        // also sets LSUIElement; this covers `swift run` during development.
        NSApplication.shared.setActivationPolicy(.accessory)
        AppServices.shared.startUp()
    }

    /// Quit through `stop()`: without this the process just dies and the pad
    /// keeps showing the last agent colours, which reads as a stuck device
    /// rather than a quit app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppServices.shared.shutDown {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct MicroManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var bridge = AppServices.shared.bridge

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environmentObject(bridge)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: MenuBarIcon.State.from(bridge)))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Persisted across launches.
enum BridgeSettings {
    private static let key = "bridgeEnabled"

    static var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: key) == nil { return true }
            return UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private static let emulateKey = "emulatePad"

    /// Drive a virtual pad instead of the hardware. `WL_EMULATE=1` forces it on
    /// for a single run, which is what makes `swift run` useful with no device
    /// plugged in.
    static var emulate: Bool {
        get {
            if ProcessInfo.processInfo.environment["WL_EMULATE"] == "1" { return true }
            return UserDefaults.standard.bool(forKey: emulateKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: emulateKey) }
    }
}

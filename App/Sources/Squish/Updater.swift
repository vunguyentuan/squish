import AppKit
import Observation
import Sparkle

/// Sparkle updates, fed from squish.madebyvu.com/appcast.xml (written by scripts/release.sh).
@Observable
final class Updater {
    static let shared = Updater()

    private(set) var canCheck = false
    var automaticallyChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    @ObservationIgnored private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in self?.canCheck = updater.canCheckForUpdates }
        }
    }

    func check() {
        // From the menu bar item the app may be in the background, which would bury Sparkle's window.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}

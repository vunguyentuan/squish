import AppKit

/// Hides the Dock icon while no window is open (the menu bar item and drop shelf keep working),
/// and brings it back as soon as the main or Settings window appears.
final class DockIcon {
    static let shared = DockIcon()

    private var observers: [NSObjectProtocol] = []

    func startMonitoring() {
        let names = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.willCloseNotification,
        ]
        observers = names.map { name in
            // Deferred: on willClose the window is still visible.
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.update() }
            }
        }
        Task { update() }
    }

    func update() {
        // Cmd-H hides every window; keep the icon so the app can be unhidden from the Dock.
        guard !NSApp.isHidden else { return }
        // Minimized windows count, or there'd be no way to restore them.
        let hasWindow = NSApp.windows.contains { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }
        let policy: NSApplication.ActivationPolicy = Preferences.shared.hideDockIcon && !hasWindow ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Going back to .regular doesn't restore the app's menu bar until it's activated again.
        if policy == .regular { NSApp.activate() }
    }
}

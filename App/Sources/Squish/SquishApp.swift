import AppKit
import SwiftUI

@main
struct SquishApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private let store = OptimizerStore.shared
    private let prefs = Preferences.shared

    var body: some Scene {
        Window("Squish", id: "main") {
            ContentView()
                .environment(store)
                .environment(prefs)
        }
        .defaultSize(width: 560, height: 440)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Show Drop Shelf") { ShelfController.shared.show() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(store)
                .environment(prefs)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(store)
                .environment(prefs)
        } label: {
            MenuBarLabel()
                .environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ShelfController.shared.startMonitoring()
        DockIcon.shared.startMonitoring()
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Files dropped on the Dock icon, "Open With", and `squish://` links.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        for link in urls where link.scheme == "squish" {
            handle(link)
        }
        if !files.isEmpty {
            OptimizerStore.shared.add(files)
            WindowRouter.openMain()
        }
    }

    /// `squish://shelf` shows the drop shelf; `squish://open` brings up the main window.
    private func handle(_ link: URL) {
        switch link.host() {
        case "shelf": ShelfController.shared.show()
        default: WindowRouter.openMain()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { WindowRouter.openMain() }
        return true
    }
}

/// Finder → right-click → Services → "Squish Images".
final class ServiceProvider: NSObject {
    @objc func squishFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "No files to squish" as NSString
            return
        }
        OptimizerStore.shared.add(urls)
        WindowRouter.openMain()
    }
}

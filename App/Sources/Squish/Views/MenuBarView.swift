import SwiftUI

struct MenuBarContent: View {
    @Environment(OptimizerStore.self) private var store
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        if store.savedBytes > 0 {
            Text("Saved \(Fmt.bytes(store.savedBytes)) this session")
        }
        if LifetimeStats.shared.files > 0 {
            Text("Saved \(Fmt.bytes(LifetimeStats.shared.savedBytes)) all time")
        }
        if store.isWorking {
            Text("Squishing \(store.finishedCount + 1) of \(store.jobs.count)…")
        }
        Button("Open Squish") { WindowRouter.openMain() }
            .keyboardShortcut("0")
        Button("Show Drop Shelf") { ShelfController.shared.show() }
        Divider()
        Picker("Preset", selection: $prefs.preset) {
            ForEach([Preset.lossless, .balanced, .maximum]) { Label($0.title, systemImage: $0.symbol).tag($0) }
        }
        Picker("Output", selection: $prefs.output) {
            ForEach(OutputFormat.imageCases) { Text($0.title).tag($0) }
        }
        Toggle("Shake to Drop", isOn: $prefs.shakeToShelf)
            .onChange(of: prefs.shakeToShelf) { _, on in ShelfController.shared.setEnabled(on) }
        Divider()
        Button("Check for Updates…") { Updater.shared.check() }
            .disabled(!Updater.shared.canCheck)
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Squish") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The menu bar icon; it also captures `openWindow` for AppKit callers.
struct MenuBarLabel: View {
    @Environment(OptimizerStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: store.isWorking ? "rectangle.compress.vertical" : "arrow.down.right.and.arrow.up.left")
            .symbolEffect(.pulse, isActive: store.isWorking)
            .onAppear { WindowRouter.openWindow = openWindow }
    }
}

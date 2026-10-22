import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Optimization", systemImage: "slider.horizontal.3") { OptimizationSettings() }
            Tab("Formats", systemImage: "photo.on.rectangle.angled") { FormatSettings() }
            Tab("Automation", systemImage: "gearshape.2") { AutomationSettings() }
            Tab("About", systemImage: "info.circle") { AboutSettings() }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(Preferences.self) private var prefs
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section("Saving") {
                Picker("When optimizing", selection: $prefs.saveMode) {
                    ForEach(SaveMode.allCases) { Text($0.title).tag($0) }
                }
                if prefs.saveMode == .copy {
                    TextField("Copy suffix", text: $prefs.copySuffix)
                }
                if prefs.saveMode == .folder {
                    LabeledContent("Folder") {
                        HStack {
                            Text(prefs.outputFolder?.lastPathComponent ?? "Not set")
                                .foregroundStyle(prefs.outputFolder == nil ? .secondary : .primary)
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                }
                Text("\(prefs.saveMode.detail) Converted files (WebP, AVIF, JPEG) are always saved next to the original.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Shake to Drop") {
                Toggle("Shake the cursor while dragging files to open the drop shelf", isOn: $prefs.shakeToShelf)
                    .onChange(of: prefs.shakeToShelf) { _, on in ShelfController.shared.setEnabled(on) }
                Button("Show Shelf Now") { ShelfController.shared.show() }
            }
            Section("Dock") {
                Toggle("Hide the Dock icon when no windows are open", isOn: $prefs.hideDockIcon)
                    .onChange(of: prefs.hideDockIcon) { DockIcon.shared.update() }
                Text("Squish stays in the menu bar, and the drop shelf keeps working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Updates") {
                @Bindable var updater = Updater.shared
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
                Button("Check Now") { updater.check() }
                    .disabled(!updater.canCheck)
            }
            Section("Feedback") {
                Toggle("Play a sound when a batch finishes", isOn: $prefs.playSounds)
                Toggle("Launch Squish at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Use Folder")
        if panel.runModal() == .OK { prefs.outputFolder = panel.url }
    }
}

private struct OptimizationSettings: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                Picker("Preset", selection: $prefs.preset) {
                    ForEach(Preset.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                Picker("Output format", selection: $prefs.output) {
                    ForEach(OutputFormat.imageCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Quality \(prefs.quality)") {
                    Slider(value: Binding(
                        get: { Double(prefs.quality) },
                        set: { v in prefs.customize { $0.quality = Int(v.rounded()) } }
                    ), in: 30...100, step: 1)
                }
                .disabled(prefs.lossless)
                Picker("Effort", selection: Binding(get: { prefs.effort }, set: { v in prefs.customize { $0.effort = v } })) {
                    Text("Fast").tag(0)
                    Text("Balanced").tag(1)
                    Text("Maximum (Zopfli, slow)").tag(2)
                }
                Toggle("Lossless only", isOn: Binding(get: { prefs.lossless }, set: { v in prefs.customize { $0.lossless = v } }))
            }
            Section("Size") {
                ResizePicker(title: "Resize to fit")
                Text("Larger images and videos are scaled down so their longest side fits. Resizing always re-encodes, even in Lossless mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Metadata") {
                Toggle("Strip EXIF, GPS, XMP and comments", isOn: $prefs.stripMetadata)
                Toggle("Keep ICC color profiles", isOn: $prefs.keepColorProfile)
                    .disabled(!prefs.stripMetadata)
                Text("Photo orientation is always preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("How it works") {
                engineRow("PNG", "libimagequant palette quantization + oxipng (lossless Deflate search, Zopfli at Maximum)")
                engineRow("JPEG", "mozjpeg trellis re-encode, or jpegtran-style lossless transcode — whichever is smaller")
                engineRow("WebP", "libwebp at method 6 with sharp YUV")
                engineRow("AVIF", "rav1e AV1 encoder via ravif")
                engineRow("SVG", "OXVG, a Rust port of SVGO")
                engineRow("GIF", "Animated GIFs become animated WebP (libwebp) or H.264 MP4 (Apple's hardware encoder)")
                engineRow(String(localized: "Video"), "HEVC via Apple's hardware encoder (speed-tuned unless Effort is Maximum); HDR, rotation and audio are kept")
                Text("Squish never makes a file bigger: if it can't win, the original is left untouched. Videos must shrink by at least 10% to be replaced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func engineRow(_ format: String, _ detail: LocalizedStringKey) -> some View {
        LabeledContent(format) {
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

/// "Off" or a longest-edge size in pixels.
struct ResizePicker: View {
    @Environment(Preferences.self) private var prefs
    var title: LocalizedStringKey

    var body: some View {
        @Bindable var prefs = prefs
        Picker(title, selection: $prefs.maxDimension) {
            ForEach(Preferences.resizeChoices, id: \.self) { size in
                Text(size == 0 ? "Off" : "\(String(size)) px").tag(size)
            }
            if !Preferences.resizeChoices.contains(prefs.maxDimension) {
                Text("\(String(prefs.maxDimension)) px").tag(prefs.maxDimension)
            }
        }
    }
}

private struct FormatSettings: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        Form {
            Section {
                ForEach(FormatKind.allCases) { kind in
                    LabeledContent(kind.title) {
                        HStack(spacing: 8) {
                            Picker("Preset", selection: binding(kind, \.preset)) {
                                Text("Default").tag(Preset?.none)
                                Divider()
                                ForEach([Preset.lossless, .balanced, .maximum]) { Text($0.title).tag(Optional($0)) }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                            Picker("Output", selection: binding(kind, \.output)) {
                                Text("Default").tag(OutputFormat?.none)
                                Divider()
                                ForEach(kind.outputs) { Text($0.title).tag(Optional($0)) }
                            }
                            .labelsHidden()
                            .frame(width: 130)
                            .disabled(kind.outputs.count < 2)
                        }
                    }
                }
            } header: {
                Text("Per-format rules")
            } footer: {
                Text("“Default” follows the preset and output format chosen in the toolbar. For example: keep PNGs lossless, convert HEIC to JPEG, and turn animated GIFs into MP4 video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Reset All Rules") { prefs.formatRules = [:] }
                    .disabled(prefs.formatRules.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    private func binding<Value>(_ kind: FormatKind, _ field: WritableKeyPath<FormatRule, Value>) -> Binding<Value> {
        Binding(
            get: { prefs.rule(for: kind)[keyPath: field] },
            set: { value in
                var rule = prefs.rule(for: kind)
                rule[keyPath: field] = value
                prefs.setRule(rule, for: kind)
            }
        )
    }
}

private struct AutomationSettings: View {
    @Environment(Preferences.self) private var prefs
    @State private var selection: URL?
    @State private var cliInstalled = CommandLineTool.isInstalled

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(prefs.watchedFolders, id: \.self) { folder in
                        Label(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder")
                            .tag(folder)
                    }
                }
                .frame(minHeight: 80)
                .overlay {
                    if prefs.watchedFolders.isEmpty {
                        Text("No watched folders").foregroundStyle(.tertiary)
                    }
                }
                HStack {
                    Button("Add Folder…", action: addFolder)
                    Button("Watch Screenshots") { watch(FolderWatcher.screenshotsFolder) }
                        .disabled(prefs.watchedFolders.contains(FolderWatcher.screenshotsFolder.standardizedFileURL))
                    Spacer()
                    Button("Remove", role: .destructive) {
                        prefs.watchedFolders.removeAll { $0 == selection }
                        selection = nil
                    }
                    .disabled(selection == nil)
                }
            } header: {
                Text("Watched folders")
            } footer: {
                Text("New images and videos saved into these folders are optimized automatically with your current settings. Subfolders aren't watched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Clipboard") {
                Toggle("Optimize the clipboard image with \(ClipboardSquisher.shortcut)", isOn: $prefs.clipboardHotKey)
                Text("Shrinks a copied screenshot or image before you paste it. PNG stays PNG and JPEG stays JPEG, so every app can paste it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("squish") {
                    if cliInstalled {
                        Label("Installed in /usr/local/bin", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Install Command-Line Tool…", action: installCLI)
                    }
                }
                Text("Run `squish --help` in Terminal. Useful in build scripts: `squish -i -r 2560 assets/`")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("Command line")
            }
            Section("Shortcuts") {
                Text("Squish adds “Optimize Files” and “Optimize Clipboard Image” actions to the Shortcuts app, so you can use them in shortcuts, Folder Actions, Spotlight and Siri.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Shortcuts") { NSWorkspace.shared.open(URL(string: "shortcuts://")!) }
            }
        }
        .formStyle(.grouped)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Watch")
        if panel.runModal() == .OK { panel.urls.forEach(watch) }
    }

    private func watch(_ folder: URL) {
        let folder = folder.standardizedFileURL
        if !prefs.watchedFolders.contains(folder) { prefs.watchedFolders.append(folder) }
    }

    private func installCLI() {
        do {
            try CommandLineTool.install()
        } catch {
            NSAlert(error: error).runModal()
        }
        cliInstalled = CommandLineTool.isInstalled
    }
}

private struct AboutSettings: View {
    @State private var stats = LifetimeStats.shared

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
            Text("Squish").font(.title.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? Engine.version)")
                .foregroundStyle(.secondary)
            if stats.files > 0 {
                Text("Squish has saved you \(Text(Fmt.bytes(stats.savedBytes)).foregroundStyle(.green).fontWeight(.semibold)) across \(Fmt.items(stats.files)).")
                    .contextMenu {
                        Button("Reset Statistics") { stats.reset() }
                    }
            }
            Text(Engine.codecs)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Engine written in Rust. Includes libimagequant (GPL-3.0), mozjpeg (BSD/IJG), libwebp (BSD), rav1e (BSD-2), oxipng (MIT), OXVG (MIT).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

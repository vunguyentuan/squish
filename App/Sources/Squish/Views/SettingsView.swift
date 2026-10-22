import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Optimization", systemImage: "slider.horizontal.3") { OptimizationSettings() }
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
                Text(prefs.saveMode.detail + " Converted files (WebP, AVIF, JPEG) are always saved next to the original.")
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
        panel.prompt = "Use Folder"
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
                engineRow("Video", "HEVC via Apple's hardware encoder (speed-tuned unless Effort is Maximum); HDR, rotation and audio are kept")
                Text("Squish never makes a file bigger: if it can't win, the original is left untouched. Videos must shrink by at least 10% to be replaced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func engineRow(_ format: String, _ detail: String) -> some View {
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

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
            Text("Squish").font(.title.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? Engine.version)")
                .foregroundStyle(.secondary)
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

import SwiftUI

/// Compact options popover behind the toolbar's preset button.
struct PresetPopover: View {
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 14) {
            Picker("Preset", selection: $prefs.preset) {
                ForEach([Preset.lossless, .balanced, .maximum]) { Text($0.title).tag($0) }
                if prefs.preset == .custom { Text("Custom").tag(Preset.custom) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Form {
                Picker("Format:", selection: $prefs.output) {
                    ForEach(OutputFormat.imageCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Quality:") {
                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { Double(prefs.quality) },
                                set: { v in prefs.customize { $0.quality = Int(v.rounded()) } }
                            ),
                            in: 30...100,
                            step: 1
                        )
                        Text(prefs.lossless ? "—" : "\(prefs.quality)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .trailing)
                    }
                }
                .disabled(prefs.lossless)
                Picker("Effort:", selection: Binding(
                    get: { prefs.effort },
                    set: { v in prefs.customize { $0.effort = v } }
                )) {
                    Text("Fast").tag(0)
                    Text("Balanced").tag(1)
                    Text("Maximum").tag(2)
                }
                ResizePicker(title: "Resize:")
                Picker("Save:", selection: $prefs.saveMode) {
                    ForEach(SaveMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Lossless only", isOn: Binding(
                    get: { prefs.lossless },
                    set: { v in prefs.customize { $0.lossless = v } }
                ))
                Toggle("Strip metadata", isOn: $prefs.stripMetadata)
            }
            .formStyle(.columns)
            .controlSize(.small)

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Text(prefs.saveMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                SettingsLink { Text("Settings…") }
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

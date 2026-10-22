import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(OptimizerStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @Environment(\.openWindow) private var openWindow

    @State private var isTargeted = false
    @State private var showOptions = false
    @State private var showImporter = false
    @State private var comparing: ImageJob?

    var body: some View {
        Group {
            if store.isEmpty {
                DropZoneView(isTargeted: isTargeted, choose: { showImporter = true })
            } else {
                JobList(comparing: $comparing)
                    .overlay {
                        if isTargeted {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 3)
                                .padding(4)
                                .allowsHitTesting(false)
                        }
                    }
                    .safeAreaBar(edge: .bottom) { StatusBar() }
            }
        }
        .animation(.smooth(duration: 0.25), value: store.isEmpty)
        .frame(minWidth: 440, minHeight: 320)
        .navigationTitle("Squish")
        .toolbar { toolbar }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            FileDrop.load(providers) { store.add($0) }
            return true
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.image, .movie, .folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { store.add(urls) }
        }
        .sheet(item: $comparing) { job in
            CompareView(job: job)
        }
        .onAppear { WindowRouter.openWindow = openWindow }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showOptions.toggle()
            } label: {
                Label(prefs.summary, systemImage: "slider.horizontal.3")
                    .labelStyle(.titleAndIcon)
            }
            .help("Optimization options")
            .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                PresetPopover()
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Add Files", systemImage: "plus") { showImporter = true }
                .help("Add images, videos or folders")
                .keyboardShortcut("o")
            Button("Clear", systemImage: "xmark.circle") { store.clearFinished() }
                .help("Clear finished items")
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(store.finishedCount == 0)
        }
    }
}

/// Finder-style status line under the list.
private struct StatusBar: View {
    @Environment(OptimizerStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            if store.isWorking {
                ProgressView(value: store.progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 90)
                Text("Optimizing \(min(store.finishedCount + 1, store.jobs.count)) of \(store.jobs.count) · \(Fmt.percent(store.progress))")
                    .contentTransition(.numericText())
            } else {
                Text(summary)
                    .contentTransition(.numericText())
            }
            Spacer()
            if store.savedBytes > 0 {
                Text("Saved \(Text(Fmt.bytes(store.savedBytes)).foregroundStyle(.green).fontWeight(.semibold))")
                    .contentTransition(.numericText(value: Double(store.savedBytes)))
            }
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .animation(.smooth, value: store.isWorking)
        .animation(.smooth, value: store.savedBytes)
    }

    private var summary: String {
        let processed = store.processedJobs.count
        guard processed > 0 else { return Fmt.items(store.jobs.count) }
        return String(localized: "\(Fmt.items(store.jobs.count)) · \(Fmt.percent(store.savedFraction)) smaller")
    }
}

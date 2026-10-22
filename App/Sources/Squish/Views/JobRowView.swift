import QuickLook
import SwiftUI

struct JobList: View {
    @Environment(OptimizerStore.self) private var store
    @Binding var comparing: ImageJob?

    @State private var selection = Set<ImageJob.ID>()
    @State private var quickLook: URL?

    var body: some View {
        List(selection: $selection) {
            ForEach(store.jobs) { job in
                JobRow(job: job)
                    .onDrag { NSItemProvider(contentsOf: job.outputURL ?? job.sourceURL) ?? NSItemProvider() }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: ImageJob.ID.self) { ids in
            menu(for: jobs(ids))
        } primaryAction: { ids in
            let picked = jobs(ids)
            if picked.count == 1, picked[0].canCompare {
                comparing = picked[0]
            } else {
                picked.forEach { NSWorkspace.shared.open($0.outputURL ?? $0.sourceURL) }
            }
        }
        .onKeyPress(.space) {
            guard let job = jobs(selection).first else { return .ignored }
            quickLook = job.outputURL ?? job.sourceURL
            return .handled
        }
        .onDeleteCommand {
            jobs(selection).forEach(store.remove)
        }
        .quickLookPreview($quickLook, in: store.jobs.map { $0.outputURL ?? $0.sourceURL })
    }

    private func jobs(_ ids: Set<ImageJob.ID>) -> [ImageJob] {
        store.jobs.filter { ids.contains($0.id) }
    }

    @ViewBuilder
    private func menu(for jobs: [ImageJob]) -> some View {
        if !jobs.isEmpty {
            if jobs.count == 1, jobs[0].canCompare {
                Button("Compare Before & After") { comparing = jobs[0] }
            }
            Button("Quick Look") { quickLook = jobs.first.map { $0.outputURL ?? $0.sourceURL } }
            Button("Show in Finder") { store.reveal(jobs) }
            Divider()
            let restorable = jobs.filter(\.canRestore)
            if !restorable.isEmpty {
                Button(restorable.count == 1 ? "Restore Original" : "Restore \(restorable.count) Originals") {
                    restorable.forEach(store.restore)
                }
            }
            let failed = jobs.filter { if case .failed = $0.state { true } else { false } }
            if !failed.isEmpty {
                Button("Try Again") { failed.forEach(store.retry) }
            }
            let convertible = jobs.filter(\.canConvert)
            if !convertible.isEmpty {
                let outputs = OutputFormat.allCases.filter { output in
                    convertible.contains { OutputFormat.conversions(for: $0.inputFormat).contains(output) }
                }
                Menu("Convert To") {
                    ForEach(outputs) { output in
                        Button(output.title) {
                            convertible
                                .filter { OutputFormat.conversions(for: $0.inputFormat).contains(output) }
                                .forEach { store.convert($0, to: output) }
                        }
                    }
                }
            }
            Divider()
            Button("Copy Summary") { BatchReport.copySummary(jobs) }
            Button("Export Report…") { BatchReport.exportCSV(jobs) }
            Divider()
            Button("Remove from List") { jobs.forEach(store.remove) }
                .disabled(!jobs.contains { $0.state.isFinished })
        }
    }
}

struct JobRow: View {
    let job: ImageJob

    var body: some View {
        HStack(spacing: 10) {
            JobThumbnail(job: job, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(detailIsWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .help(detailText)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 3)
    }

    private var formats: String {
        if let out = job.outputFormat, out != job.inputFormat, job.state == .optimized {
            return "\(job.inputFormat.label) → \(out.label)"
        }
        return job.inputFormat.label
    }

    private var detailText: String {
        switch job.state {
        case .queued: return String(localized: "\(formats) · Waiting")
        case .working: return String(localized: "\(formats) · Optimizing…")
        case .skipped(let reason), .failed(let reason): return reason
        case .restored: return String(localized: "\(formats) · Original restored")
        case .alreadyOptimal:
            return job.inputFormat.isVideo
                ? String(localized: "\(formats) · Already efficiently encoded")
                : String(localized: "\(formats) · Already optimal")
        case .optimized:
            var parts = [formats]
            if let size = job.pixelSize { parts.append("\(Int(size.width))×\(Int(size.height))") }
            if let detail = job.detail { parts.append(detail) }
            parts.append(job.note ?? Fmt.duration(ms: job.elapsedMs))
            return parts.joined(separator: " · ")
        }
    }

    private var detailIsWarning: Bool {
        if case .failed = job.state { return true }
        return job.note != nil
    }

    @ViewBuilder
    private var trailing: some View {
        switch job.state {
        case .queued:
            size(job.originalSize)
        case .working:
            if let progress = job.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .help("\(Fmt.percent(progress)) encoded")
            } else {
                ProgressView().controlSize(.small)
            }
        case .optimized:
            VStack(alignment: .trailing, spacing: 1) {
                size(job.optimizedSize ?? job.originalSize)
                Text(job.savedFraction >= 0 ? "−\(Fmt.percent(job.savedFraction))" : "+\(Fmt.percent(-job.savedFraction))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(job.savedFraction > 0.001 ? .green : .orange)
                    .monospacedDigit()
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
        case .alreadyOptimal, .restored:
            size(job.originalSize)
        case .skipped:
            ConvertMenu(job: job)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func size(_ bytes: Int64) -> some View {
        Text(Fmt.bytes(bytes))
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(job.state == .optimized ? .primary : .secondary)
            .contentTransition(.numericText())
    }
}

/// "Convert" pull-down for rows that can't be optimized in place (HEIC, TIFF…).
struct ConvertMenu: View {
    let job: ImageJob

    @Environment(OptimizerStore.self) private var store

    var body: some View {
        Menu("Convert") {
            ForEach(OutputFormat.conversions(for: job.inputFormat)) { output in
                Button {
                    store.convert(job, to: output)
                } label: {
                    Text(output.title)
                    Text(hint(for: output))
                }
            }
        }
        .controlSize(.small)
        .fixedSize()
        .help("Convert this image to a modern format")
    }

    private func hint(for output: OutputFormat) -> LocalizedStringKey {
        switch output {
        case .webp: "Small, works everywhere"
        case .avif: "Smallest, slower to encode"
        case .jpeg: "Maximum compatibility"
        case .mp4: "Smallest for animations, plays everywhere"
        case .original: ""
        }
    }
}

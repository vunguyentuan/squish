import AppKit
import UniformTypeIdentifiers

/// Before/after numbers for a set of jobs, as CSV or a short plain-text summary.
enum BatchReport {
    static let csvHeader = [
        "File", "Path", "Status", "Input Format", "Output Format", "Width", "Height",
        "Original Bytes", "Optimized Bytes", "Saved Bytes", "Saved %", "Time ms", "Output Path",
    ]

    static func csv(_ jobs: [ImageJob]) -> String {
        let rows = jobs.map { job -> [String] in
            let optimized = job.state == .optimized ? job.optimizedSize ?? job.originalSize : job.originalSize
            return [
                job.name,
                job.sourceURL.path,
                status(job.state),
                job.inputFormat.label,
                (job.state == .optimized ? job.outputFormat : nil)?.label ?? job.inputFormat.label,
                job.pixelSize.map { String(Int($0.width)) } ?? "",
                job.pixelSize.map { String(Int($0.height)) } ?? "",
                String(job.originalSize),
                String(optimized),
                String(job.savedBytes),
                String(format: "%.1f", job.savedFraction * 100),
                String(job.elapsedMs),
                job.outputURL?.path ?? "",
            ]
        }
        return ([csvHeader] + rows).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// e.g. "Squished 12 files: 8.4 MB → 2.1 MB (75% smaller)" plus one line per file.
    static func summary(_ jobs: [ImageJob]) -> String {
        let processed = jobs.filter { $0.state == .optimized || $0.state == .alreadyOptimal }
        let original = processed.reduce(0) { $0 + $1.originalSize }
        let saved = processed.reduce(0) { $0 + $1.savedBytes }
        let fraction = original > 0 ? Double(saved) / Double(original) : 0
        var lines = [
            String(localized: "Squished \(Fmt.items(processed.count)): \(Fmt.bytes(original)) → \(Fmt.bytes(original - saved)) (\(Fmt.percent(fraction)) smaller)"),
        ]
        for job in jobs {
            switch job.state {
            case .optimized:
                lines.append("• \(job.name): \(Fmt.bytes(job.originalSize)) → \(Fmt.bytes(job.optimizedSize ?? job.originalSize)) (−\(Fmt.percent(job.savedFraction)))")
            case .alreadyOptimal:
                lines.append(String(localized: "• \(job.name): already optimal"))
            case .skipped(let reason), .failed(let reason):
                lines.append("• \(job.name): \(reason)")
            case .queued, .working, .restored:
                continue
            }
        }
        return lines.joined(separator: "\n")
    }

    static func copySummary(_ jobs: [ImageJob]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary(jobs), forType: .string)
    }

    static func exportCSV(_ jobs: [ImageJob]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = String(localized: "Squish Report \(Date.now.formatted(.iso8601.year().month().day()))") + ".csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv(jobs).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private static func status(_ state: ImageJob.State) -> String {
        switch state {
        case .queued: "queued"
        case .working: "working"
        case .optimized: "optimized"
        case .alreadyOptimal: "already optimal"
        case .skipped: "skipped"
        case .failed: "failed"
        case .restored: "restored"
        }
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

import AppKit
import Observation
import QuickLookThumbnailing
import SwiftUI

@Observable
final class OptimizerStore {
    static let shared = OptimizerStore()

    private(set) var jobs: [ImageJob] = []

    private let prefs = Preferences.shared
    /// Measured on an M4 Pro: throughput peaks around two thirds of the cores (8 of 12).
    private let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount * 2 / 3)
    private var running = 0
    /// Videos share the hardware encoder, so they run one at a time.
    private var runningVideo = false

    // MARK: Aggregates

    var isEmpty: Bool { jobs.isEmpty }
    var isWorking: Bool { jobs.contains { !$0.state.isFinished } }
    var finishedCount: Int { jobs.count { $0.state.isFinished } }
    var optimizedJobs: [ImageJob] { jobs.filter { $0.state == .optimized } }
    var totalOriginal: Int64 { processedJobs.reduce(0) { $0 + $1.originalSize } }
    /// Jobs the engine actually ran on (excludes skipped, failed and restored).
    var processedJobs: [ImageJob] { jobs.filter { $0.state == .optimized || $0.state == .alreadyOptimal } }
    var savedBytes: Int64 { jobs.reduce(0) { $0 + $1.savedBytes } }
    var savedFraction: Double {
        let original = totalOriginal
        return original > 0 ? Double(savedBytes) / Double(original) : 0
    }
    var progress: Double { jobs.isEmpty ? 0 : jobs.reduce(0) { $0 + $1.completion } / Double(jobs.count) }

    func jobs(in batch: UUID) -> [ImageJob] { jobs.filter { $0.batch == batch } }

    // MARK: Intake

    /// Queues images (folders are expanded). Returns the batch id, or nil if nothing was usable.
    @discardableResult
    func add(_ urls: [URL]) -> UUID? {
        let pending = Set(jobs.filter { !$0.state.isFinished }.map(\.sourceURL))
        let images = FileWork.collectFiles(from: urls).filter { !pending.contains($0) }
        guard !images.isEmpty else {
            NSSound.beep()
            return nil
        }
        let batch = UUID()
        let newJobs = images.map { ImageJob(url: $0, batch: batch) }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            jobs.insert(contentsOf: newJobs, at: 0)
        }
        newJobs.forEach(loadThumbnail)
        pump()
        return batch
    }

    func clearFinished() {
        withAnimation(.smooth) {
            jobs.removeAll { $0.state.isFinished }
        }
    }

    func remove(_ job: ImageJob) {
        guard job.state.isFinished else { return }
        withAnimation(.smooth) { jobs.removeAll { $0.id == job.id } }
    }

    // MARK: Actions

    func restore(_ job: ImageJob) {
        do {
            try FileWork.restore(source: job.sourceURL, output: job.outputURL, backup: job.backupURL)
            withAnimation(.smooth) {
                job.state = .restored
                job.backupURL = nil
                job.outputURL = nil
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func reveal(_ jobs: [ImageJob]) {
        let urls = jobs.compactMap { $0.outputURL ?? $0.sourceURL }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Re-runs a job (e.g. after changing settings).
    func retry(_ job: ImageJob) {
        guard job.state.isFinished, job.state != .optimized else { return }
        job.state = .queued
        job.note = nil
        pump()
    }

    /// Re-runs a finished job with a different output format.
    func convert(_ job: ImageJob, to output: OutputFormat) {
        guard job.canConvert else { return }
        withAnimation(.smooth) {
            job.outputOverride = output
            job.note = nil
            job.optimizedSize = nil
            job.state = .queued
        }
        pump()
    }

    // MARK: Engine pump

    private func pump() {
        while running < maxConcurrent,
              let job = jobs.last(where: { $0.state == .queued && !($0.inputFormat.isVideo && runningVideo) }) {
            start(job)
        }
        updateDockBadge()
    }

    private func start(_ job: ImageJob) {
        running += 1
        if job.inputFormat.isVideo { runningVideo = true }
        withAnimation(.smooth) { job.state = .working }
        var options = prefs.options(for: job.inputFormat)
        if let override = job.outputOverride { options.output = override }
        let order = WorkOrder(
            source: job.sourceURL,
            inputFormat: job.inputFormat,
            options: options,
            saveMode: prefs.saveMode,
            copySuffix: prefs.copySuffix,
            folder: prefs.outputFolder
        )
        let progress: @Sendable (Double) -> Void = { value in
            Task { @MainActor in if job.state == .working { job.progress = value } }
        }
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { await FileWork.run(order, progress: progress) }.value
            finish(job, with: outcome)
        }
    }

    private func finish(_ job: ImageJob, with outcome: WorkOutcome) {
        running -= 1
        if job.inputFormat.isVideo { runningVideo = false }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
            job.outputFormat = outcome.outputFormat
            job.optimizedSize = outcome.optimizedSize
            job.pixelSize = outcome.pixelSize ?? job.pixelSize
            job.elapsedMs = outcome.elapsedMs
            job.outputURL = outcome.outputURL
            job.backupURL = outcome.backupURL
            job.note = outcome.note
            job.detail = outcome.detail
            job.progress = nil
            job.state = switch outcome.kind {
            case .optimized: .optimized
            case .alreadyOptimal: .alreadyOptimal
            case .skipped(let reason): .skipped(reason)
            case .failed(let message): .failed(message)
            }
        }
        if job.state == .optimized, let output = job.outputURL, output != job.sourceURL {
            loadThumbnail(job)
        }
        pump()
        announceIfBatchDone(job.batch)
    }

    private func announceIfBatchDone(_ batch: UUID) {
        let batchJobs = jobs(in: batch)
        guard !batchJobs.isEmpty, batchJobs.allSatisfy(\.state.isFinished) else { return }
        if batchJobs.contains(where: { $0.state == .optimized }), prefs.playSounds {
            NSSound(named: "Glass")?.play()
        }
        if !isWorking, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    private func updateDockBadge() {
        let remaining = jobs.count { !$0.state.isFinished }
        NSApp.dockTile.badgeLabel = remaining > 0 ? "\(remaining)" : nil
    }

    private func loadThumbnail(_ job: ImageJob) {
        let url = job.outputURL ?? job.sourceURL
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 96, height: 96),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let image = rep?.cgImage else { return }
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.25)) {
                    job.thumbnail = NSImage(cgImage: image, size: .zero)
                }
            }
        }
    }
}

enum Haptics {
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

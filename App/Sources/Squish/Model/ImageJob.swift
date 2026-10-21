import AppKit
import Observation

@Observable
final class ImageJob: Identifiable {
    enum State: Equatable {
        case queued
        case working
        case optimized
        case alreadyOptimal
        case skipped(String)
        case failed(String)
        case restored

        var isFinished: Bool { self != .queued && self != .working }
    }

    let id = UUID()
    let sourceURL: URL
    let batch: UUID
    let inputFormat: ImageFormat
    let originalSize: Int64

    var state: State = .queued
    var outputFormat: ImageFormat?
    var optimizedSize: Int64?
    var pixelSize: CGSize?
    var elapsedMs = 0
    /// Where the optimized file lives (the source path itself in replace mode).
    var outputURL: URL?
    /// The original, moved to the Trash in replace mode.
    var backupURL: URL?
    var note: String?
    /// Neutral extra info, e.g. "H.264 → HEVC · 1:23" for videos.
    var detail: String?
    /// 0…1 while a video is encoding.
    var progress: Double?
    var thumbnail: NSImage?
    /// Set by "Convert to…" on a single row; overrides the global output format.
    var outputOverride: OutputFormat?

    init(url: URL, batch: UUID) {
        sourceURL = url
        self.batch = batch
        inputFormat = Engine.detectFormat(of: url)
        originalSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    var name: String { sourceURL.lastPathComponent }

    /// 0…1 share of this job that's done; videos report partial progress while encoding.
    var completion: Double { state.isFinished ? 1 : progress ?? 0 }

    var savedBytes: Int64 {
        guard state == .optimized, let optimizedSize else { return 0 }
        return originalSize - optimizedSize
    }

    /// 0...1, negative when a conversion grew the file.
    var savedFraction: Double {
        guard state == .optimized, let optimizedSize, originalSize > 0 else { return 0 }
        return 1 - Double(optimizedSize) / Double(originalSize)
    }

    /// The best file to show as "before" in the comparison view.
    var beforeURL: URL? {
        if let backupURL { return backupURL }
        return outputURL == sourceURL ? nil : sourceURL
    }

    var canCompare: Bool { state == .optimized && !inputFormat.isVideo && beforeURL != nil && outputURL != nil }
    var canRestore: Bool { state == .optimized && (backupURL != nil || outputURL != sourceURL) }

    /// Finished without producing a file, so converting it is a sensible next step.
    var canConvert: Bool {
        switch state {
        case .skipped, .alreadyOptimal, .failed, .restored: inputFormat != .svg && inputFormat != .unknown && !inputFormat.isVideo
        default: false
        }
    }
}

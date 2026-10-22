import Foundation

/// Everything one optimization needs, captured on the main actor.
nonisolated struct WorkOrder: Sendable {
    var source: URL
    var inputFormat: ImageFormat
    var options: OptimizeOptions
    var saveMode: SaveMode
    var copySuffix: String
    var folder: URL?
}

nonisolated struct WorkOutcome: Sendable {
    enum Kind: Sendable, Equatable {
        case optimized, alreadyOptimal
        case skipped(String)
        case failed(String)
    }

    var kind: Kind
    var outputFormat: ImageFormat?
    var optimizedSize: Int64?
    var pixelSize: CGSize?
    var elapsedMs = 0
    var outputURL: URL?
    var backupURL: URL?
    var note: String?
    var detail: String?
}

/// File-system choreography around the encoders: temp files, Trash backups, unique names.
nonisolated enum FileWork {
    /// A re-encoded video must be at least this much smaller to be worth the generation loss.
    static let videoMinimumSaving = 0.1

    static func run(_ order: WorkOrder, progress: @escaping @Sendable (Double) -> Void) async -> WorkOutcome {
        if order.inputFormat.isVideo {
            return await runVideo(order, progress: progress)
        }
        if order.inputFormat == .gif && order.options.output == .mp4 {
            return await runGIFVideo(order, progress: progress)
        }

        let fm = FileManager.default
        let source = order.source
        let target = order.options.output.format ?? order.inputFormat
        let converting = target != order.inputFormat

        if !converting && !order.inputFormat.isOptimizable {
            let reason = switch order.inputFormat {
            case .heic, .avif: "\(order.inputFormat.label) is already compact. Pick an output format to convert it."
            case .unknown: "Not a file Squish understands."
            case .gif: String(localized: "GIF can't be optimized in place. Convert it to WebP or MP4.")
            default: "\(order.inputFormat.label) can't be optimized in place. Pick an output format to convert it."
            }
            return WorkOutcome(kind: .skipped(reason))
        }

        var scratch: [URL] = []
        defer { scratch.forEach { try? fm.removeItem(at: $0) } }

        // ImageIO decodes what the engine can't (HEIC, AVIF); the engine gets a lossless PNG.
        var engineInput = source
        if order.inputFormat.needsSystemDecode {
            let png = fm.temporaryDirectory.appending(path: "squish-\(UUID().uuidString).png")
            scratch.append(png)
            do {
                _ = try Engine.decodeWithImageIO(source, to: png)
            } catch {
                return WorkOutcome(kind: .failed("macOS couldn't decode this \(order.inputFormat.label)."))
            }
            engineInput = png
        }

        let place = placement(for: order, ext: converting ? target.fileExtension : source.pathExtension, converting: converting)
        if place.replacing { scratch.append(place.destination) }

        let result = Engine.optimize(input: engineInput, output: place.destination, options: order.options)
        var outcome = WorkOutcome(
            kind: .alreadyOptimal,
            outputFormat: result.outputFormat == .unknown ? target : result.outputFormat,
            optimizedSize: result.optimizedSize,
            pixelSize: result.pixelSize,
            elapsedMs: result.elapsedMs,
            note: result.note
        )

        switch result.status {
        case .failed(let message):
            outcome.kind = .failed(message)
            return outcome
        case .alreadyOptimal:
            return outcome
        case .optimized:
            commit(place, source: source, into: &outcome)
            return outcome
        }
    }

    /// Videos are re-encoded to HEVC in their own container (MOV stays MOV, MP4 stays MP4).
    private static func runVideo(_ order: WorkOrder, progress: @escaping @Sendable (Double) -> Void) async -> WorkOutcome {
        guard !order.options.lossless else {
            return WorkOutcome(kind: .skipped("Videos can't be shrunk losslessly. Choose Balanced or Smallest."))
        }
        let fm = FileManager.default
        let source = order.source
        let place = placement(for: order, ext: source.pathExtension, converting: false)
        defer { if place.replacing { try? fm.removeItem(at: place.destination) } }

        let clock = ContinuousClock()
        let started = clock.now
        var outcome = WorkOutcome(kind: .alreadyOptimal, outputFormat: order.inputFormat)
        do {
            let result = try await VideoWork.transcode(
                source,
                to: place.destination,
                quality: VideoWork.quality(order.options.quality),
                maxDimension: order.options.maxDimension,
                prioritizeSpeed: order.options.effort < 2,
                keepMetadata: !order.options.stripMetadata,
                progress: progress
            )
            outcome.pixelSize = result.pixelSize
            outcome.detail = result.detail
        } catch VideoWork.Failure.alreadySquished {
            outcome.detail = "Optimized by Squish before"
            return outcome
        } catch {
            try? fm.removeItem(at: place.destination)
            outcome.kind = .failed(error.localizedDescription)
            return outcome
        }
        outcome.elapsedMs = Int((clock.now - started) / .milliseconds(1))

        let originalSize = fileSize(source)
        let newSize = fileSize(place.destination)
        guard newSize > 0, Double(newSize) < Double(originalSize) * (1 - videoMinimumSaving) else {
            // Not worth a lossy generation: keep the original untouched.
            try? fm.removeItem(at: place.destination)
            return outcome
        }
        outcome.optimizedSize = newSize
        commit(place, source: source, into: &outcome)
        return outcome
    }

    /// Animated GIF → H.264 MP4 next to the original (or in the output folder).
    private static func runGIFVideo(_ order: WorkOrder, progress: @escaping @Sendable (Double) -> Void) async -> WorkOutcome {
        let place = placement(for: order, ext: ImageFormat.mp4.fileExtension, converting: true)
        let clock = ContinuousClock()
        let started = clock.now
        var outcome = WorkOutcome(kind: .alreadyOptimal, outputFormat: .mp4)
        do {
            // MP4 has no lossless mode; "Lossless" gets the top of the quality range instead.
            let quality = order.options.lossless ? 0.9 : VideoWork.quality(order.options.quality)
            let result = try await GIFVideo.convert(
                order.source,
                to: place.destination,
                quality: quality,
                maxDimension: order.options.maxDimension,
                progress: progress
            )
            outcome.pixelSize = result.pixelSize
            outcome.detail = result.detail
        } catch {
            try? FileManager.default.removeItem(at: place.destination)
            outcome.kind = .failed(error.localizedDescription)
            return outcome
        }
        outcome.elapsedMs = Int((clock.now - started) / .milliseconds(1))
        outcome.optimizedSize = fileSize(place.destination)
        if outcome.optimizedSize ?? 0 >= fileSize(order.source) {
            outcome.note = String(localized: "Converted file is larger than the original")
        }
        commit(place, source: order.source, into: &outcome)
        return outcome
    }

    private struct Placement {
        var destination: URL
        /// The result will replace the source in place (written to a hidden temp file first).
        var replacing: Bool
    }

    private static func placement(for order: WorkOrder, ext: String, converting: Bool) -> Placement {
        let source = order.source
        let directory = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        if !converting && order.saveMode == .replace {
            return Placement(destination: directory.appending(path: ".\(stem).squish-\(UUID().uuidString.prefix(8)).\(ext)"), replacing: true)
        }
        if order.saveMode == .folder, let folder = order.folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return Placement(destination: uniqueURL(in: folder, stem: stem, ext: ext), replacing: false)
        }
        let suffix = converting ? "" : order.copySuffix
        return Placement(destination: uniqueURL(in: directory, stem: stem + suffix, ext: ext), replacing: false)
    }

    /// Moves a finished file into place, backing up the original when replacing.
    private static func commit(_ place: Placement, source: URL, into outcome: inout WorkOutcome) {
        if place.replacing {
            do {
                outcome.backupURL = try backUpOriginal(source)
                // replaceItemAt keeps the original's creation date, permissions and Finder tags.
                _ = try FileManager.default.replaceItemAt(source, withItemAt: place.destination)
                outcome.outputURL = source
            } catch {
                outcome = WorkOutcome(kind: .failed("Couldn't replace the original: \(error.localizedDescription)"))
                return
            }
        } else {
            outcome.outputURL = place.destination
        }
        outcome.kind = .optimized
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Clones the original (free on APFS) and moves the clone to the Trash.
    private static func backUpOriginal(_ url: URL) throws -> URL {
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        let clone = staging.appending(path: url.lastPathComponent)
        try fm.copyItem(at: url, to: clone)
        do {
            var trashed: NSURL?
            try fm.trashItem(at: clone, resultingItemURL: &trashed)
            try? fm.removeItem(at: staging)
            if let trashed = trashed as URL? { return trashed }
        } catch {
            // Volumes without a Trash: keep the backup in Application Support instead.
        }
        let backups = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Squish/Backups/\(UUID().uuidString)")
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let kept = backups.appending(path: url.lastPathComponent)
        if fm.fileExists(atPath: clone.path) {
            try fm.moveItem(at: clone, to: kept)
        } else {
            try fm.copyItem(at: url, to: kept)
        }
        try? fm.removeItem(at: staging)
        return kept
    }

    /// Puts the original back (replace mode) or removes the optimized copy.
    static func restore(source: URL, output: URL?, backup: URL?) throws {
        let fm = FileManager.default
        if let backup {
            _ = try fm.replaceItemAt(source, withItemAt: backup)
        } else if let output, output != source {
            try fm.trashItem(at: output, resultingItemURL: nil)
        }
    }

    static func uniqueURL(in directory: URL, stem: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appending(path: "\(stem).\(ext)")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(stem) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Expands folders recursively and keeps only images and videos the app accepts.
    static func collectFiles(from urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let walker = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let file = walker?.nextObject() as? URL {
                    if isAccepted(file) { found.append(file) }
                }
            } else if isAccepted(url) {
                found.append(url)
            }
        }
        return found
    }

    private static func isAccepted(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return !name.hasPrefix(".") && !name.contains(".squish-")
            && ImageFormat.acceptedExtensions.contains(url.pathExtension.lowercased())
    }
}

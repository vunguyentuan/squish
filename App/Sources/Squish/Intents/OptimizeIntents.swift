import AppIntents
import Foundation

/// Shortcuts, Spotlight and Siri actions. They run inside the app, sharing its queue and settings.

enum IntentPreset: String, AppEnum {
    case current, lossless, balanced, smallest

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Preset"
    static let caseDisplayRepresentations: [IntentPreset: DisplayRepresentation] = [
        .current: "Current Settings",
        .lossless: "Lossless",
        .balanced: "Balanced",
        .smallest: "Smallest",
    ]

    var preset: Preset? {
        switch self {
        case .current: nil
        case .lossless: .lossless
        case .balanced: .balanced
        case .smallest: .maximum
        }
    }
}

enum IntentFormat: String, AppEnum {
    case current, keep, webp, avif, jpeg, mp4

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Output Format"
    static let caseDisplayRepresentations: [IntentFormat: DisplayRepresentation] = [
        .current: "Current Settings",
        .keep: "Keep Format",
        .webp: "WebP",
        .avif: "AVIF",
        .jpeg: "JPEG",
        .mp4: "MP4 Video (animated GIFs)",
    ]

    var output: OutputFormat? {
        switch self {
        case .current: nil
        case .keep: .original
        case .webp: .webp
        case .avif: .avif
        case .jpeg: .jpeg
        case .mp4: .mp4
        }
    }
}

struct OptimizeFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Optimize Files"
    static let description = IntentDescription(
        "Shrinks images and videos with Squish and returns the optimized files.",
        categoryName: "Optimize"
    )

    @Parameter(title: "Files", supportedContentTypes: [.image, .movie])
    var files: [IntentFile]

    @Parameter(title: "Preset", default: .current)
    var preset: IntentPreset

    @Parameter(title: "Output Format", default: .current)
    var format: IntentFormat

    @Parameter(title: "Resize To Fit (px)", description: "Longest side in pixels. Leave empty to use Squish's setting, or 0 to keep the size.")
    var maxDimension: Int?

    @Parameter(title: "Save", default: .copy)
    var saveMode: IntentSaveMode

    static var parameterSummary: some ParameterSummary {
        Summary("Optimize \(\.$files) with \(\.$preset)") {
            \.$format
            \.$maxDimension
            \.$saveMode
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let urls = files.compactMap(\.fileURL)
        guard !urls.isEmpty else {
            throw $files.needsValueError("Choose files on disk to optimize.")
        }
        let override = JobOverride(preset: preset.preset, output: format.output, maxDimension: maxDimension, saveMode: saveMode.mode)
        let jobs = await OptimizerStore.shared.optimize(urls, override: override)
        let results = jobs.map { job in
            let url = job.outputURL ?? job.sourceURL
            return IntentFile(fileURL: url, filename: url.lastPathComponent)
        }
        return .result(value: results)
    }
}

enum IntentSaveMode: String, AppEnum {
    case copy, replace, settings

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Save Mode"
    static let caseDisplayRepresentations: [IntentSaveMode: DisplayRepresentation] = [
        .copy: "Save Copies Alongside",
        .replace: "Replace Originals (Trash Backup)",
        .settings: "As in Settings",
    ]

    var mode: SaveMode? {
        switch self {
        case .copy: .copy
        case .replace: .replace
        case .settings: nil
        }
    }
}

struct OptimizeClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Optimize Clipboard Image"
    static let description = IntentDescription(
        "Shrinks the image on the clipboard in place, keeping it PNG or JPEG so it pastes anywhere.",
        categoryName: "Optimize"
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        ClipboardSquisher.shared.squish()
        return .result()
    }
}

struct SquishShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OptimizeClipboardIntent(),
            phrases: ["Optimize clipboard image with \(.applicationName)", "\(.applicationName) the clipboard"],
            shortTitle: "Optimize Clipboard",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: OptimizeFilesIntent(),
            phrases: ["Optimize files with \(.applicationName)"],
            shortTitle: "Optimize Files",
            systemImageName: "arrow.down.right.and.arrow.up.left"
        )
    }
}

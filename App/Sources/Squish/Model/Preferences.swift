import Foundation
import Observation

enum Preset: String, CaseIterable, Identifiable, Codable {
    case lossless, balanced, maximum, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lossless: "Lossless"
        case .balanced: "Balanced"
        case .maximum: "Smallest"
        case .custom: "Custom"
        }
    }

    var subtitle: String {
        switch self {
        case .lossless: "Pixel-perfect"
        case .balanced: "Invisible loss"
        case .maximum: "Max savings"
        case .custom: "Your settings"
        }
    }

    var symbol: String {
        switch self {
        case .lossless: "checkmark.seal.fill"
        case .balanced: "sparkles"
        case .maximum: "flame.fill"
        case .custom: "slider.horizontal.3"
        }
    }

    /// (quality, effort, lossless)
    var values: (Int, Int, Bool)? {
        switch self {
        case .lossless: (100, 1, true)
        case .balanced: (80, 1, false)
        case .maximum: (65, 2, false)
        case .custom: nil
        }
    }
}

enum SaveMode: String, CaseIterable, Identifiable {
    case replace, copy, folder

    var id: String { rawValue }
    var title: String {
        switch self {
        case .replace: "Replace originals"
        case .copy: "Save copies alongside"
        case .folder: "Save to folder"
        }
    }
    var detail: String {
        switch self {
        case .replace: "Originals go to the Trash, so you can always restore them."
        case .copy: "Adds a suffix and keeps the original untouched."
        case .folder: "Writes optimized files into one folder."
        }
    }
}

/// Source formats that can override the global preset and output format.
enum FormatKind: String, CaseIterable, Identifiable, Codable, CodingKeyRepresentable {
    case png, jpeg, webp, gif, heic, raster, video

    var id: String { rawValue }

    init?(_ format: ImageFormat) {
        switch format {
        case .png: self = .png
        case .jpeg: self = .jpeg
        case .webp: self = .webp
        case .gif: self = .gif
        case .heic, .avif: self = .heic
        case .tiff, .bmp: self = .raster
        case .mov, .mp4: self = .video
        case .svg, .unknown: return nil
        }
    }

    var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .webp: "WebP"
        case .gif: "GIF"
        case .heic: String(localized: "HEIC & AVIF")
        case .raster: String(localized: "TIFF & BMP")
        case .video: String(localized: "Video")
        }
    }

    /// Output choices that make sense for this source.
    var outputs: [OutputFormat] {
        switch self {
        case .png, .jpeg, .heic, .raster: [.original, .webp, .avif, .jpeg]
        case .webp: [.original, .avif, .jpeg]
        case .gif: [.original, .webp, .mp4]
        case .video: [.original]
        }
    }
}

/// A per-format override; nil fields follow the global settings.
struct FormatRule: Codable, Equatable {
    var preset: Preset?
    var output: OutputFormat?

    var isEmpty: Bool { preset == nil && output == nil }
}

/// User settings, persisted to UserDefaults.
@Observable
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    var preset: Preset { didSet { save(preset.rawValue, "preset"); apply(preset) } }
    var quality: Int { didSet { save(quality, "quality") } }
    var effort: Int { didSet { save(effort, "effort") } }
    var lossless: Bool { didSet { save(lossless, "lossless") } }
    var stripMetadata: Bool { didSet { save(stripMetadata, "stripMetadata") } }
    var keepColorProfile: Bool { didSet { save(keepColorProfile, "keepColorProfile") } }
    var output: OutputFormat { didSet { save(output.rawValue, "output") } }
    var saveMode: SaveMode { didSet { save(saveMode.rawValue, "saveMode") } }
    var copySuffix: String { didSet { save(copySuffix, "copySuffix") } }
    var outputFolder: URL? { didSet { save(outputFolder?.path, "outputFolder") } }
    var shakeToShelf: Bool { didSet { save(shakeToShelf, "shakeToShelf") } }
    var playSounds: Bool { didSet { save(playSounds, "playSounds") } }
    var hideDockIcon: Bool { didSet { save(hideDockIcon, "hideDockIcon") } }
    /// Longest edge in pixels; 0 keeps the original size.
    var maxDimension: Int { didSet { save(maxDimension, "maxDimension") } }
    var formatRules: [FormatKind: FormatRule] {
        didSet { save(try? JSONEncoder().encode(formatRules.filter { !$0.value.isEmpty }), "formatRules") }
    }
    var watchedFolders: [URL] {
        didSet { save(watchedFolders.map(\.path), "watchedFolders"); FolderWatcher.shared.update() }
    }

    static let resizeChoices = [0, 3840, 2560, 1920, 1600, 1280, 1024, 800]

    private init() {
        defaults.register(defaults: [
            "preset": Preset.balanced.rawValue,
            "quality": 80,
            "effort": 1,
            "lossless": false,
            "stripMetadata": true,
            "keepColorProfile": true,
            "output": OutputFormat.original.rawValue,
            "saveMode": SaveMode.replace.rawValue,
            "copySuffix": "-squished",
            "shakeToShelf": true,
            "playSounds": false,
            "hideDockIcon": true,
            "maxDimension": 0,
        ])
        preset = Preset(rawValue: defaults.string(forKey: "preset") ?? "") ?? .balanced
        quality = defaults.integer(forKey: "quality")
        effort = defaults.integer(forKey: "effort")
        lossless = defaults.bool(forKey: "lossless")
        stripMetadata = defaults.bool(forKey: "stripMetadata")
        keepColorProfile = defaults.bool(forKey: "keepColorProfile")
        output = OutputFormat(rawValue: defaults.string(forKey: "output") ?? "") ?? .original
        saveMode = SaveMode(rawValue: defaults.string(forKey: "saveMode") ?? "") ?? .replace
        copySuffix = defaults.string(forKey: "copySuffix") ?? "-squished"
        outputFolder = defaults.string(forKey: "outputFolder").map { URL(fileURLWithPath: $0) }
        shakeToShelf = defaults.bool(forKey: "shakeToShelf")
        playSounds = defaults.bool(forKey: "playSounds")
        hideDockIcon = defaults.bool(forKey: "hideDockIcon")
        maxDimension = defaults.integer(forKey: "maxDimension")
        formatRules = defaults.data(forKey: "formatRules")
            .flatMap { try? JSONDecoder().decode([FormatKind: FormatRule].self, from: $0) } ?? [:]
        watchedFolders = (defaults.stringArray(forKey: "watchedFolders") ?? []).map { URL(fileURLWithPath: $0) }
    }

    var options: OptimizeOptions {
        OptimizeOptions(
            quality: quality,
            lossless: lossless,
            stripMetadata: stripMetadata,
            keepColorProfile: keepColorProfile,
            effort: effort,
            output: output,
            maxDimension: maxDimension
        )
    }

    /// The global options with any per-format rule applied.
    func options(for format: ImageFormat) -> OptimizeOptions {
        var resolved = options
        guard let kind = FormatKind(format), let rule = formatRules[kind] else { return resolved }
        if let (q, e, l) = rule.preset?.values {
            (resolved.quality, resolved.effort, resolved.lossless) = (q, e, l)
        }
        if let output = rule.output { resolved.output = output }
        return resolved
    }

    func rule(for kind: FormatKind) -> FormatRule { formatRules[kind] ?? FormatRule() }

    func setRule(_ rule: FormatRule, for kind: FormatKind) {
        formatRules[kind] = rule.isEmpty ? nil : rule
    }

    /// One-line description, e.g. "Balanced · WebP · 2560 px".
    var summary: String {
        var parts = [preset.title]
        if output != .original { parts.append(output.title) }
        if maxDimension > 0 { parts.append(String(localized: "\(String(maxDimension)) px")) }
        return parts.joined(separator: " · ")
    }

    /// Marks the preset as custom after a manual tweak.
    func customize(_ change: (Preferences) -> Void) {
        change(self)
        if preset != .custom, let (q, e, l) = preset.values, (q, e, l) != (quality, effort, lossless) {
            preset = .custom
        }
    }

    private func apply(_ preset: Preset) {
        guard let (q, e, l) = preset.values else { return }
        if quality != q { quality = q }
        if effort != e { effort = e }
        if lossless != l { lossless = l }
    }

    private func save(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
    }
}

import Foundation
import Observation

enum Preset: String, CaseIterable, Identifiable {
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

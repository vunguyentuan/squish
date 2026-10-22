import CSquishCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Mirrors `SquishFormat` in squish_core.h; video containers (handled by AVFoundation) start at 100.
nonisolated enum ImageFormat: UInt8, Sendable, CaseIterable {
    case unknown = 0, png, jpeg, webp, avif, svg, gif, tiff, bmp, heic
    case mov = 100, mp4

    var label: String {
        switch self {
        case .unknown: "?"
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .webp: "WebP"
        case .avif: "AVIF"
        case .svg: "SVG"
        case .gif: "GIF"
        case .tiff: "TIFF"
        case .bmp: "BMP"
        case .heic: "HEIC"
        case .mov: "MOV"
        case .mp4: "MP4"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .unknown: "bin"
        default: label.lowercased()
        }
    }

    /// Formats the engine can shrink without changing format.
    var isOptimizable: Bool { [.png, .jpeg, .webp, .svg].contains(self) }

    /// Formats only macOS can decode; the app hands the engine a PNG instead.
    var needsSystemDecode: Bool { [.heic, .avif].contains(self) }

    var isVideo: Bool { self == .mov || self == .mp4 }

    static let acceptedExtensions = Set([
        "png", "jpg", "jpeg", "jpe", "webp", "svg", "gif", "tif", "tiff", "bmp", "heic", "heif", "avif",
    ]).union(VideoWork.extensions)
}

nonisolated enum OutputFormat: String, Sendable, CaseIterable, Identifiable {
    case original, webp, avif, jpeg
    /// Animated GIF → H.264 video, made by the app rather than the engine.
    case mp4

    /// Choices for the global output pickers; MP4 only applies to GIFs.
    static let imageCases: [OutputFormat] = [.original, .webp, .avif, .jpeg]

    /// What a finished image of this format can be converted to.
    static func conversions(for format: ImageFormat) -> [OutputFormat] {
        let images: [OutputFormat] = [.webp, .avif, .jpeg]
        return format == .gif ? [.webp, .mp4] : images.filter { $0.format != format }
    }

    var id: String { rawValue }
    var format: ImageFormat? {
        switch self {
        case .original: nil
        case .webp: .webp
        case .avif: .avif
        case .jpeg: .jpeg
        case .mp4: .mp4
        }
    }
    var title: String {
        switch self {
        case .original: "Keep Format"
        case .webp: "WebP"
        case .avif: "AVIF"
        case .jpeg: "JPEG"
        case .mp4: String(localized: "MP4 Video")
        }
    }
}

nonisolated struct OptimizeOptions: Sendable, Equatable {
    var quality = 80
    var lossless = false
    var stripMetadata = true
    var keepColorProfile = true
    /// 0 fast, 1 balanced, 2 maximum.
    var effort = 1
    var output = OutputFormat.original
    /// Longest edge in pixels; 0 keeps the size.
    var maxDimension = 0
}

nonisolated struct EngineResult: Sendable {
    enum Status: Sendable, Equatable {
        case optimized
        case alreadyOptimal
        case failed(String)
    }

    var status: Status
    var inputFormat: ImageFormat
    var outputFormat: ImageFormat
    var pixelSize: CGSize?
    var originalSize: Int64
    var optimizedSize: Int64
    var elapsedMs: Int
    var note: String?
}

/// Swift face of the Rust engine. Every call blocks, so run it off the main actor.
nonisolated enum Engine {
    static let codecs = String(cString: squish_engine_info())
    static let version = String(cString: squish_version())

    static func detectFormat(of url: URL) -> ImageFormat {
        let raw = url.withUnsafeFileSystemRepresentation { path in path.map { squish_detect_format($0) } ?? 0 }
        let sniffed = ImageFormat(rawValue: raw) ?? .unknown
        if sniffed != .unknown { return sniffed }
        return switch url.pathExtension.lowercased() {
        case "heic", "heif": .heic
        case "avif": .avif
        case "mov", "qt": .mov
        case "mp4", "m4v": .mp4
        default: .unknown
        }
    }

    static func optimize(input: URL, output: URL, options: OptimizeOptions) -> EngineResult {
        var opts = SquishOptions(
            quality: UInt8(clamping: options.quality),
            lossless: options.lossless,
            strip_metadata: options.stripMetadata,
            keep_color_profile: options.keepColorProfile,
            effort: UInt8(clamping: options.effort),
            output_format: options.output == .mp4 ? 0 : options.output.format?.rawValue ?? 0,
            max_dimension: UInt32(clamping: options.maxDimension)
        )
        var raw = input.withUnsafeFileSystemRepresentation { inPath in
            output.withUnsafeFileSystemRepresentation { outPath in
                squish_optimize_file(inPath, outPath, &opts)
            }
        }
        defer { squish_result_free(&raw) }

        let message = raw.message.map { String(cString: $0) }
        let status: EngineResult.Status = switch raw.status {
        case SQUISH_OK: .optimized
        case SQUISH_ALREADY_OPTIMAL: .alreadyOptimal
        default: .failed(message ?? "Something went wrong")
        }
        return EngineResult(
            status: status,
            inputFormat: ImageFormat(rawValue: raw.input_format) ?? .unknown,
            outputFormat: ImageFormat(rawValue: raw.output_format) ?? .unknown,
            pixelSize: raw.width > 0 ? CGSize(width: Int(raw.width), height: Int(raw.height)) : nil,
            originalSize: Int64(raw.original_size),
            optimizedSize: Int64(raw.optimized_size),
            elapsedMs: Int(raw.elapsed_ms),
            note: raw.status == SQUISH_OK ? message : nil
        )
    }

    /// Decodes HEIC/AVIF (or anything ImageIO reads) into an upright, lossless PNG.
    static func decodeWithImageIO(_ url: URL, to destination: URL) throws -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let dest = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileReadCorruptFile) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return CGSize(width: image.width, height: image.height)
    }
}

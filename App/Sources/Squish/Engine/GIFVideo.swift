import AVFoundation
import CoreGraphics
import ImageIO

/// Turns animated GIFs into H.264 MP4, the format browsers and chat apps play everywhere.
///
/// ImageIO hands back fully composited frames with their delays; each one is drawn onto an
/// opaque, even-sized canvas (H.264 needs even dimensions and has no alpha) and appended
/// with its own timestamp, so the variable frame timing of the GIF survives.
nonisolated enum GIFVideo {
    struct Result: Sendable {
        var pixelSize: CGSize
        /// e.g. "48 frames · 0:03"
        var detail: String
    }

    enum Failure: LocalizedError {
        case notAnimated
        case unreadable
        case writing(Error?)

        var errorDescription: String? {
            switch self {
            case .notAnimated: String(localized: "This GIF isn't animated. Convert it to WebP instead.")
            case .unreadable: String(localized: "macOS couldn't read this GIF.")
            case .writing(let error):
                error.map { String(localized: "Couldn't write the video: \($0.localizedDescription)") } ?? String(localized: "Couldn't write the video.")
            }
        }
    }

    static func convert(
        _ source: URL,
        to destination: URL,
        quality: Double,
        maxDimension: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Result {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil) else { throw Failure.unreadable }
        let count = CGImageSourceGetCount(image)
        guard count > 1 else { throw Failure.notAnimated }
        guard let first = CGImageSourceCreateImageAtIndex(image, 0, nil) else { throw Failure.unreadable }

        let size = canvasSize(width: first.width, height: first.height, maxDimension: maxDimension)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        } catch {
            throw Failure.writing(error)
        }
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: quality,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
        ])
        guard writer.canAdd(input) else { throw Failure.writing(nil) }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writing(writer.error) }
        writer.startSession(atSourceTime: .zero)

        var time = CMTime.zero
        for index in 0..<count {
            guard let frame = index == 0 ? first : CGImageSourceCreateImageAtIndex(image, index, nil),
                  let pool = adaptor.pixelBufferPool,
                  let buffer = render(frame, into: pool, size: size)
            else { continue }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard adaptor.append(buffer, withPresentationTime: time) else {
                writer.cancelWriting()
                throw Failure.writing(writer.error)
            }
            time = time + CMTime(value: delayMs(image, at: index), timescale: 1000)
            progress(Double(index + 1) / Double(count))
        }
        input.markAsFinished()
        // Ending the session at the GIF's total length keeps the last frame on screen for its delay.
        writer.endSession(atSourceTime: time)
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.writing(writer.error) }

        let seconds = Int(time.seconds.rounded())
        return Result(
            pixelSize: CGSize(width: size.width, height: size.height),
            detail: String(localized: "\(count) frames · \(seconds / 60):\(String(format: "%02d", seconds % 60))")
        )
    }

    /// Fits `maxDimension` (0 = no limit) and rounds up to even sides for H.264.
    static func canvasSize(width: Int, height: Int, maxDimension: Int) -> (width: Int, height: Int) {
        var (w, h) = (Double(width), Double(height))
        let longest = max(w, h)
        if maxDimension > 0, longest > Double(maxDimension) {
            let scale = Double(maxDimension) / longest
            (w, h) = ((w * scale).rounded(), (h * scale).rounded())
        }
        let even = { (v: Double) in max(2, Int(v) + Int(v) % 2) }
        return (even(w), even(h))
    }

    /// Browsers play GIF delays of 10 ms or less at 100 ms; match them.
    private static func delayMs(_ source: CGImageSource, at index: Int) -> Int64 {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double).flatMap { $0 > 0 ? $0 : nil }
            ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0
        return delay <= 0.011 ? 100 : Int64((delay * 1000).rounded())
    }

    /// Draws a frame over white (transparent GIF pixels have no equivalent in H.264).
    private static func render(_ frame: CGImage, into pool: CVPixelBufferPool, size: (width: Int, height: Int)) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(canvas)
        context.interpolationQuality = .high
        context.draw(frame, in: canvas)
        return buffer
    }
}

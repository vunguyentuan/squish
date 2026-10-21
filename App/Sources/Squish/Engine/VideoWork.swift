import AVFoundation
import CoreMedia
import VideoToolbox

/// Re-encodes videos to HEVC with Apple's hardware encoder.
///
/// Video goes through AVAssetReader → AVAssetWriter at constant quality, keeping resolution,
/// frame rate, orientation and colour (HDR stays 10-bit HDR). AAC audio is copied untouched;
/// other stereo/mono audio is encoded to AAC, and surround tracks are copied as they are.
nonisolated enum VideoWork {
    struct Result: Sendable {
        var pixelSize: CGSize
        /// e.g. "H.264 → HEVC · 1:23"
        var detail: String
    }

    enum Failure: LocalizedError {
        /// Squish wrote this file already; another pass would only lose quality.
        case alreadySquished
        case noVideoTrack
        case unsupportedTrack(String)
        case reading(Error?)
        case writing(Error?)

        var errorDescription: String? {
            switch self {
            case .alreadySquished: "Already optimized by Squish."
            case .noVideoTrack: "This file has no video track."
            case .unsupportedTrack(let kind): "Can't keep this video's \(kind) in the same container."
            case .reading(let error): "macOS couldn't read this video" + (error.map { ": \($0.localizedDescription)" } ?? ".")
            case .writing(let error): "Couldn't write the video" + (error.map { ": \($0.localizedDescription)" } ?? ".")
            }
        }
    }

    static let extensions: Set<String> = ["mov", "mp4", "m4v"]

    /// Written into the "encoding software" metadata of every video Squish produces.
    private static let softwareTag = "Squish"

    /// Maps the app's 30…100 quality slider onto VideoToolbox's 0…1 constant-quality scale.
    static func quality(_ value: Int) -> Double {
        0.25 + Double(min(max(value, 30), 100) - 30) / 70 * 0.5
    }

    static func transcode(
        _ source: URL,
        to destination: URL,
        quality: Double,
        /// Lets the encoder take shortcuts: ~1.75× faster for files ~6% larger at the same quality.
        prioritizeSpeed: Bool,
        keepMetadata: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Result {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let video: AVAssetTrack
        let audioTracks: [AVAssetTrack]
        let duration: CMTime
        let (natural, transform, fps, formats): (CGSize, CGAffineTransform, Float, [CMFormatDescription])
        do {
            if try await isSquished(asset) { throw Failure.alreadySquished }
            guard let first = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideoTrack }
            video = first
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
            (natural, transform, fps, formats) = try await video.load(
                .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions
            )
        } catch let failure as Failure {
            throw failure
        } catch {
            // AVFoundation's own message here is just "Cannot Open".
            throw Failure.reading(nil)
        }

        let format = formats.first
        let colour = format.flatMap { CMFormatDescriptionGetExtensions($0) as? [CFString: Any] } ?? [:]
        let transfer = colour[kCMFormatDescriptionExtension_TransferFunction] as? String
        let isHDR = transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
            || transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: destination, fileType: fileType(for: destination))
        } catch {
            throw Failure.reading(error)
        }
        writer.shouldOptimizeForNetworkUse = true
        defer { removeWriterScratch(for: destination) }
        let software = AVMutableMetadataItem()
        software.identifier = .commonIdentifierSoftware
        software.value = softwareTag as NSString
        software.dataType = kCMMetadataBaseDataType_UTF8 as String
        let kept = keepMetadata ? (try? await asset.load(.metadata)) ?? [] : []
        writer.metadata = kept.filter { $0.commonKey != .commonKeySoftware } + [software]

        // Video: decode to 4:2:0 (10-bit for HDR), encode HEVC at constant quality.
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: isHDR
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(natural.width),
            AVVideoHeightKey: Int(natural.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: quality,
                kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String: prioritizeSpeed,
                AVVideoExpectedSourceFrameRateKey: fps > 0 ? Int(fps.rounded()) : 30,
                AVVideoProfileLevelKey: isHDR
                    ? kVTProfileLevel_HEVC_Main10_AutoLevel as String
                    : kVTProfileLevel_HEVC_Main_AutoLevel as String,
            ] as [String: Any],
        ]
        if let primaries = colour[kCMFormatDescriptionExtension_ColorPrimaries] as? String,
           let transfer,
           let matrix = colour[kCMFormatDescriptionExtension_YCbCrMatrix] as? String {
            videoSettings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: primaries,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: matrix,
            ]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else { throw Failure.unsupportedTrack("video") }
        reader.add(videoOutput)
        writer.add(videoInput)

        let seconds = max(duration.seconds, 0.001)
        var pumps = [TrackPump(output: videoOutput, input: videoInput) { time in progress(min(1, time.seconds / seconds)) }]

        for track in audioTracks {
            let hint = try await track.load(.formatDescriptions).first
            let stream = hint.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let channels = Int(stream?.mChannelsPerFrame ?? 2)
            let copyAsIs = stream?.mFormatID == kAudioFormatMPEG4AAC || channels > 2

            let output: AVAssetReaderTrackOutput
            let input: AVAssetWriterInput
            if copyAsIs {
                output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            } else {
                let rate = stream.map { $0.mSampleRate } ?? 48_000
                output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: max(channels, 1),
                    AVSampleRateKey: rate > 48_000 || rate < 8_000 ? 48_000 : rate,
                    AVEncoderBitRateKey: channels == 1 ? 96_000 : 192_000,
                ])
            }
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else { throw Failure.unsupportedTrack("audio") }
            reader.add(output)
            writer.add(input)
            pumps.append(TrackPump(output: output, input: input))
        }

        for pump in pumps {
            pump.peers = pumps.filter { $0 !== pump }
        }

        guard reader.startReading() else { throw Failure.reading(reader.error) }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw Failure.writing(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            for pump in pumps {
                group.addTask { await pump.run() }
            }
        }
        pumps.forEach { $0.peers = [] }

        if reader.status == .failed {
            writer.cancelWriting()
            throw Failure.reading(reader.error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.writing(writer.error) }

        let shown = natural.applying(transform)
        let codec = format.map { codecName(CMFormatDescriptionGetMediaSubType($0)) } ?? "Video"
        return Result(
            pixelSize: CGSize(width: abs(shown.width).rounded(), height: abs(shown.height).rounded()),
            detail: "\(codec) → HEVC\(isHDR ? " HDR" : "") · \(clock(seconds))"
        )
    }

    private static func isSquished(_ asset: AVAsset) async throws -> Bool {
        let common = try await asset.load(.commonMetadata)
        for item in AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierSoftware) {
            if try await item.load(.stringValue) == softwareTag { return true }
        }
        return false
    }

    /// Fast-start rewriting leaves a "<name>.sb-…" media-data file next to the output; remove it.
    private static func removeWriterScratch(for destination: URL) {
        let fm = FileManager.default
        let directory = destination.deletingLastPathComponent()
        let prefix = destination.lastPathComponent + ".sb-"
        let siblings = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in siblings where name.hasPrefix(prefix) {
            try? fm.removeItem(at: directory.appending(path: name))
        }
    }

    private static func fileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mp4": .mp4
        case "m4v": .m4v
        default: .mov
        }
    }

    private static func codecName(_ code: FourCharCode) -> String {
        switch code {
        case kCMVideoCodecType_H264: "H.264"
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha: "HEVC"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT,
             kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ:
            "ProRes"
        case kCMVideoCodecType_MPEG4Video: "MPEG-4"
        case kCMVideoCodecType_AV1: "AV1"
        default:
            String(decoding: withUnsafeBytes(of: code.bigEndian) { Array($0) }, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces).uppercased()
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Feeds one track from the reader to the writer on its own queue.
/// AVFoundation objects aren't Sendable; each pump confines its pair to `queue`.
nonisolated private final class TrackPump: @unchecked Sendable {
    private let output: AVAssetReaderOutput
    private let input: AVAssetWriterInput
    private let onTime: ((CMTime) -> Void)?
    private let queue = DispatchQueue(label: "dev.squish.video-pump", qos: .userInitiated)
    private var done = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var lastReported = -1.0
    /// The other tracks of the same file, stopped if this one fails to write.
    var peers: [TrackPump] = []

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput, onTime: ((CMTime) -> Void)? = nil) {
        self.output = output
        self.input = input
        self.onTime = onTime
    }

    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                self.continuation = continuation
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    while !done && input.isReadyForMoreMediaData {
                        guard let buffer = output.copyNextSampleBuffer() else {
                            finish()
                            return
                        }
                        guard input.append(buffer) else {
                            // The writer failed: a stalled sibling would otherwise wait forever.
                            finish()
                            peers.forEach { $0.abort() }
                            return
                        }
                        report(CMSampleBufferGetPresentationTimeStamp(buffer))
                    }
                }
            }
        }
    }

    func abort() {
        queue.async { [self] in finish() }
    }

    /// Runs on `queue`.
    private func finish() {
        guard !done else { return }
        done = true
        input.markAsFinished()
        continuation?.resume()
        continuation = nil
    }

    /// Throttled to roughly every 0.25 s of media.
    private func report(_ time: CMTime) {
        guard let onTime, time.isNumeric, time.seconds - lastReported >= 0.25 else { return }
        lastReported = time.seconds
        onTime(time)
    }
}

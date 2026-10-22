import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Throwaway files for tests, removed when the fixture goes away.
final class Sandbox {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "SquishTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func url(_ name: String) -> URL { directory.appending(path: name) }

    /// A photo-like gradient, which every lossy encoder can shrink.
    @discardableResult
    func image(_ name: String, width: Int = 480, height: Int = 320, type: UTType = .png) throws -> URL {
        let url = url(name)
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try Self.gradient(width: width, height: height, phase: 0), nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    func animatedGIF(_ name: String, frames: Int = 6) throws -> URL {
        let url = url(name)
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil))
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<frames {
            CGImageDestinationAddImage(
                dest,
                try Self.gradient(width: 121, height: 81, phase: i),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
            )
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    private static func gradient(width: Int, height: Int, phase: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let colors = [CGColor(red: 0.9, green: 0.2, blue: 0.3, alpha: 1), CGColor(red: 0.1, green: 0.5, blue: 0.95, alpha: 1)]
        let gradient = try #require(CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: nil))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setFillColor(CGColor(gray: 1, alpha: 0.8))
        context.fillEllipse(in: CGRect(x: phase * 12, y: height / 4, width: width / 3, height: height / 2))
        return try #require(context.makeImage())
    }
}

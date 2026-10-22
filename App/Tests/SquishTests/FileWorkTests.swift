import Foundation
import Testing
@testable import Squish

/// The code that touches people's originals: placement, backups, restore and the Squish marker.
@Suite struct FileWorkTests {
    let sandbox: Sandbox

    init() throws {
        sandbox = try Sandbox()
    }

    private func order(_ url: URL, _ mode: SaveMode, options: OptimizeOptions = OptimizeOptions(), folder: URL? = nil) -> WorkOrder {
        WorkOrder(
            source: url,
            inputFormat: Engine.detectFormat(of: url),
            options: options,
            saveMode: mode,
            copySuffix: "-squished",
            folder: folder
        )
    }

    @Test func copyModeLeavesTheOriginalAlone() async throws {
        let source = try sandbox.image("photo.png")
        let before = try Data(contentsOf: source)

        let outcome = await FileWork.run(order(source, .copy), progress: { _ in })

        #expect(outcome.kind == .optimized)
        let output = try #require(outcome.outputURL)
        #expect(output.lastPathComponent == "photo-squished.png")
        #expect(try Data(contentsOf: source) == before)
        #expect(FileWork.fileSize(output) < before.count)
        #expect(FileWork.isMarkedOptimized(output))
        #expect(!FileWork.isMarkedOptimized(source))
    }

    @Test func replaceModeKeepsTagsAndCanRestore() async throws {
        let source = try sandbox.image("tagged.png")
        let original = try Data(contentsOf: source)
        try (source as NSURL).setResourceValue(["Red"], forKey: .tagNamesKey)

        let outcome = await FileWork.run(order(source, .replace), progress: { _ in })
        let backup = try #require(outcome.backupURL)
        defer { try? FileManager.default.removeItem(at: backup) } // keep the Trash clean

        #expect(outcome.kind == .optimized)
        #expect(outcome.outputURL == source)
        #expect(FileWork.fileSize(source) < original.count)
        #expect(try source.resourceValues(forKeys: [.tagNamesKey]).tagNames == ["Red"])
        #expect(try Data(contentsOf: backup) == original)

        try FileWork.restore(source: source, output: outcome.outputURL, backup: backup)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func folderModeNeverOverwrites() async throws {
        let source = try sandbox.image("shot.png")
        let folder = sandbox.url("out")

        let first = await FileWork.run(order(source, .folder, folder: folder), progress: { _ in })
        let second = await FileWork.run(order(source, .folder, folder: folder), progress: { _ in })

        #expect(first.outputURL?.lastPathComponent == "shot.png")
        #expect(second.outputURL?.lastPathComponent == "shot 2.png")
    }

    @Test func conversionWritesANewFileNextToTheOriginal() async throws {
        let source = try sandbox.image("convert.png")
        var options = OptimizeOptions()
        options.output = .webp

        let outcome = await FileWork.run(order(source, .replace, options: options), progress: { _ in })

        #expect(outcome.kind == .optimized)
        #expect(outcome.outputFormat == .webp)
        #expect(outcome.outputURL?.lastPathComponent == "convert.webp")
        #expect(outcome.backupURL == nil)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func resizeFitsTheLongestEdge() async throws {
        let source = try sandbox.image("big.jpg", width: 1200, height: 800, type: .jpeg)
        var options = OptimizeOptions()
        options.maxDimension = 600

        let outcome = await FileWork.run(order(source, .copy, options: options), progress: { _ in })

        #expect(outcome.kind == .optimized)
        #expect(outcome.pixelSize == CGSize(width: 600, height: 400))
    }

    @Test func animatedGIFBecomesMP4() async throws {
        let source = try sandbox.animatedGIF("loop.gif")
        var options = OptimizeOptions()
        options.output = .mp4

        let outcome = await FileWork.run(order(source, .copy, options: options), progress: { _ in })

        #expect(outcome.kind == .optimized)
        #expect(outcome.outputFormat == .mp4)
        #expect(outcome.outputURL?.pathExtension == "mp4")
        #expect(outcome.pixelSize == CGSize(width: 122, height: 82)) // rounded up to even sides
        #expect(outcome.detail?.hasPrefix("6 frames") == true)
    }

    @Test func animatedGIFBecomesWebP() async throws {
        let source = try sandbox.animatedGIF("loop.gif")
        var options = OptimizeOptions()
        options.output = .webp

        let outcome = await FileWork.run(order(source, .copy, options: options), progress: { _ in })

        #expect(outcome.kind == .optimized)
        #expect(outcome.outputURL?.lastPathComponent == "loop.webp")
    }

    @Test func gifWithoutAConversionIsSkipped() async throws {
        let source = try sandbox.animatedGIF("loop.gif")
        let outcome = await FileWork.run(order(source, .copy), progress: { _ in })
        guard case .skipped(let reason) = outcome.kind else {
            Issue.record("expected a skip, got \(outcome.kind)")
            return
        }
        #expect(reason.contains("WebP or MP4"))
    }

    @Test func collectFilesSkipsHiddenAndInProgressFiles() throws {
        try sandbox.image("a.png")
        try sandbox.image(".hidden.png")
        try sandbox.image(".a.squish-1234.png")
        try FileManager.default.createDirectory(at: sandbox.url("nested"), withIntermediateDirectories: true)
        try sandbox.image("nested/b.jpg", type: .jpeg)
        try Data("hi".utf8).write(to: sandbox.url("notes.txt"))

        let found = FileWork.collectFiles(from: [sandbox.directory]).map(\.lastPathComponent).sorted()

        #expect(found == ["a.png", "b.jpg"])
    }

    @Test func uniqueURLCountsUp() throws {
        try sandbox.image("x.png")
        try sandbox.image("x 2.png")
        #expect(FileWork.uniqueURL(in: sandbox.directory, stem: "x", ext: "png").lastPathComponent == "x 3.png")
        #expect(FileWork.uniqueURL(in: sandbox.directory, stem: "y", ext: "png").lastPathComponent == "y.png")
    }
}

import Foundation
import Testing
@testable import Squish

/// A private defaults domain per test, deleted afterwards.
final class TestDefaults {
    let name = "SquishTests-\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: name)!

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: name)
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences/\(name).plist")
        try? FileManager.default.removeItem(at: file)
    }
}

@Suite final class PreferencesTests {
    let store = TestDefaults()
    var defaults: UserDefaults { store.defaults }

    @Test func formatRulesOverrideTheGlobalSettings() {
        let prefs = Preferences(defaults: defaults)
        prefs.preset = .balanced
        prefs.output = .webp
        prefs.setRule(FormatRule(preset: .lossless, output: .original), for: .png)
        prefs.setRule(FormatRule(output: .jpeg), for: .heic)

        let png = prefs.options(for: .png)
        #expect(png.lossless && png.output == .original)

        let heic = prefs.options(for: .avif)
        #expect(!heic.lossless && heic.quality == 80 && heic.output == .jpeg)

        let jpeg = prefs.options(for: .jpeg)
        #expect(jpeg.output == .webp)
    }

    @Test func rulesSurviveARelaunch() {
        let prefs = Preferences(defaults: defaults)
        prefs.setRule(FormatRule(output: .mp4), for: .gif)
        prefs.maxDimension = 1920

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.rule(for: .gif).output == .mp4)
        #expect(reloaded.maxDimension == 1920)
        #expect(reloaded.summary.contains("1920 px"))
    }

    @Test func emptyRulesAreDropped() {
        let prefs = Preferences(defaults: defaults)
        prefs.setRule(FormatRule(preset: .maximum), for: .jpeg)
        prefs.setRule(FormatRule(), for: .jpeg)
        #expect(prefs.formatRules.isEmpty)
    }

    @Test func overridesFromShortcutsWin() {
        var options = OptimizeOptions()
        JobOverride(preset: .maximum, output: .avif, maxDimension: 1024).apply(to: &options)
        #expect(options.quality == 65 && options.effort == 2 && options.output == .avif && options.maxDimension == 1024)

        var untouched = OptimizeOptions(maxDimension: 800)
        JobOverride().apply(to: &untouched)
        #expect(untouched == OptimizeOptions(maxDimension: 800))
    }

    @Test func gifsOfferVideo() {
        #expect(OptimizeOptions().output == .original)
        #expect(OutputFormat.conversions(for: .gif) == [.webp, .mp4])
        #expect(OutputFormat.conversions(for: .jpeg) == [.webp, .avif])
        #expect(!OutputFormat.imageCases.contains(.mp4))
    }
}

@Suite struct LifetimeStatsTests {
    @Test func countsAndUndoes() {
        let store = TestDefaults()
        let defaults = store.defaults
        let stats = LifetimeStats(defaults: defaults)
        stats.record(saved: 1_000)
        stats.record(saved: 500)
        stats.undo(saved: 500)
        #expect(stats.savedBytes == 1_000 && stats.files == 1)
        #expect(LifetimeStats(defaults: defaults).savedBytes == 1_000)
    }
}

@Suite struct SizingTests {
    @Test func videoScalingKeepsAspectAndEvenSides() {
        #expect(VideoWork.scaledSize(CGSize(width: 3840, height: 2160), maxDimension: 1920) == CGSize(width: 1920, height: 1080))
        #expect(VideoWork.scaledSize(CGSize(width: 1080, height: 1920), maxDimension: 1280) == CGSize(width: 720, height: 1280))
        #expect(VideoWork.scaledSize(CGSize(width: 1280, height: 720), maxDimension: 1920) == CGSize(width: 1280, height: 720))
    }

    @Test func gifCanvasIsEven() {
        #expect(GIFVideo.canvasSize(width: 321, height: 241, maxDimension: 0) == (322, 242))
        #expect(GIFVideo.canvasSize(width: 321, height: 241, maxDimension: 200) == (200, 150))
    }
}

@Suite struct BatchReportTests {
    @Test func csvEscapesAwkwardNames() throws {
        let sandbox = try Sandbox()
        let url = try sandbox.image("a, \"quoted\" name.png")
        let job = ImageJob(url: url, batch: UUID())
        job.state = .optimized
        job.optimizedSize = job.originalSize / 2

        let lines = BatchReport.csv([job]).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[1].hasPrefix("\"a, \"\"quoted\"\" name.png\","))
        #expect(lines[1].contains(",optimized,PNG,"))
        // Plural forms come from the compiled catalog, which unit tests don't load.
        #expect(BatchReport.summary([job]).hasPrefix("Squished 1 item"))
    }
}

@Suite struct ClipboardTests {
    @Test func shrinksPNGData() throws {
        let sandbox = try Sandbox()
        let png = try Data(contentsOf: try sandbox.image("clip.png"))
        let result = try #require(ClipboardSquisher.optimize(png, format: .png, options: OptimizeOptions()))
        #expect(result.count < png.count)
        #expect(result.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }
}

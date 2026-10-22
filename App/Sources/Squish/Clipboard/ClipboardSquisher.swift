import AppKit
import Carbon.HIToolbox
import Observation
import UniformTypeIdentifiers

/// Optimizes the image on the clipboard in place (⌃⌥⌘V), e.g. a screenshot before pasting it
/// into Slack or GitHub. The image keeps its type (PNG stays PNG, JPEG stays JPEG) so every app
/// can still paste it. Copied files are optimized like any dropped file.
@Observable
final class ClipboardSquisher {
    static let shared = ClipboardSquisher()
    static let shortcut = "⌃⌥⌘V"

    private(set) var isWorking = false
    private var hotKey: HotKey?

    func updateHotKey() {
        hotKey = nil
        guard Preferences.shared.clipboardHotKey else { return }
        hotKey = HotKey(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.squish()
        }
    }

    func squish() {
        guard !isWorking else { return }
        let pasteboard = NSPasteboard.general

        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            let count = OptimizerStore.shared.add(files).map { OptimizerStore.shared.jobs(in: $0).count } ?? 0
            ClipboardHUD.show(count > 0 ? "Optimizing \(Fmt.items(count)) from the clipboard" : "No images in the copied files")
            return
        }

        guard let (data, format) = Self.image(on: pasteboard) else {
            NSSound.beep()
            ClipboardHUD.show("No image on the clipboard")
            return
        }
        isWorking = true
        let changeCount = pasteboard.changeCount
        var options = Preferences.shared.options(for: format)
        // Pasting needs a type every app accepts, so the format never changes here.
        options.output = .original

        Task {
            let result = await Task.detached(priority: .userInitiated) { [data, format, options] in
                Self.optimize(data, format: format, options: options)
            }.value
            isWorking = false
            guard let result else {
                ClipboardHUD.show("Couldn't optimize the clipboard image")
                return
            }
            guard result.count < data.count else {
                ClipboardHUD.show("Clipboard image is already optimal")
                return
            }
            // Something else was copied while we worked: don't clobber it.
            guard pasteboard.changeCount == changeCount else { return }
            pasteboard.clearContents()
            pasteboard.setData(result, forType: format == .jpeg ? NSPasteboard.PasteboardType(UTType.jpeg.identifier) : .png)
            let saved = Int64(data.count - result.count)
            LifetimeStats.shared.record(saved: saved)
            let fraction = Double(saved) / Double(data.count)
            ClipboardHUD.show("Clipboard image \(Fmt.bytes(Int64(data.count))) → \(Fmt.bytes(Int64(result.count))) (−\(Fmt.percent(fraction)))")
        }
    }

    /// PNG or JPEG bytes from the pasteboard; TIFF (what many apps copy) becomes PNG.
    private static func image(on pasteboard: NSPasteboard) -> (Data, ImageFormat)? {
        if let png = pasteboard.data(forType: .png) { return (png, .png) }
        if let jpeg = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) { return (jpeg, .jpeg) }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return (png, .png)
        }
        return nil
    }

    nonisolated static func optimize(_ data: Data, format: ImageFormat, options: OptimizeOptions) -> Data? {
        let fm = FileManager.default
        let stem = "squish-clipboard-\(UUID().uuidString)"
        let input = fm.temporaryDirectory.appending(path: "\(stem).\(format.fileExtension)")
        let output = fm.temporaryDirectory.appending(path: "\(stem)-out.\(format.fileExtension)")
        defer {
            try? fm.removeItem(at: input)
            try? fm.removeItem(at: output)
        }
        do {
            try data.write(to: input)
        } catch {
            return nil
        }
        let result = Engine.optimize(input: input, output: output, options: options)
        switch result.status {
        case .optimized: return try? Data(contentsOf: output)
        case .alreadyOptimal: return data
        case .failed: return nil
        }
    }
}

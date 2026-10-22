import CoreServices
import Foundation

/// Optimizes images and videos that land in watched folders, such as screenshots on the Desktop.
///
/// Only files added directly inside a watched folder count (not subfolders), and only after
/// their size has stopped changing. Files Squish wrote itself carry an extended attribute
/// (see `FileWork.markOptimized`), so replacing or copying never triggers another pass.
final class FolderWatcher {
    static let shared = FolderWatcher()

    private var stream: FSEventStreamRef?
    private var folders: Set<String> = []
    private var pending: [URL: Task<Void, Never>] = [:]

    /// Where macOS saves screenshots (Desktop unless changed in the Screenshot app).
    static var screenshotsFolder: URL {
        let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        if let custom, !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop", directoryHint: .isDirectory)
    }

    /// Restarts the event stream for the folders in Preferences.
    func update() {
        stop()
        let urls = Preferences.shared.watchedFolders.filter { (try? $0.checkResourceIsReachable()) == true }
        folders = Set(urls.map { $0.standardizedFileURL.path })
        guard !folders.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: flags, count: count))
            MainActor.assumeIsolated { watcher.handle(zip(paths, flags)) }
        }
        let options = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf
        )
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            Array(folders) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            options
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stop() {
        pending.values.forEach { $0.cancel() }
        pending = [:]
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(_ events: some Sequence<(String, FSEventStreamEventFlags)>) {
        let arrived = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed)
        for (path, flags) in events where flags & arrived != 0 && flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 {
            let url = URL(fileURLWithPath: path)
            guard folders.contains(url.deletingLastPathComponent().standardizedFileURL.path),
                  FileWork.isAccepted(url)
            else { continue }
            pending[url]?.cancel()
            pending[url] = Task { [weak self] in
                await self?.settle(url)
            }
        }
    }

    /// Waits until the file has stopped growing, then queues it.
    private func settle(_ url: URL) async {
        var lastSize: Int64 = -1
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            guard FileManager.default.fileExists(atPath: url.path) else { break }
            let size = FileWork.fileSize(url)
            if size > 0 && size == lastSize {
                pending[url] = nil
                queue(url)
                return
            }
            lastSize = size
        }
        pending[url] = nil
    }

    private func queue(_ url: URL) {
        let store = OptimizerStore.shared
        // Restored originals and files already handled this session are left alone.
        let known = store.jobs.contains { $0.sourceURL == url || $0.outputURL == url }
        guard !known, !FileWork.isMarkedOptimized(url) else { return }
        store.add([url], quietly: true)
    }
}

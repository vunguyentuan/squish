import Foundation
import Observation

/// All-time totals across launches: bytes saved and files optimized.
@Observable
final class LifetimeStats {
    static let shared = LifetimeStats()

    private let defaults: UserDefaults

    private(set) var savedBytes: Int64
    private(set) var files: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        savedBytes = Int64(defaults.integer(forKey: "lifetimeSavedBytes"))
        files = defaults.integer(forKey: "lifetimeFiles")
    }

    /// Counts one optimized file. Conversions that grew are counted too, so the total stays honest.
    func record(saved bytes: Int64) {
        savedBytes += bytes
        files += 1
        persist()
    }

    /// Takes a file back out after its original was restored.
    func undo(saved bytes: Int64) {
        savedBytes -= bytes
        files = max(0, files - 1)
        persist()
    }

    func reset() {
        savedBytes = 0
        files = 0
        persist()
    }

    private func persist() {
        defaults.set(Int(savedBytes), forKey: "lifetimeSavedBytes")
        defaults.set(files, forKey: "lifetimeFiles")
    }
}

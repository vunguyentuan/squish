import AppKit

/// Pure shake math: counts quick horizontal direction reversals.
nonisolated struct ShakeRecognizer {
    /// Minimum horizontal travel before a direction change counts as a swing.
    var minSwing: Double = 38
    /// Direction reversals needed inside `window`.
    var reversalsNeeded = 3
    var window: TimeInterval = 0.75

    private var direction: Double = 0
    private var anchorX: Double?
    private var extremeX: Double = 0
    private var reversalTimes: [TimeInterval] = []

    /// Feeds one cursor sample; returns true when a shake completes.
    mutating func feed(x: Double, time: TimeInterval) -> Bool {
        guard let anchor = anchorX else {
            anchorX = x
            extremeX = x
            return false
        }
        if direction == 0 {
            if abs(x - anchor) >= minSwing {
                direction = x > anchor ? 1 : -1
                extremeX = x
            }
            return false
        }
        if (x - extremeX) * direction > 0 {
            extremeX = x // still travelling the same way
            return false
        }
        guard abs(x - extremeX) >= minSwing else { return false }
        direction = -direction
        extremeX = x
        reversalTimes.append(time)
        reversalTimes.removeAll { time - $0 > window }
        return reversalTimes.count >= reversalsNeeded
    }

    mutating func reset() {
        direction = 0
        anchorX = nil
        reversalTimes.removeAll()
    }
}

/// Fires when the cursor is shaken while dragging files anywhere on screen.
///
/// Mouse-down monitors need no Accessibility permission. Instead of relying on drag events
/// (which a system drag session may swallow), the cursor is sampled while the button is held.
/// A file drag is recognised by the drag pasteboard changing after mouse-down and holding file URLs.
final class ShakeDetector {
    var recognizer = ShakeRecognizer()
    var isEnabled = true
    var onShake: (NSPoint) -> Void = { _ in }
    var onDragEnded: () -> Void = {}

    private var monitors: [Any] = []
    private var sampler: Timer?
    private var pasteboardCountAtMouseDown = 0
    private var isFileDrag: Bool?
    private var fired = false

    func start() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            self?.mouseDown()
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            self?.mouseDown()
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        endSampling()
    }

    private func mouseDown() {
        guard isEnabled else { return }
        pasteboardCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        isFileDrag = nil
        fired = false
        recognizer.reset()
        sampler?.invalidate()
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
    }

    private func sample() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            if isFileDrag == true { onDragEnded() }
            endSampling()
            return
        }
        guard !fired, carriesFiles() else { return }
        if recognizer.feed(x: NSEvent.mouseLocation.x, time: ProcessInfo.processInfo.systemUptime) {
            fired = true
            onShake(NSEvent.mouseLocation)
        }
    }

    private func endSampling() {
        sampler?.invalidate()
        sampler = nil
    }

    private func carriesFiles() -> Bool {
        if let isFileDrag { return isFileDrag }
        let pasteboard = NSPasteboard(name: .drag)
        // Until the pasteboard changes, this is a plain click-drag (selection, window move…).
        guard pasteboard.changeCount != pasteboardCountAtMouseDown else { return false }
        let hasFiles = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        isFileDrag = hasFiles
        return hasFiles
    }
}

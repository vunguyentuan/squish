import AppKit
import Observation
import SwiftUI

/// Borderless floating panel that hosts the drop shelf on every Space, even over full-screen apps.
final class ShelfPanel: NSPanel {
    init(contentView: NSView, size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.contentView = contentView
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@Observable
final class ShelfController {
    static let shared = ShelfController()
    static let size = NSSize(width: 236, height: 236)

    /// Drives the SwiftUI entrance/exit animation.
    var isPresented = false
    var batch: UUID?
    var isHovering = false { didSet { if !isHovering { scheduleAutoHide() } } }
    var isTargeted = false

    private var panel: ShelfPanel?
    private let detector = ShakeDetector()
    private var hideTask: Task<Void, Never>?

    func startMonitoring() {
        detector.onShake = { [weak self] point in self?.show(at: point) }
        detector.onDragEnded = { [weak self] in self?.dragEnded() }
        detector.isEnabled = Preferences.shared.shakeToShelf
        detector.start()
    }

    func setEnabled(_ enabled: Bool) {
        detector.isEnabled = enabled
        if !enabled { hide() }
    }

    func show(at point: NSPoint? = nil) {
        hideTask?.cancel()
        let panel = panel ?? makePanel()
        let anchor = point ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        var origin = NSPoint(x: anchor.x - Self.size.width / 2, y: anchor.y - Self.size.height / 2)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - Self.size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - Self.size.height - 8)
        }
        panel.setFrameOrigin(origin)
        if !isPresented {
            batch = nil
        }
        panel.orderFrontRegardless()
        Haptics.tap()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { isPresented = true }
    }

    func hide() {
        hideTask?.cancel()
        guard isPresented else { return }
        withAnimation(.smooth(duration: 0.2)) { isPresented = false }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(240))
            guard let self, !Task.isCancelled, !isPresented else { return }
            panel?.orderOut(nil)
            batch = nil
        }
    }

    func receive(_ urls: [URL]) {
        guard let batch = OptimizerStore.shared.add(urls) else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { self.batch = batch }
    }

    /// Called by the view when its batch finishes.
    func batchFinished() {
        scheduleAutoHide(after: .seconds(5))
    }

    func openMainWindow() {
        WindowRouter.openMain()
        hide()
    }

    private func dragEnded() {
        // Shaken but dropped elsewhere: tidy up the empty shelf.
        guard isPresented, batch == nil else { return }
        scheduleAutoHide(after: .milliseconds(1400))
    }

    private func scheduleAutoHide(after delay: Duration = .seconds(3)) {
        guard isPresented else { return }
        let store = OptimizerStore.shared
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, !isHovering, !isTargeted else { return }
            if let batch, store.jobs(in: batch).contains(where: { !$0.state.isFinished }) { return }
            hide()
        }
    }

    private func makePanel() -> ShelfPanel {
        let host = NSHostingView(rootView: ShelfView().environment(OptimizerStore.shared).environment(Preferences.shared))
        host.sizingOptions = []
        let panel = ShelfPanel(contentView: host, size: Self.size)
        self.panel = panel
        return panel
    }
}

/// Lets AppKit code open the SwiftUI main window.
enum WindowRouter {
    static var openWindow: OpenWindowAction?

    static func openMain() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: "main")
        }
    }
}

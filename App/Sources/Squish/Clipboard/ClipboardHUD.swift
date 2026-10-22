import AppKit
import SwiftUI

/// A brief glass capsule near the top of the screen confirming what happened to the clipboard.
enum ClipboardHUD {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ message: LocalizedStringResource) {
        hideTask?.cancel()
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: HUDView(message: String(localized: message)))
        let size = panel.contentView?.fittingSize ?? NSSize(width: 320, height: 44)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(
                NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 24, width: size.width, height: size.height),
                display: true
            )
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }
            if !Task.isCancelled { panel.orderOut(nil) }
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private struct HUDView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "arrow.down.right.and.arrow.up.left")
            .font(.callout.weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .glassEffect(.regular, in: .capsule)
            .padding(12) // room for the glass shadow
            .fixedSize()
    }
}

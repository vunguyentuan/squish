import AppKit
import SwiftUI

/// Starts a multi-file AppKit drag, which SwiftUI's `onDrag` can't do.
struct FileDragSource: NSViewRepresentable {
    var urls: [URL]

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.urls = urls
    }

    final class DragView: NSView, NSDraggingSource {
        var urls: [URL] = []
        private var mouseDownEvent: NSEvent?

        override func hitTest(_ point: NSPoint) -> NSView? {
            urls.isEmpty ? nil : super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down = mouseDownEvent, !urls.isEmpty else { return }
            mouseDownEvent = nil
            let items = urls.enumerated().map { index, url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                let origin = convert(down.locationInWindow, from: nil)
                item.setDraggingFrame(
                    NSRect(x: origin.x - 32 + CGFloat(index) * 6, y: origin.y - 32 - CGFloat(index) * 6, width: 64, height: 64),
                    contents: icon
                )
                return item
            }
            beginDraggingSession(with: items, event: down, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .generic] : []
        }
    }
}

import AppKit
import SwiftUI

/// An AppKit drag handle for resizing the inspector. A SwiftUI `DragGesture` over the inspector
/// (which is AppKit-backed — `NSSplitView` + `NSScrollView`s) doesn't reliably receive mouse events,
/// so the handle is its own `NSView` that handles the drag directly and shows a resize cursor.
struct InspectorResizeHandle: NSViewRepresentable {
  /// Incremental horizontal drag delta in points (positive = rightward), per mouse-moved event.
  let onDrag: (CGFloat) -> Void
  let onEnd: () -> Void

  func makeNSView(context: Context) -> HandleView { HandleView() }

  func updateNSView(_ nsView: HandleView, context: Context) {
    nsView.onDrag = onDrag
    nsView.onEnd = onEnd
  }

  final class HandleView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var lastX: CGFloat = 0

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { lastX = event.locationInWindow.x }

    override func mouseDragged(with event: NSEvent) {
      let x = event.locationInWindow.x
      onDrag?(x - lastX)
      lastX = x
    }

    override func mouseUp(with event: NSEvent) { onEnd?() }
  }
}

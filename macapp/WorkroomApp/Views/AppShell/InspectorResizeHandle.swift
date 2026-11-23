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

    override init(frame: NSRect) {
      super.init(frame: frame)
      // Its own accessibility element: the handle is AppKit, so SwiftUI's modifiers can't name it,
      // and without this assistive tech and UI tests can't find the resize edge at all.
      setAccessibilityElement(true)
      setAccessibilityRole(.handle)
      setAccessibilityLabel("Resize Inspector")
      setAccessibilityIdentifier("inspector.resizeHandle")
      toolTip = "Drag to resize the inspector"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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

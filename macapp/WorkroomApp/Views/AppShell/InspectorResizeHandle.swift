import AppKit
import SwiftUI

/// An AppKit drag handle for resizing a column: the inspector, the Projects sidebar and the
/// changeset file list all use it. A SwiftUI `DragGesture` over AppKit-backed content
/// (`NSSplitView` + `NSScrollView`s) doesn't reliably receive mouse events, so the handle is its own
/// `NSView` that handles the drag directly and shows a resize cursor.
struct InspectorResizeHandle: NSViewRepresentable {
  /// How the handle names itself to assistive tech, UI tests and the tooltip. Each caller passes
  /// its own, so two handles on screen never share a label or an identifier.
  struct Identity {
    let label: String
    let identifier: String
    let tooltip: String

    static let inspector = Identity(
      label: "Resize Inspector", identifier: "inspector.resizeHandle",
      tooltip: "Drag to resize the inspector")
    static let sidebar = Identity(
      label: "Resize Sidebar", identifier: "sidebar.resizeHandle",
      tooltip: "Drag to resize the sidebar")
    static let changesetFileList = Identity(
      label: "Resize File List", identifier: "changeset.fileList.resizeHandle",
      tooltip: "Drag to resize the file list")
  }

  let identity: Identity
  /// Incremental horizontal drag delta in points (positive = rightward), per mouse-moved event.
  let onDrag: (CGFloat) -> Void
  let onEnd: () -> Void

  func makeNSView(context: Context) -> HandleView { HandleView() }

  func updateNSView(_ nsView: HandleView, context: Context) {
    nsView.onDrag = onDrag
    nsView.onEnd = onEnd
    nsView.setAccessibilityLabel(identity.label)
    nsView.setAccessibilityIdentifier(identity.identifier)
    nsView.toolTip = identity.tooltip
  }

  final class HandleView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var lastX: CGFloat = 0

    override init(frame: NSRect) {
      super.init(frame: frame)
      // Its own accessibility element: the handle is AppKit, so SwiftUI's modifiers can't name it,
      // and without this assistive tech and UI tests can't find the resize edge at all. The label,
      // identifier and tooltip come from the caller's `Identity` in `updateNSView`.
      setAccessibilityElement(true)
      setAccessibilityRole(.handle)
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

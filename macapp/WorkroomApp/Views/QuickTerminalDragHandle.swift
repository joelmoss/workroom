import AppKit
import Defaults
import SwiftUI

extension EnvironmentValues {
  /// True inside the Quick Terminal's window: the tab strip and pane footers it shares with
  /// workrooms put a `QuickTerminalDragHandle` in their empty space.
  @Entry var isQuickTerminal = false
}

/// Empty chrome you can drag the Quick Terminal by. The window isn't movable (AppKit would let it
/// float free); this moves it itself, docked to the nearest screen edge the whole way
/// (`QuickTerminalController.dragDock`), and keeps where it ends up for the next summon.
struct QuickTerminalDragHandle: NSViewRepresentable {
  func makeNSView(context: Context) -> HandleView { HandleView() }
  func updateNSView(_ nsView: HandleView, context: Context) {}

  final class HandleView: NSView {
    /// The pointer's distance from the window's centre when the drag began.
    private var grab: NSPoint?
    private var landed: (edge: QuickTerminalEdge, offset: Double)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
      guard let window else { return }
      let pointer = NSEvent.mouseLocation
      grab = NSPoint(x: pointer.x - window.frame.midX, y: pointer.y - window.frame.midY)
      NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
      guard let window, let grab else { return }
      landed =
        QuickTerminalController.dragDock(window, pointer: NSEvent.mouseLocation, grab: grab)
        ?? landed
    }

    override func mouseUp(with event: NSEvent) {
      if grab != nil { NSCursor.pop() }
      grab = nil
      // Once, at the end: the Settings picker follows the edge it landed on.
      guard let landed else { return }
      self.landed = nil
      Defaults[.quickTerminalEdge] = landed.edge
      Defaults[.quickTerminalOffset] = landed.offset
    }
  }
}

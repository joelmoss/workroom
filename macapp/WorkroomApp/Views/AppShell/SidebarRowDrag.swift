import AppKit
import WorkroomDomain

/// A terminals row being dragged in a window's Terminals section (#659, #652): a standalone
/// terminal's, a group's, or one of a group's terminals. It reports the pointer to the window's
/// drag session (`TerminalDragSession`), which highlights the destination under it, and when the
/// button comes up over one that takes it, drops there (`AppStore.dropTerminals`): another row's
/// middle (a folded group's row: anywhere below its top quarter, `AppStore.groupBand`), a
/// title-bar tab, a pane tab or a group's title bar.
///
/// The List's reorder drag takes the mouse once it starts, so the row's own `DragGesture` sees the
/// drag begin but never its end; a timer follows the pointer from then until the button comes up.
/// That mouse-up is the one place a row drops on something. Measured in the VM (#652): let go on a
/// row's middle, the List refuses the drop and calls no `.onMove`; let go between rows, the timer
/// sees the button come up first, finds no destination, and the List's `.onMove` then reorders
/// (or, for a group's terminal, makes it standalone there).
@MainActor
final class SidebarRowDrag {
  /// How far a row's own `DragGesture` waits before it reports the drag: one point. The List's drag
  /// starts after a few points and takes the mouse from then, so a row gesture waiting longer
  /// (it was 6) can lose that race and never report the drag at all, and the drop never happens
  /// (#652: the flaky row-onto-row UI tests). A click that wobbles a point follows the pointer
  /// until the button comes up over its own row, where nothing takes it.
  static let startDistance: CGFloat = 1

  private var dragged: TerminalDragSource?
  private weak var store: AppStore?
  private var poll: Timer?
  /// The row whose drag last ended in a drop, so the List's own move of it, should it come,
  /// doesn't also move it (`dropped(_:)`).
  private var lastDropped: TerminalDragSource?

  /// Row `dragged`'s drag moved: starts following the pointer, and highlights what is under it.
  func moved(_ dragged: TerminalDragSource, in store: AppStore) {
    if self.dragged != dragged {
      stop()
      self.dragged = dragged
      self.store = store
      lastDropped = nil
      SidebarTableDragImage.title = store.ghostTitle(of: dragged)
      let poll = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.follow() }
      }
      RunLoop.main.add(poll, forMode: .common)
      self.poll = poll
    }
    follow()
  }

  /// Whether row `dragged`'s drag just ended in a drop: the List's move of it then does nothing.
  func dropped(_ dragged: TerminalDragSource) -> Bool { lastDropped == dragged }

  private func follow() {
    guard let dragged, let store else { return stop() }
    let point = NSEvent.mouseLocation
    guard NSEvent.pressedMouseButtons & 1 != 0 else {
      // Decided now, moved after: the List's `.onMove`, should it come, sees `dropped` first.
      if store.terminalDrag.ended(at: point) { lastDropped = dragged }
      return stop()
    }
    store.terminalDrag.moved(dragged, from: .sidebar, to: point)
  }

  private func stop() {
    SidebarTableDragImage.title = nil
    poll?.invalidate()
    poll = nil
    if let store, store.terminalDrag.source == dragged { store.terminalDrag.cancel() }
    dragged = nil
  }
}

import AppKit
import WorkroomDomain

/// A standalone terminal's row being dragged in a window's sidebar (#659): it highlights the row
/// it would group with, and when the button comes up over the middle of another standalone
/// terminal's row, the two become an unnamed group.
///
/// The List's reorder drag takes the mouse once it starts, so the row's own `DragGesture` sees the
/// drag begin but never its end; a timer follows the pointer from then until the button comes up.
/// That mouse-up is the one place a row groups. Measured in the VM (#652): let go on a row's middle,
/// the List refuses the drop and calls no `.onMove`; let go between rows, the timer sees the button
/// come up first, finds no row to group with, and the List's `.onMove` then reorders.
@MainActor
final class SidebarRowDrag {
  private var sid: SidebarID?
  private weak var store: AppStore?
  private var poll: Timer?
  /// The row whose drag last ended in a group, so the List's own move of it, should it come,
  /// doesn't also reorder it (`grouped(_:)`).
  private var lastGrouped: SidebarID?

  /// Row `sid`'s drag moved: starts following the pointer, and highlights the row under it.
  func moved(_ sid: SidebarID, in store: AppStore) {
    if self.sid != sid {
      stop()
      self.sid = sid
      self.store = store
      lastGrouped = nil
      let poll = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.follow() }
      }
      RunLoop.main.add(poll, forMode: .common)
      self.poll = poll
    }
    follow()
  }

  /// Whether row `sid`'s drag just ended in a group: the List's move of it then does nothing.
  func grouped(_ sid: SidebarID) -> Bool { lastGrouped == sid }

  private func follow() {
    guard let sid, let store else { return stop() }
    let point = NSEvent.mouseLocation
    guard NSEvent.pressedMouseButtons & 1 != 0 else {
      stop()
      if let destination = store.rowDropDestination(sid, at: point),
        store.dropRow(sid, onto: destination)
      {
        lastGrouped = sid
      }
      return
    }
    let shown = store.rowDropDestination(sid, at: point).map(PaneDropZone.target)
    if store.incomingPaneDrop != shown { store.incomingPaneDrop = shown }
  }

  private func stop() {
    poll?.invalidate()
    poll = nil
    if let store, store.incomingPaneDrop != nil { store.incomingPaneDrop = nil }
    sid = nil
  }
}

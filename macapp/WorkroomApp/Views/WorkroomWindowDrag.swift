import AppKit
import WorkroomDomain

/// A workroom dragged in from another window, hovering over this one (#444).
struct IncomingWorkroomDrop: Equatable {
  /// Where its tab would land among this window's: nil for the end.
  let slot: Int?
  /// The gap to open for it: the dragged tab's width.
  let width: CGFloat
}

/// Dragging a workroom out of its window (#444): its workroom tab and its title bar both do this,
/// so they share it. Inside the window a drag still reorders or splits as before; these run only
/// once it has left. Over another Workroom window the workroom joins it, its tab bar opening a gap
/// where it will land; anywhere else it gets a new window, shown by the same ghost a torn-off pane
/// gets.
@MainActor
enum WorkroomWindowDrag {
  /// Show where a drag outside the window would land.
  static func update(store: AppStore, sid: SidebarID, target: TerminalTarget, width: CGFloat) {
    guard store.canMoveWorkroom(sid) else { return cancel() }
    let screen = NSEvent.mouseLocation
    if let destination = joinable(at: screen, from: store) {
      DetachedPaneDragPreview.shared.hide()
      show(
        IncomingWorkroomDrop(slot: destination.incomingWorkroomSlot(at: screen), width: width),
        on: destination)
    } else {
      show(nil, on: nil)
      DetachedPaneDragPreview.shared.show(
        title: target.title, glyph: target.workroomGlyph, at: screen,
        size: store.hostWindow?.frame.size)
    }
  }

  /// The drag was let go outside the window: join the window under it, or open a new one.
  static func end(store: AppStore, sid: SidebarID) {
    defer { cancel() }
    guard store.canMoveWorkroom(sid) else { return }
    let screen = NSEvent.mouseLocation
    if let destination = joinable(at: screen, from: store) {
      store.moveWorkroom(
        sid, to: destination, at: destination.incomingWorkroomSlot(at: screen))
    } else {
      store.moveWorkroomToNewWindow(sid, at: screen)
    }
  }

  /// Take down the ghost and every window's gap. Called whenever a drag ends or comes back inside.
  static func cancel() {
    DetachedPaneDragPreview.shared.hide()
    show(nil, on: nil)
  }

  /// The other Workroom window under `screen`, if any. The window the drag started in is not one:
  /// a drop over one of its own torn-off panes opens a new window like any other empty spot.
  private static func joinable(at screen: CGPoint, from store: AppStore) -> AppStore? {
    let ghost = DetachedPaneDragPreview.shared.windowNumber.map { Set([$0]) } ?? []
    guard
      case .store(let destination) = WindowRegistry.shared.dropWindow(
        at: screen, skipping: ghost), destination !== store
    else { return nil }
    return destination
  }

  /// One window at a time shows the gap.
  private static func show(_ drop: IncomingWorkroomDrop?, on destination: AppStore?) {
    for other in WindowRegistry.shared.allStores {
      let value = other === destination ? drop : nil
      if other.incomingWorkroomDrop != value { other.incomingWorkroomDrop = value }
    }
  }
}

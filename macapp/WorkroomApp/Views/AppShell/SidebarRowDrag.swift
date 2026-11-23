import AppKit
import WorkroomDomain

/// A terminals row being dragged in a window's Terminals section (#659, #652): a standalone
/// terminal's, a group's, or one of a group's terminals. It reports the pointer to the window's
/// drag session (`TerminalDragSession`), which highlights the destination under it, and when the
/// button comes up over one that takes it, drops there (`AppStore.dropTerminals`): another row's
/// middle (a folded group's row: anywhere below its top quarter, `AppStore.groupBand`), a
/// title-bar tab, a pane tab or a group's title bar.
///
/// The row's own `DragGesture` sees a drag begin but not end: the List's reorder drag takes the
/// mouse. The List may take the drop too, on a row's middle as readily as between rows, so this
/// decides every release once, where the button came up, and the List moves a row only where this
/// dropped nothing (`listMoves`). Nothing orders what reports a release (#776, measured in the VM):
/// - The gesture's first report can come after the button is already up.
/// - The List's drop can come before the timer sees the button up.
/// - A mouse-up that beats the List's drag goes to the app instead, and leaves that drag running
///   until the pointer next moves, when it drops there, by the row index it started with.
@MainActor
final class SidebarRowDrag {
  /// How far a row's own `DragGesture` waits before it reports the drag: one point. The List's drag
  /// starts after a few points and takes the mouse from then, so a row gesture waiting longer
  /// (it was 6) can lose that race and never report the drag at all, and the drop never happens
  /// (#652: the flaky row-onto-row UI tests). A click that wobbles a point follows the pointer
  /// until the button comes up over its own row, where nothing takes it.
  static let startDistance: CGFloat = 1

  /// How far from the release a left-over List drag's drop still counts as let go there: a quarter
  /// of a row, about what the pointer's first move after it covers.
  private static let releaseSlop: CGFloat = 6

  /// The mouse, as a drag reads it: tests give their own.
  struct Mouse {
    var location: @MainActor () -> CGPoint = { NSEvent.mouseLocation }
    var isDown: @MainActor () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    /// Where the button came up, when that mouse-up is still waiting in the app's queue.
    var queuedRelease: @MainActor () -> CGPoint? = {
      NSApp.nextEvent(
        matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: false
      )?.screenLocation
    }
    /// Where the List's drag is. Once that drag has taken the mouse-up out of the queue, where the
    /// button came up; until then it lags, so the queue is read first.
    var listDragLocation: @MainActor () -> CGPoint? = {
      SidebarTableDragImage.session?.draggingLocation
    }
  }

  /// The List's drop of a row: when its drag's press was (system uptime) and where it was let go.
  struct ListDrop {
    let pressedAt: TimeInterval
    let point: CGPoint
  }

  /// How the last drag ended.
  private struct Release {
    let time: TimeInterval
    /// Where the button came up, when an event said so.
    let point: CGPoint?
    let dropped: Bool
  }

  private let mouse: Mouse
  private var dragged: TerminalDragSource?
  private weak var store: AppStore?
  private var poll: Timer?
  private var mouseUpMonitor: Any?
  private var lastRelease: Release?

  init(mouse: Mouse = Mouse()) { self.mouse = mouse }

  /// Row `dragged`'s drag moved: starts following the pointer, and highlights what is under it.
  func moved(_ dragged: TerminalDragSource, in store: AppStore) {
    if self.dragged != dragged {
      stop()
      self.dragged = dragged
      self.store = store
      SidebarTableDragImage.title = store.ghostTitle(of: dragged)
      SidebarTableDragImage.session = nil  // the last row's; this one's hasn't begun
      // Begun even if the button is up already, so there is a drop to make; and here, before the
      // List's drag opens its gap, so the zones are where the user saw them.
      store.terminalDrag.moved(dragged, from: .sidebar, to: mouse.location())
      watchForRelease()
    }
    follow()
  }

  /// Follows the pointer while the button is down, and ends the drag once it is up.
  func follow() {
    guard let dragged, let store else { return stop() }
    if mouse.isDown() {
      store.terminalDrag.moved(dragged, from: .sidebar, to: mouse.location())
    } else {
      // The pointer may have travelled on since: the queued mouse-up says where it was let go.
      release(at: mouse.queuedRelease() ?? mouse.listDragLocation())
    }
  }

  /// Whether the List makes the move of its `drop`. The drag is ended there first if it still runs,
  /// so which of the two heard of the release first doesn't matter. Not by the row the List names:
  /// a left-over drag's index is another row's by then.
  func listMoves(_ drop: ListDrop?) -> Bool {
    guard let drop else {
      if dragged != nil { release(at: nil) }
      return lastRelease?.dropped != true
    }
    if let last = lastRelease, drop.pressedAt < last.time { return moves(drop, after: last) }
    guard dragged != nil else { return true }
    release(at: drop.point)
    return lastRelease?.dropped != true
  }

  /// Whether the List's `drop`, of the drag `last` ended, is still to be made: it dropped nothing,
  /// and this is where it was let go, not where the pointer went next.
  private func moves(_ drop: ListDrop, after last: Release) -> Bool {
    guard !last.dropped else { return false }
    guard let point = last.point else { return true }
    return hypot(drop.point.x - point.x, drop.point.y - point.y) <= Self.releaseSlop
  }

  /// Ends the drag at `point`, where an event said the button came up, else at the pointer.
  private func release(at point: CGPoint?) {
    // Reading the queue can run the timer, which may have ended it already.
    guard dragged != nil, let store else { return }
    // Decided now, moved after: the List's `.onMove`, should it come, sees the release first.
    let dropped = store.terminalDrag.ended(at: point ?? mouse.location())
    lastRelease = Release(
      time: ProcessInfo.processInfo.systemUptime, point: point, dropped: dropped)
    stop()
  }

  /// The timer sees a release the List's drag took; the monitor one that reached the app, with
  /// where it was.
  private func watchForRelease() {
    let poll = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.follow() }
    }
    RunLoop.main.add(poll, forMode: .common)
    self.poll = poll
    mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
      nonisolated(unsafe) let up = event
      MainActor.assumeIsolated { self?.release(at: up.screenLocation) }
      return event
    }
  }

  private func stop() {
    SidebarTableDragImage.title = nil
    poll?.invalidate()
    poll = nil
    if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
    mouseUpMonitor = nil
    if let store, store.terminalDrag.source == dragged { store.terminalDrag.cancel() }
    dragged = nil
  }
}

extension NSEvent {
  /// Where the event happened on screen.
  @MainActor fileprivate var screenLocation: CGPoint {
    window?.convertPoint(toScreen: locationInWindow) ?? locationInWindow
  }
}

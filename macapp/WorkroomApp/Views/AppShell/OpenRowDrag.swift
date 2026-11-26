import AppKit

/// Follows a drag begun on an Open section row to its release (#819). The section is a `List`,
/// whose table tracks the mouse itself once a press on a row reaches it (`NSTableView.mouseDown`
/// runs its own event loop): the row's `DragGesture` reports the drag's first move, then no more
/// moves and no release, so the drag would never end (measured in the VM; the retired Terminals
/// list's `SidebarRowDrag` worked round the same table). From that first report this reads the
/// pointer on a timer, which runs in the table's event-tracking run-loop mode too, and hands each
/// move and the one release to the row's drag as its gesture's own reports would be.
@MainActor
final class OpenRowDrag {
  /// The mouse, as the drag reads it: tests give their own.
  struct Mouse {
    var location: @MainActor () -> CGPoint = { NSEvent.mouseLocation }
    var isDown: @MainActor () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
  }

  /// Where the drag is, as a `.global` `DragGesture` reports it (the window's top-left space, y
  /// down), and on screen, as the window's drag session reads it.
  struct Report: Equatable {
    let location: CGPoint
    let translation: CGSize
    let screen: CGPoint
  }

  static let shared = OpenRowDrag()

  /// How often the pointer is read while the table holds the mouse: about a display frame.
  static let interval: TimeInterval = 1.0 / 60

  private let mouse: Mouse
  private let startsTimer: Bool
  private var item: OpenSectionItem?
  /// The first report's place, in the gesture's space and on screen, which maps one to the other.
  private var start = CGPoint.zero
  private var startGlobal = CGPoint.zero
  private var startScreen = CGPoint.zero
  private var last: CGPoint?
  private var onMove: ((Report) -> Void)?
  private var onEnd: ((Report) -> Void)?
  private var timer: Timer?

  /// `startsTimer`: false in tests, which call `poll` themselves.
  init(mouse: Mouse = Mouse(), startsTimer: Bool = true) {
    self.mouse = mouse
    self.startsTimer = startsTimer
  }

  /// Whether a drag of `item` is being followed.
  func isFollowing(_ item: OpenSectionItem) -> Bool { self.item == item }

  /// Row `item`'s gesture reported a move to `location` (`.global`), begun at `startLocation`.
  /// The first report starts following the pointer and is passed on; later ones are the timer's to
  /// make, so a gesture that does keep reporting moves nothing twice. A drag of another row still
  /// followed ends first.
  func changed(
    _ item: OpenSectionItem, location: CGPoint, startLocation: CGPoint,
    onMove: @escaping (Report) -> Void, onEnd: @escaping (Report) -> Void
  ) {
    guard self.item != item else { return }
    if self.item != nil { finish(at: mouse.location()) }
    self.item = item
    self.onMove = onMove
    self.onEnd = onEnd
    start = startLocation
    startGlobal = location
    startScreen = mouse.location()
    last = startScreen
    onMove(report(at: startScreen))
    if startsTimer {
      let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.poll() }
      }
      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
    }
  }

  /// Row `item`'s gesture ended, when it does get the release: the drag ends there, once.
  func ended(_ item: OpenSectionItem) {
    guard self.item == item else { return }
    finish(at: mouse.location())
  }

  /// Reads the pointer: a move is passed on, and the button up ends the drag where it is.
  func poll() {
    guard item != nil else { return }
    let point = mouse.location()
    guard mouse.isDown() else { return finish(at: point) }
    guard point != last else { return }
    last = point
    onMove?(report(at: point))
  }

  private func finish(at point: CGPoint) {
    let onEnd = onEnd
    timer?.invalidate()
    timer = nil
    let report = report(at: point)
    item = nil
    onMove = nil
    self.onEnd = nil
    onEnd?(report)
  }

  /// `screen` (y up) in the gesture's space (y down), from the first report's pair.
  private func report(at screen: CGPoint) -> Report {
    let location = CGPoint(
      x: startGlobal.x + (screen.x - startScreen.x), y: startGlobal.y - (screen.y - startScreen.y))
    return Report(
      location: location,
      translation: CGSize(width: location.x - start.x, height: location.y - start.y),
      screen: screen)
  }
}

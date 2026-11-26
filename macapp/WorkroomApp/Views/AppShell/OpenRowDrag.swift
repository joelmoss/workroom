import AppKit

/// Follows a drag begun on an Open section row to its release (#819). The section is a `List`,
/// whose table tracks the mouse itself once a press on a row reaches it (`NSTableView.mouseDown`
/// runs its own event loop): the row's `DragGesture` reports the drag's first move, then no more
/// moves and no release, so the drag would never end (measured in the VM; the retired Terminals
/// list's `SidebarRowDrag` worked round the same table). The table can take the mouse before even
/// that first move (a quick, straight drag in the VM got none), so the row's gesture reports from
/// the press (`minimumDistance: 0`) and this arms there. From then it reads the pointer on a timer,
/// which runs in the table's event-tracking run-loop mode too. Once the pointer has travelled
/// `threshold` it hands each move, and then the release, to the row's drag as its gesture's own
/// reports would be; a press let go short of that is a click and makes no drag.
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

  /// How far the pointer travels from the press before it is a drag, as a `DragGesture`'s
  /// default `minimumDistance`; less is a click's wobble.
  static let threshold: CGFloat = 6

  private let mouse: Mouse
  private let startsTimer: Bool
  private var item: OpenSectionItem?
  /// The first report's place, in the gesture's space and on screen, which maps one to the other.
  private var start = CGPoint.zero
  private var startGlobal = CGPoint.zero
  private var startScreen = CGPoint.zero
  private var last: CGPoint?
  /// The pointer has travelled `threshold`: its moves and release are passed on.
  private var started = false
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
  /// The first report, the press's, arms the drag; later ones are the timer's to make, so a
  /// gesture that does keep reporting moves nothing twice. A report once the button is up arms
  /// nothing: it is the gesture's own, queued while the table held the mouse and delivered after
  /// the release, of a drag that has already ended. A drag of another row still followed ends
  /// first.
  func changed(
    _ item: OpenSectionItem, location: CGPoint, startLocation: CGPoint,
    onMove: @escaping (Report) -> Void, onEnd: @escaping (Report) -> Void
  ) {
    guard self.item != item, mouse.isDown() else { return }
    if self.item != nil { finish(at: mouse.location()) }
    self.item = item
    self.onMove = onMove
    self.onEnd = onEnd
    start = startLocation
    startGlobal = location
    startScreen = mouse.location()
    last = startScreen
    started = false
    advance(to: startScreen)
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
    advance(to: point)
  }

  /// Passes on a move to `point` once the pointer has travelled `threshold` from the press.
  private func advance(to point: CGPoint) {
    let report = report(at: point)
    if !started {
      guard hypot(report.translation.width, report.translation.height) >= Self.threshold
      else { return }
      started = true
    }
    onMove?(report)
  }

  /// Ends the drag at `point`: a move there first when the pointer got past the last read, so the
  /// drop and the reorder are decided where it was let go. A press let go short of `threshold` is
  /// a click and ends with nothing passed on; one let go past it is a drag though no read saw it
  /// travel (a quick drag's move and release can fall between two reads).
  private func finish(at point: CGPoint) {
    let onMove = onMove
    let onEnd = onEnd
    let moved = point != last
    timer?.invalidate()
    timer = nil
    let report = report(at: point)
    let started =
      started || hypot(report.translation.width, report.translation.height) >= Self.threshold
    item = nil
    self.onMove = nil
    self.onEnd = nil
    self.started = false
    guard started else { return }
    if moved { onMove?(report) }
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

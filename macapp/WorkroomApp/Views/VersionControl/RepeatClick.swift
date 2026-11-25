import AppKit

/// The double-click gate behind the History, Changes and Files rows: the first click previews at
/// once, and the second click of a double-click persists. The system's own click count decides, so a
/// double-click is one by the user's double-click speed and the events' timestamps, never by when
/// the handler gets to run. The old gate timed the handlers (< 0.35s), so a first click that opened a
/// heavy preview could delay the second handler past the window and turn a double-click into two
/// previews.
enum RepeatClick {
  /// Whether `event` is the second (or later) click of a multi-click. Only mouse-button events have a
  /// click count (reading it from any other event raises), so anything else is a first click.
  static func isRepeat(_ event: NSEvent?) -> Bool {
    guard let event else { return false }
    switch event.type {
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
      .otherMouseUp:
      return event.clickCount >= 2
    default:
      return false
    }
  }

  /// Whether the click being handled right now (in a tap gesture's action) is a repeat click.
  @MainActor static var isCurrentRepeat: Bool { isRepeat(NSApp.currentEvent) }
}

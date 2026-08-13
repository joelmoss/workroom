import AppKit
import XCTest

/// Shared "let the SwiftUI/AppKit run loop catch up" waiter for the WORKROOM-2B/2T/2S app-hang
/// regression suites (`ChangedFileRowInvalidationTests`, `HistoryRowInvalidationTests`,
/// `DiffViewerLazyRenderingTests`).
///
/// Pumps the run loop in short slices, forcing layout each time, until either `condition` returns
/// true or `seconds` elapses — whichever comes first. `condition` defaults to `{ false }`, which
/// makes this behave exactly like the old per-file busy-wait (always burns the full `seconds`):
/// some call sites are waiting out an unrelated async race (e.g. a status probe) rather than a
/// render they can observe, and forcing a fabricated condition onto those would be worse than no
/// condition at all. Pass a real condition wherever one exists (e.g. a `bodyPasses` counter tied
/// to the assertion that follows) to return as soon as the work is actually done instead of always
/// paying the ceiling.
extension XCTestCase {
  @MainActor
  func settle(_ view: NSView, seconds: TimeInterval = 0.6, until condition: () -> Bool = { false })
  {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      view.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      if condition() { break }
    }
    view.layoutSubtreeIfNeeded()
  }

  /// View-less overload for model/coordinator-layer tests with nothing to lay out — same
  /// poll-until-condition-or-ceiling mechanism, without the `layoutSubtreeIfNeeded()` half.
  @MainActor
  func settle(_ seconds: TimeInterval = 0.5, until condition: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
      if condition() { break }
    }
  }
}

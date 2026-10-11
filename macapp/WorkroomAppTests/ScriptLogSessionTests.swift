import Combine
import XCTest

@testable import Workroom

/// The setup overlay and its log observe a `ScriptLogSession` as an `ObservableObject`: a line or
/// the end of the run that doesn't publish leaves the log frozen and the overlay without its
/// Dismiss button, withholding the new workroom's terminal.
final class ScriptLogSessionTests: XCTestCase {
  func testAppendingAndFinishingPublish() {
    let session = ScriptLogSession(title: "Creating w", phase: "setup")
    var publishes = 0
    let subscription = session.objectWillChange.sink { publishes += 1 }
    defer { subscription.cancel() }

    session.append("installing")
    XCTAssertGreaterThan(publishes, 0, "a line must publish")
    let afterAppend = publishes
    session.finish(failure: "exit 1")
    XCTAssertGreaterThan(publishes, afterAppend, "the end of the run must publish")
  }
}

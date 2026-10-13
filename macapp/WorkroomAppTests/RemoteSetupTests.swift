import XCTest

@testable import Workroom

/// The setup sheets' shared parts: the poller that watches their waiting steps.
@MainActor
final class RemoteSetupTests: XCTestCase {
  private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
  }

  // Value: protects=a waiting setup step is checked again with growing gaps and the checks stop once
  // nothing waits or the sheet closes; fails_when=the backoff stops doubling, the loop outlives
  // isWaiting, or cancel leaves it running; why_new=the setup poll had no test (only ShellHost.poll
  // did); seam=the first and cap delays, so the test takes milliseconds; no_claim=the 3 s / 30 s values
  func testThePollerBacksOffWhileAStepWaitsAndStopsWhenDoneOrCancelled() async throws {
    let poller = SetupPoller(first: .milliseconds(10), cap: .milliseconds(40))
    let checks = Box<[ContinuousClock.Instant]>([])
    let waiting = Box(true)
    poller.start(
      while: { waiting.value },
      check: {
        checks.value.append(.now)
        if checks.value.count == 4 { waiting.value = false }
      })
    for _ in 0..<300 where poller.isPolling { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(poller.isPolling, "the poll outlived the last waiting step")
    XCTAssertEqual(checks.value.count, 4)
    // 10, 20, 40, 40 ms: the third gap is a doubled one, the last is held at the cap.
    let gaps = zip(checks.value.dropFirst(), checks.value).map { $0 - $1 }
    XCTAssertGreaterThanOrEqual(gaps[1], .milliseconds(39), "the gaps didn't grow: \(gaps)")
    XCTAssertGreaterThanOrEqual(gaps[2], .milliseconds(39), "\(gaps)")

    let after = Box(0)
    waiting.value = true
    poller.start(while: { waiting.value }, check: { after.value += 1 })
    poller.cancel()
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(after.value, 0, "a cancelled poll still checked")
    XCTAssertFalse(poller.isPolling)
  }
}

import XCTest

@testable import Workroom

/// Ordered event log an `actor` so concurrent test operations can append to it race-free.
private actor EventLog {
  private(set) var events: [String] = []
  private(set) var maxConcurrent = 0
  private var running = 0

  func append(_ event: String) {
    events.append(event)
  }

  func enter() {
    running += 1
    maxConcurrent = max(maxConcurrent, running)
  }

  func exit() {
    running -= 1
  }
}

final class JJSnapshotGateTests: XCTestCase {
  /// Every test builds its OWN gate (never `.shared`) so tests can't leak state into each other.
  private func makeGate() -> JJSnapshotGate { JJSnapshotGate() }

  func testSameProjectCallsNeverOverlap() async throws {
    let gate = makeGate()
    let log = EventLog()

    async let first: Void = try gate.run(projectRoot: "/p") {
      await log.enter()
      try await Task.sleep(nanoseconds: 50_000_000)
      await log.exit()
    }
    async let second: Void = try gate.run(projectRoot: "/p") {
      await log.enter()
      try await Task.sleep(nanoseconds: 50_000_000)
      await log.exit()
    }
    _ = try await (first, second)

    let maxConcurrent = await log.maxConcurrent
    XCTAssertEqual(maxConcurrent, 1, "same-project calls must never run concurrently")
  }

  func testDifferentProjectsRunConcurrently() async throws {
    let gate = makeGate()
    let log = EventLog()

    async let first: Void = try gate.run(projectRoot: "/a") {
      await log.enter()
      try await Task.sleep(nanoseconds: 50_000_000)
      await log.exit()
    }
    async let second: Void = try gate.run(projectRoot: "/b") {
      await log.enter()
      try await Task.sleep(nanoseconds: 50_000_000)
      await log.exit()
    }
    _ = try await (first, second)

    let maxConcurrent = await log.maxConcurrent
    XCTAssertEqual(maxConcurrent, 2, "different-project calls must not wait on each other")
  }

  func testCancelledBeforeTurnSkipsOperation() async throws {
    let gate = makeGate()
    let log = EventLog()

    // Occupies the gate for "/p" long enough for the second call to be cancelled before its turn.
    let first = Task {
      try await gate.run(projectRoot: "/p") {
        await log.append("first:start")
        try await Task.sleep(nanoseconds: 100_000_000)
        await log.append("first:end")
      }
    }
    try await Task.sleep(nanoseconds: 10_000_000)  // let `first` claim the gate

    let second = Task {
      try await gate.run(projectRoot: "/p") {
        await log.append("second:ran")  // must never happen — cancelled before its turn
      }
    }
    try await Task.sleep(nanoseconds: 20_000_000)  // still well before `first` finishes
    second.cancel()

    _ = try await first.value
    _ = try? await second.value

    let events = await log.events
    XCTAssertFalse(events.contains("second:ran"), "a call cancelled before its turn must not run")
    XCTAssertEqual(events, ["first:start", "first:end"])
  }

  func testChainWaitsForRealCompletionNotAbandonment() async throws {
    let gate = makeGate()
    let log = EventLog()

    // Models `withTimeout` abandoning a call: the caller stops waiting (cancels), but the
    // underlying operation is a black-box synchronous call that keeps running regardless —
    // exactly `JJSnapshotGate`'s documented contract for why `operation` must be un-timed.
    let first = Task {
      try? await gate.run(projectRoot: "/p") {
        await log.append("first:start")
        try? await Task.sleep(nanoseconds: 100_000_000)
        await log.append("first:end")
      }
    }
    try await Task.sleep(nanoseconds: 10_000_000)
    first.cancel()  // the caller gives up; the operation body above is NOT cancellation-aware

    // Queued right after `first` is cancelled — must still wait for `first`'s operation to
    // actually finish, not merely for the cancellation request.
    let second = Task {
      try await gate.run(projectRoot: "/p") {
        await log.append("second:start")
      }
    }

    _ = await first.value
    try await second.value

    let events = await log.events
    XCTAssertEqual(events, ["first:start", "first:end", "second:start"])
  }

  /// The tail chain swallows a predecessor's thrown error (`try? await task.value` in `run`) so the
  /// queue keeps flowing — prove a same-project call queued behind a THROWING predecessor still
  /// runs (and that the throwing call's own caller still observes its error).
  func testOperationThrowsStillAllowsNextQueuedCallToRun() async {
    let gate = makeGate()
    let log = EventLog()
    struct Boom: Error {}

    let first = Task {
      try await gate.run(projectRoot: "/p") {
        await log.append("first:start")
        throw Boom()
      }
    }
    do {
      _ = try await first.value
      XCTFail("expected Boom to propagate to the throwing call's own caller")
    } catch {
      XCTAssertTrue(error is Boom, "expected Boom, got \(error)")
    }

    try? await gate.run(projectRoot: "/p") {
      await log.append("second:ran")
    }

    let events = await log.events
    XCTAssertEqual(events, ["first:start", "second:ran"])
  }

  /// The self-healing ceiling (VCS-foundation eng-review follow-up): a predecessor that never
  /// completes (a genuine jj-lib wedge, not just slow) must not block the chain forever. A tiny
  /// injected `maxChainWait` proves a queued call gives up waiting once the ceiling elapses and
  /// runs its own operation anyway, rather than hanging for the test's (or a real predecessor's)
  /// entire lifetime.
  func testCeilingLetsQueueSelfHealPastAWedgedPredecessor() async throws {
    let gate = JJSnapshotGate(maxChainWait: 0.05)
    let log = EventLog()

    // Fire-and-forget: simulates a truly wedged native call. Never awaited directly by this test,
    // so the test's own runtime isn't tied to it.
    Task {
      try? await gate.run(projectRoot: "/p") {
        await log.append("first:start")
        try? await Task.sleep(nanoseconds: 60_000_000_000)  // far longer than this test can run
      }
    }
    try await Task.sleep(nanoseconds: 10_000_000)  // let `first` claim the gate first

    try await gate.run(projectRoot: "/p") {
      await log.append("second:ran")
    }

    let events = await log.events
    XCTAssertEqual(events, ["first:start", "second:ran"])
  }
}

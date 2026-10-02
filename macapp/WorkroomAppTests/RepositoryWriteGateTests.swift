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

final class RepositoryWriteGateTests: XCTestCase {
  /// Every test builds its OWN gate (never `.shared`) so tests can't leak state into each other.
  private func makeGate() -> RepositoryWriteGate { RepositoryWriteGate() }

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
    // exactly `RepositoryWriteGate`'s documented contract for why `operation` must be un-timed.
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
  /// completes (a genuinely wedged `git` process, not just slow) must not block the chain forever. A tiny
  /// injected `maxChainWait` proves a queued call gives up waiting once the ceiling elapses and
  /// runs its own operation anyway, rather than hanging for the test's (or a real predecessor's)
  /// entire lifetime.
  func testCeilingLetsQueueSelfHealPastAWedgedPredecessor() async throws {
    let gate = RepositoryWriteGate(maxChainWait: 0.05)
    let log = EventLog()

    // Fire-and-forget: simulates a truly wedged call. Never awaited directly by this test,
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

extension RepositoryWriteGateTests {
  func testCancelledMiddleWaiterCannotReleaseRunningPredecessor() async throws {
    let gate = RepositoryWriteGate(maxChainWait: 5)
    let location = try RepositoryLocation.remote(host: UUID(), path: "/same/path")
    let log = EventLog()
    let entered = expectation(description: "native work started")
    let release = DispatchSemaphore(value: 0)
    let first = Task {
      try await gate.run(repository: location) {
        await log.append("A:start")
        try await runBlocking {
          entered.fulfill()
          release.wait()
        }
        await log.append("A:end")
      }
    }
    await fulfillment(of: [entered], timeout: 2)
    let second = Task { try await gate.run(repository: location) { await log.append("B") } }
    try await Task.sleep(nanoseconds: 30_000_000)
    second.cancel()
    let third = Task { try await gate.run(repository: location) { await log.append("C") } }
    try await Task.sleep(nanoseconds: 50_000_000)
    let beforeRelease = await log.events
    XCTAssertEqual(beforeRelease, ["A:start"])
    release.signal()
    try await first.value
    _ = try? await second.value
    try await third.value
    let final = await log.events
    XCTAssertEqual(final, ["A:start", "A:end", "C"])
  }

  func testSamePathOnDifferentHostsDoesNotShareOrdering() async throws {
    let gate = RepositoryWriteGate()
    let one = try RepositoryLocation.remote(host: UUID(), path: "/repo")
    let two = try RepositoryLocation.remote(host: UUID(), path: "/repo")
    let log = EventLog()
    async let first: Void = gate.run(repository: one) {
      await log.enter()
      try await Task.sleep(nanoseconds: 80_000_000)
      await log.exit()
    }
    async let second: Void = gate.run(repository: two) {
      await log.enter()
      try await Task.sleep(nanoseconds: 80_000_000)
      await log.exit()
    }
    _ = try await (first, second)
    let maximum = await log.maxConcurrent
    XCTAssertEqual(maximum, 2)
  }
}

extension RepositoryWriteGateTests {
  func testTimedOutNativeCallKeepsItsTailUntilActualCompletion() async throws {
    let location = try RepositoryLocation.remote(host: UUID(), path: "/repo")
    let gate = RepositoryWriteGate(maxChainWait: 5)
    let log = EventLog()
    let started = expectation(description: "native operation started")
    let release = DispatchSemaphore(value: 0)
    let first = Task {
      try await withTimeout(seconds: 0.05) {
        try await gate.run(repository: location) {
          await log.append("A:start")
          try await runBlocking {
            started.fulfill()
            release.wait()
          }
          await log.append("A:end")
        }
      }
    }
    await fulfillment(of: [started], timeout: 2)
    do {
      try await first.value
      XCTFail("wait should time out")
    } catch { XCTAssertTrue(error is VCSTimeoutError) }
    let second = Task { try await gate.run(repository: location) { await log.append("B") } }
    try await Task.sleep(nanoseconds: 30_000_000)
    let whileNativeIsRunning = await log.events
    XCTAssertEqual(whileNativeIsRunning, ["A:start"])
    release.signal()
    try await second.value
    let completed = await log.events
    XCTAssertEqual(completed, ["A:start", "A:end", "B"])
  }
}

extension RepositoryWriteGateTests {
  /// The `Task.detached` shield in `run(repository:)`. Every other blocking test here uses
  /// `runBlocking`, which ignores cancellation, so they stay green without the shield. An
  /// agent-routed git write DOES observe cancellation: unshielded, cancelling the caller throws out
  /// of its `Task.sleep`-like wait, releases the tail early, and lets the next write start while the
  /// agent's `git` is still running. With the shield the operation runs to its own end first.
  func testCancelledCallKeepsTailUntilCancellationObservingOperationEnds() async throws {
    let gate = RepositoryWriteGate(maxChainWait: 5)
    let location = try RepositoryLocation.remote(host: UUID(), path: "/repo")
    let log = EventLog()
    let started = expectation(description: "operation started")
    let first = Task {
      try await gate.run(repository: location) {
        await log.append("A:start")
        started.fulfill()
        try await Task.sleep(nanoseconds: 300_000_000)
        await log.append("A:end")
      }
    }
    await fulfillment(of: [started], timeout: 2)
    first.cancel()
    let second = Task { try await gate.run(repository: location) { await log.append("B") } }
    _ = try? await first.value
    try await second.value
    let events = await log.events
    XCTAssertEqual(events, ["A:start", "A:end", "B"])
  }
}

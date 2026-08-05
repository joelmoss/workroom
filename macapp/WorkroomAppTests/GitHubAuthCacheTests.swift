import XCTest

@testable import Workroom

/// `GitHubAuthCache`'s four contracts: single-flight, freshness (including the shorter negative TTL),
/// the `force` guarantee, and what a `.keepPrior` non-answer does to the cache.
///
/// Every test injects millisecond TTLs, so none of them sleep for a minute to age a verdict.
final class GitHubAuthCacheTests: XCTestCase {
  // MARK: - Single-flight

  /// The reason this type exists: `AppStore` is per-window but the verdict is machine-global, so
  /// several windows asking at once must cost ONE `gh auth status`, not one each.
  func testConcurrentCallersShareOneProbe() async {
    let runner = CountingGHRunner(
      stdout: #"{"hosts":{"github.com":[{"state":"success","active":true}]}}"#,
      delay: .milliseconds(80))
    let cache = GitHubAuthCache()
    let resolver = WorkroomStatusResolver(runner: runner)

    let results = await withTaskGroup(of: GitHubCLIStatus?.self) { group in
      for _ in 0..<5 { group.addTask { await cache.status(resolver: resolver) } }
      var out: [GitHubCLIStatus?] = []
      for await r in group { out.append(r) }
      return out
    }

    XCTAssertEqual(runner.authCallCount, 1, "each waiter forked its own `gh auth status`")
    XCTAssertEqual(results.compactMap { $0 }, Array(repeating: .available, count: 5))
  }

  // MARK: - Freshness

  func testASecondCallInsideTheTTLDoesNotReprobe() async {
    let runner = CountingGHRunner(stdout: successJSON)
    let cache = GitHubAuthCache(ttl: .seconds(60))
    let resolver = WorkroomStatusResolver(runner: runner)

    _ = await cache.status(resolver: resolver)
    _ = await cache.status(resolver: resolver)

    XCTAssertEqual(runner.authCallCount, 1)
  }

  func testAStaleVerdictIsReprobed() async {
    let runner = CountingGHRunner(stdout: successJSON)
    let cache = GitHubAuthCache(ttl: .milliseconds(20))
    let resolver = WorkroomStatusResolver(runner: runner)

    _ = await cache.status(resolver: resolver)
    try? await Task.sleep(nanoseconds: 40_000_000)
    _ = await cache.status(resolver: resolver)

    XCTAssertEqual(runner.authCallCount, 2)
  }

  /// `.notAuthenticated` gets the SHORTER lease. It is both the alarming answer and the one every
  /// ambiguous result falls back to, and it gates the whole PR/CI lane — so it is re-confirmed
  /// quickly rather than trusted for the full minute.
  func testNotAuthenticatedIsReconfirmedOnTheShorterNegativeTTL() async {
    let runner = CountingGHRunner(stdout: #"{"hosts":{}}"#)
    let cache = GitHubAuthCache(ttl: .seconds(60), negativeTTL: .milliseconds(20))
    let resolver = WorkroomStatusResolver(runner: runner)

    let first = await cache.status(resolver: resolver)
    XCTAssertEqual(first, .notAuthenticated)
    try? await Task.sleep(nanoseconds: 40_000_000)
    _ = await cache.status(resolver: resolver)

    XCTAssertEqual(runner.authCallCount, 2, "a logout verdict was trusted past its negative TTL")
  }

  /// The other half of the asymmetry: a good verdict is NOT re-probed on the negative TTL's schedule,
  /// or the shortened lease would apply to everyone and multiply `gh` calls for no reason.
  func testAvailableKeepsTheFullTTL() async {
    let runner = CountingGHRunner(stdout: successJSON)
    let cache = GitHubAuthCache(ttl: .seconds(60), negativeTTL: .milliseconds(20))
    let resolver = WorkroomStatusResolver(runner: runner)

    _ = await cache.status(resolver: resolver)
    try? await Task.sleep(nanoseconds: 40_000_000)
    _ = await cache.status(resolver: resolver)

    XCTAssertEqual(runner.authCallCount, 1)
  }

  // MARK: - force

  func testForceBypassesAFreshVerdict() async {
    let runner = CountingGHRunner(stdout: successJSON)
    let cache = GitHubAuthCache(ttl: .seconds(60))
    let resolver = WorkroomStatusResolver(runner: runner)

    _ = await cache.status(resolver: resolver)
    _ = await cache.status(force: true, resolver: resolver)

    XCTAssertEqual(runner.authCallCount, 2, "the Refresh button reused a cached answer")
  }

  /// The contract Codex flagged as unspecified. A forced caller must not be handed the result of a
  /// probe that started BEFORE the user pressed Refresh — otherwise Refresh silently doesn't refresh.
  func testForceDoesNotJoinAnInFlightNonForcedProbe() async {
    let runner = CountingGHRunner(stdout: successJSON, delay: .milliseconds(120))
    let cache = GitHubAuthCache(ttl: .seconds(60))
    let resolver = WorkroomStatusResolver(runner: runner)

    let background = Task { await cache.status(resolver: resolver) }
    // Let the non-forced probe get in flight before forcing.
    try? await Task.sleep(nanoseconds: 30_000_000)
    _ = await cache.status(force: true, resolver: resolver)
    _ = await background.value

    XCTAssertEqual(runner.authCallCount, 2, "force joined a probe that predated the request")
  }

  // MARK: - keepPrior

  /// A non-answer must not become a verdict, and — the sticky half of the original bug — must not
  /// refresh the freshness clock either, or one blip would suppress its own repair for a full TTL.
  func testKeepPriorReturnsNilWhenNothingIsCached() async {
    let runner = CountingGHRunner(signalled: true)
    let cache = GitHubAuthCache()
    let resolver = WorkroomStatusResolver(runner: runner)

    let status = await cache.status(resolver: resolver)

    XCTAssertNil(status, "a killed probe produced a verdict out of nothing")
  }

  func testKeepPriorPreservesThePriorVerdictAndDoesNotStamp() async {
    let runner = SwitchableGHRunner(stdout: #"{"hosts":{}}"#)
    let cache = GitHubAuthCache(ttl: .seconds(60), negativeTTL: .milliseconds(20))
    let resolver = WorkroomStatusResolver(runner: runner)

    let first = await cache.status(resolver: resolver)
    XCTAssertEqual(first, .notAuthenticated)
    // Now every probe comes back killed. The prior verdict must survive...
    runner.becomeSignalled()
    try? await Task.sleep(nanoseconds: 40_000_000)
    let afterBlip = await cache.status(resolver: resolver)
    XCTAssertEqual(afterBlip, .notAuthenticated, "a killed probe erased a true verdict")
    // ...and must NOT have been re-stamped, so the very next call probes again rather than sitting on
    // a non-answer until the TTL expires.
    let callsSoFar = runner.authCallCount
    _ = await cache.status(resolver: resolver)
    XCTAssertGreaterThan(
      runner.authCallCount, callsSoFar, "a non-answer refreshed the freshness clock")
  }

  // MARK: - Isolation

  /// Two `GitHubAuthCache` instances share nothing. This is the whole reason it is an instance rather
  /// than the `static let shared` actor `VCSToolVersionCache` uses: `make app-test` runs classes in
  /// parallel, and static state would let one test's fake runner answer another test's probe.
  func testTwoInstancesDoNotShareState() async {
    let runnerA = CountingGHRunner(stdout: successJSON)
    let runnerB = CountingGHRunner(stdout: #"{"hosts":{}}"#)
    let cacheA = GitHubAuthCache()
    let cacheB = GitHubAuthCache()

    let a = await cacheA.status(resolver: WorkroomStatusResolver(runner: runnerA))
    let b = await cacheB.status(resolver: WorkroomStatusResolver(runner: runnerB))

    XCTAssertEqual(a, .available)
    XCTAssertEqual(b, .notAuthenticated)
    XCTAssertEqual(runnerA.authCallCount, 1)
    XCTAssertEqual(runnerB.authCallCount, 1)
  }

  private let successJSON = #"{"hosts":{"github.com":[{"state":"success","active":true}]}}"#
}

/// Counts `gh auth status` invocations so single-flight and TTL behaviour are asserted on the number
/// of real probes, not just on the returned value.
private final class CountingGHRunner: StatusCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private let stdout: String
  private let delay: Duration?
  private let signalled: Bool

  init(stdout: String = "", delay: Duration? = nil, signalled: Bool = false) {
    self.stdout = stdout
    self.delay = delay
    self.signalled = signalled
  }

  var authCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    guard executable == "gh", args.contains("auth") else {
      return CommandResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
    }
    lock.lock()
    count += 1
    lock.unlock()
    if let delay { try? await Task.sleep(for: delay) }
    if signalled {
      return CommandResult(stdout: "", stderr: "", exitCode: 9, timedOut: false, signaled: true)
    }
    return CommandResult(stdout: stdout, stderr: "", exitCode: 0, timedOut: false)
  }
}

/// Like `CountingGHRunner` but can flip to returning killed results mid-test, so "a good verdict
/// survives a later blip" is exercised in one cache instance.
private final class SwitchableGHRunner: StatusCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var signalled = false
  private let stdout: String

  init(stdout: String) { self.stdout = stdout }

  var authCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func becomeSignalled() {
    lock.lock()
    signalled = true
    lock.unlock()
  }

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    guard executable == "gh", args.contains("auth") else {
      return CommandResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
    }
    lock.lock()
    count += 1
    let killed = signalled
    lock.unlock()
    if killed {
      return CommandResult(stdout: "", stderr: "", exitCode: 9, timedOut: false, signaled: true)
    }
    return CommandResult(stdout: stdout, stderr: "", exitCode: 0, timedOut: false)
  }
}

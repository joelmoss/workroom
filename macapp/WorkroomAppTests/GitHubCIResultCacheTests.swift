import WorkroomSystem
import XCTest

@testable import Workroom

private final class CIClock: @unchecked Sendable {
  private let lock = NSLock()
  private var instant = ContinuousClock.now
  func now() -> ContinuousClock.Instant { lock.withLock { instant } }
  func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}

private actor CICommandProbe: StatusCommandRunning {
  private(set) var calls = 0
  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    calls += 1
    return CommandResult(
      stdout: #"{"data":{"repository":{"object":{"statusCheckRollup":{"state":"SUCCESS"}}}}}"#,
      stderr: "", exitCode: 0, timedOut: false)
  }
}

final class GitHubCIResultCacheTests: XCTestCase {
  private let repo = GitHubRepository(host: "github.com", owner: "fixture", name: "status")!

  private func ticket(
    _ cache: GitHubCIResultCache, repository: GitHubRepository? = nil,
    commit: String = "1234567", force: Bool = false
  ) async throws -> GitHubCIResultCache.Ticket {
    switch await cache.lookup(repository: repository ?? repo, commit: commit, force: force) {
    case .probe(let ticket): return ticket
    case .cached: throw NSError(domain: "unexpected cached result", code: 1)
    }
  }

  private func cached(
    _ cache: GitHubCIResultCache, commit: String = "1234567"
  ) async -> CIResolution? {
    switch await cache.lookup(repository: repo, commit: commit, force: false) {
    case .cached(let result): return result.resolution
    case .probe: return nil
    }
  }

  func testCacheIsScopedToRepositoryAndCommitAndExpires() async throws {
    let clock = CIClock()
    let cache = GitHubCIResultCache(now: { clock.now() })
    let issued = try await ticket(cache)
    await cache.record(.state(.passing), for: issued, cancelled: false)
    let first = await cached(cache)
    XCTAssertEqual(first, .state(.passing))
    _ = try await ticket(cache, commit: "abcdef0")
    _ = try await ticket(
      cache, repository: GitHubRepository(host: "github.example", owner: "fixture", name: "status"))
    _ = try await ticket(
      cache, repository: GitHubRepository(host: "github.com", owner: "other", name: "status"))
    clock.advance(.seconds(299))
    let stillFresh = await cached(cache)
    XCTAssertEqual(stillFresh, .state(.passing))
    clock.advance(.seconds(1))
    _ = try await ticket(cache)
  }

  func testForceReplacesFreshResultAndOlderInFlightAnswersCannotOverwriteIt() async throws {
    let cache = GitHubCIResultCache()
    let old = try await ticket(cache)
    let sibling = try await ticket(cache)
    await cache.record(.state(.passing), for: sibling, cancelled: false)
    let forced = try await ticket(cache, force: true)
    await cache.record(.state(.failing), for: forced, cancelled: false)
    await cache.record(.state(.passing), for: old, cancelled: false)
    let result = await cached(cache)
    XCTAssertEqual(result, .state(.failing))
  }

  func testAnOrdinaryCompletionCanPopulateTheCacheWhileItsSiblingIsRunning() async throws {
    let cache = GitHubCIResultCache()
    let first = try await ticket(cache)
    let second = try await ticket(cache)
    await cache.record(.state(.running), for: first, cancelled: false)
    let result = await cached(cache)
    XCTAssertEqual(result, .state(.running))
    await cache.record(.state(.passing), for: second, cancelled: false)
    let completed = await cached(cache)
    XCTAssertEqual(completed, .state(.passing))
  }

  func testCancelledAndTransientResultsDoNotBecomeFreshAnswers() async throws {
    let cache = GitHubCIResultCache()
    let cancelled = try await ticket(cache)
    await cache.record(.state(.passing), for: cancelled, cancelled: true)
    let transient = try await ticket(cache)
    await cache.record(.keepPrior, for: transient, cancelled: false)
    let absent = try await ticket(cache)
    await cache.record(.absent, for: absent, cancelled: false)
    let result = await cached(cache)
    XCTAssertEqual(result, .absent, "a settled absence is still a cacheable CI fact")
  }

  @MainActor
  func testWindowsShareFactsOnlyWithinTheirProjectStore() async {
    let shared = ProjectStore()
    let probe = CICommandProbe()
    let first = AppStore(projectStore: shared)
    let second = AppStore(projectStore: shared)
    let isolated = AppStore()
    for store in [first, second, isolated] {
      store.statusResolver = WorkroomStatusResolver(
        runner: probe, ciCache: store.statusResolver.ciCache)
    }
    _ = await first.statusResolver.resolveCI(repo: repo, commit: "1234567")
    _ = await second.statusResolver.resolveCI(repo: repo, commit: "1234567")
    let sharedCalls = await probe.calls
    XCTAssertEqual(sharedCalls, 1, "windows must reuse the shared ProjectStore's CI fact")
    _ = await isolated.statusResolver.resolveCI(repo: repo, commit: "1234567")
    let isolatedCalls = await probe.calls
    XCTAssertEqual(isolatedCalls, 2, "an isolated store must not inherit another store's cache")
  }
}

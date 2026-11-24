import Synchronization
import WorkroomSystem
import XCTest

@testable import Workroom

final class GitRepositoryProbeTests: XCTestCase {
  private let repo = GitHubRepository(host: "github.com", owner: "octo", name: "repo")!

  /// A create without gh (a remote provider's needs none) reads the repository from the project's
  /// own origin remote (#260); a project with no origin, or git failing, has none.
  func testOriginRepositoryReadsGitAlone() async {
    let runner = RecordingStatusRunner { _, _ in ok("git@github.com:octo/repo.git\n") }
    let found = await GitRepositoryProbe(runner: runner).originRepository(in: "/proj")
    XCTAssertEqual(found, repo)
    XCTAssertEqual(runner.calls.first?.dir, "/proj")
    XCTAssertEqual(runner.calls.first?.args, ["remote", "get-url", "origin"])
    let none = await GitRepositoryProbe(
      runner: MockStatusRunner { _, _ in
        CommandResult(
          stdout: "", stderr: "error: No such remote 'origin'", exitCode: 2, timedOut: false)
      }
    ).originRepository(in: "/proj")
    XCTAssertNil(none)
  }

  /// A remote create reads the project's remotes to tell `upstream/main` from an origin branch.
  func testRemoteNamesListsGitRemotes() async {
    let names = await GitRepositoryProbe(
      runner: MockStatusRunner { _, args in
        XCTAssertEqual(args, ["remote"])
        return ok("origin\nupstream\n")
      }
    ).remoteNames(in: "/proj")
    XCTAssertEqual(names, ["origin", "upstream"])
  }

  /// A remote create checks origin has the project's base branch: `ls-remote --exit-code` exits 2
  /// only for no match, so anything else (offline, no credentials) is left undecided.
  func testOriginHasBranchReadsLsRemotesExitCode() async {
    func ask(_ code: Int32) async -> Bool? {
      await GitRepositoryProbe(
        runner: MockStatusRunner { _, args in
          XCTAssertEqual(
            args, ["ls-remote", "--exit-code", "--heads", "origin", "refs/heads/develop"])
          return CommandResult(stdout: "", stderr: "", exitCode: code, timedOut: false)
        }
      ).originHasBranch("develop", in: "/proj")
    }
    let found = await ask(0)
    let missing = await ask(2)
    let unknown = await ask(128)
    XCTAssertEqual(found, true)
    XCTAssertEqual(missing, false)
    XCTAssertNil(unknown)
  }

  // MARK: - A read that outruns its bound (#812)

  /// Value: protects=a slow but live path resolving when every read of it takes a little longer
  /// than the bound, so each lands in the caller's backoff gap (#812); fails_when=a late result is
  /// dropped, so the next try starts a fresh read that times out again; why_new=#812;
  /// seam=`blockingRead`, with an injected read twice the bound (scaled down); no_claim=a real mount
  func testAReadThatOutrunsItsBoundIsKeptForTheNextTry() async throws {
    let key = "late-read-test\u{0}\(UUID().uuidString)"
    let reads = Mutex(0)
    func read() async -> String? {
      await GitRepositoryProbe.blockingRead(key, timeout: 0.1) {
        reads.withLock { $0 += 1 }
        Thread.sleep(forTimeInterval: 0.2)
        return "resolved"
      }
    }
    let first = await read()
    XCTAssertNil(first, "the first try outruns the bound")
    try await Task.sleep(for: .milliseconds(250))  // the backoff gap: the read lands in it
    let start = ContinuousClock.now
    let second = await read()
    XCTAssertEqual(second, "resolved", "the next try gets the late result")
    XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(50), "at once")
    XCTAssertEqual(reads.withLock { $0 }, 1, "without a new read")
  }

  /// A read of `key` on `reads` under a 0.1 s bound, taking `takes` and answering `answer`,
  /// counted in `count`.
  private func read(
    _ reads: BlockingReads, _ key: String, takes: Duration, answer: Int, count: Counter
  ) async -> Int? {
    await reads.read(key, timeout: 0.1) {
      count.bump()
      try await Task.sleep(for: takes)
      return answer
    } as? Int
  }

  /// Value: protects=a kept late result never answering past its lifetime, and the newest landing
  /// replacing it (#812); fails_when=a kept result is served stale, or an older one outlives a newer
  /// read; why_new=#812; seam=`BlockingReads` with a scaled-down lifetime; no_claim=a real mount
  func testAKeptResultExpiresAndTheNewestLandingReplacesIt() async throws {
    let reads = BlockingReads(keepFor: .milliseconds(400))
    let count = Counter()
    let slow = Duration.milliseconds(200)
    let lateFirst = await read(reads, "k", takes: slow, answer: 1, count: count)
    XCTAssertNil(lateFirst)
    try await Task.sleep(for: .milliseconds(150))  // landed at 0.2 s
    let kept = await read(reads, "k", takes: slow, answer: 9, count: count)
    XCTAssertEqual(kept, 1, "kept within its lifetime")
    try await Task.sleep(for: .milliseconds(500))  // past it
    let fresh = await read(reads, "k", takes: slow, answer: 2, count: count)
    XCTAssertNil(fresh, "an expired result is not served: a fresh read starts, and outruns too")
    XCTAssertEqual(count.value, 2)
    try await Task.sleep(for: .milliseconds(150))
    let newer = await read(reads, "k", takes: slow, answer: 9, count: count)
    XCTAssertEqual(newer, 2, "the newer late landing replaced the older")
    try await Task.sleep(for: .milliseconds(500))
    // An in-time landing clears the key: the next ask reads again.
    let inTime = await read(reads, "k", takes: .zero, answer: 3, count: count)
    XCTAssertEqual(inTime, 3)
    let again = await read(reads, "k", takes: .zero, answer: 4, count: count)
    XCTAssertEqual(again, 4, "an in-time result is not kept")
    XCTAssertEqual(count.value, 4)
  }

  /// Value: protects=the kept-results table staying bounded, as it is keyed per path (#812);
  /// fails_when=every late path is kept, however many; why_new=#812; seam=`BlockingReads` with a
  /// capacity of two; no_claim=the production capacity
  func testKeptResultsAreBoundedOldestFirst() async throws {
    let reads = BlockingReads(capacity: 2)
    let count = Counter()
    for (i, key) in ["a", "b", "c"].enumerated() {
      _ = await read(reads, key, takes: .milliseconds(200), answer: i, count: count)
      try await Task.sleep(for: .milliseconds(150))  // landed, in order
    }
    let b = await read(reads, "b", takes: .zero, answer: 9, count: count)
    let c = await read(reads, "c", takes: .zero, answer: 9, count: count)
    XCTAssertEqual(b, 1)
    XCTAssertEqual(c, 2)
    XCTAssertEqual(count.value, 3, "the two newest were kept")
    let a = await read(reads, "a", takes: .zero, answer: 9, count: count)
    XCTAssertEqual(a, 9, "the oldest was dropped, so it is read again")
  }

  /// How many reads started.
  final class Counter: Sendable {
    private let count = Mutex(0)
    func bump() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
  }
}

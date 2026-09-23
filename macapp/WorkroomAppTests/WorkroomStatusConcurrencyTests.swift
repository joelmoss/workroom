import XCTest

@testable import Workroom

/// Counts in-flight `workingStatus` calls and records the peak seen — the invariant
/// `AppStore.runLocalSweep`'s `cap`-bounded `withTaskGroup` fan-out must hold, and had ZERO test
/// coverage before this file (confirmed by grep: no hits for `runLocalSweep`/`localConcurrency` in
/// this test target). Shared by any status double that needs to prove it never over-runs.
private final class InFlightCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var current = 0
  private(set) var peak = 0

  func enter() {
    lock.lock()
    current += 1
    peak = max(peak, current)
    lock.unlock()
  }
  func leave() {
    lock.lock()
    current -= 1
    lock.unlock()
  }
}

/// A `VCSWorkingStatusReading` double that holds briefly while counting concurrent callers — long enough
/// that more than `cap` probes would visibly overlap if the fan-out weren't actually bounded, short
/// enough the test doesn't feel it (8 items / cap 5 ⇒ two sequential batches of ~20ms).
private struct CountingGitStatus: VCSWorkingStatusReading {
  let counter: InFlightCounter
  func workingStatus(root: URL) throws -> WorkroomStatus {
    counter.enter()
    defer { counter.leave() }
    Thread.sleep(forTimeInterval: 0.02)
    return WorkroomStatus(dirty: false)
  }
}

/// Reports every tool as missing (exit 127) so `refreshGitHubCLI` resolves to "not available" and
/// the sweep's CI stage never fires a real `gh` process — this test is only about the LOCAL stage's
/// concurrency bound.
private struct MissingToolRunner: StatusCommandRunning {
  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    CommandResult(stdout: "", stderr: "", exitCode: CommandResult.commandNotFound, timedOut: false)
  }
}

/// Counts `gh repo view` (the repository lookup) and `gh api graphql` (a CI probe), and answers just
/// enough for the CI stage to run: `gh auth` available, a branch, a sha, and a repository named after
/// the directory the lookup ran in — so a test can tell WHICH project a CI query was built for.
/// `lookupResult` replaces the lookup's answer (e.g. a timeout).
private final class LookupCountingRunner: StatusCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var _lookups = 0
  private var _queries: [String] = []
  private let lookupResult: CommandResult?
  var lookups: Int { lock.withLock { _lookups } }
  var queries: [String] { lock.withLock { _queries } }

  init(lookupResult: CommandResult? = nil) { self.lookupResult = lookupResult }

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    func ok(_ stdout: String) -> CommandResult {
      CommandResult(stdout: stdout, stderr: "", exitCode: 0, timedOut: false)
    }
    if executable == "gh", args.contains("auth") {
      return ok("github.com\n  \u{2713} Logged in to github.com account test")
    }
    if args.contains("symbolic-ref") { return ok("main") }
    if args.contains("rev-parse") { return ok(String(repeating: "a", count: 40)) }
    if executable == "gh", args.prefix(2) == ["repo", "view"] {
      lock.withLock { _lookups += 1 }
      if let lookupResult { return lookupResult }
      let name = (directory as NSString).lastPathComponent
      return ok("https://github.com/acme/\(name)")
    }
    if executable == "gh", args.contains("graphql") {
      lock.withLock { _queries.append(args.first { $0.hasPrefix("query=") } ?? "") }
      return ok("")
    }
    return ok("")
  }
}

/// A `StatusCommandRunning` double that counts concurrent `gh` calls while returning just enough of
/// a real answer to keep `resolveCI`'s chain moving: `gh auth status` reports available (so the CI
/// stage's `githubCLIStatus == .available` gate opens at all), `git symbolic-ref`/`rev-parse` report
/// a plausible branch/sha (so `localCICommit` doesn't bail before the counted work
/// happens), and the final `gh api graphql` call returns an empty body — `classifyCheckRollup` reads
/// that as `.keepPrior` on a decode failure, which is fine: this test only cares about `counter.peak`.
private struct CountingGHRunner: StatusCommandRunning, @unchecked Sendable {
  let counter: InFlightCounter

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    counter.enter()
    defer { counter.leave() }
    try? await Task.sleep(nanoseconds: 20_000_000)
    if executable == "gh", args.contains("auth") {
      return CommandResult(
        stdout: "github.com\n  \u{2713} Logged in to github.com account test", stderr: "",
        exitCode: 0, timedOut: false)
    }
    if args.contains("symbolic-ref") {
      return CommandResult(stdout: "main", stderr: "", exitCode: 0, timedOut: false)
    }
    if args.contains("rev-parse") {
      return CommandResult(
        stdout: String(repeating: "a", count: 40), stderr: "", exitCode: 0, timedOut: false)
    }
    if args.contains("view") {  // `gh repo view --json url` — the repository lookup
      return CommandResult(
        stdout: "https://github.com/acme/repo", stderr: "", exitCode: 0, timedOut: false)
    }
    return CommandResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
  }
}

/// REGRESSION (Muxy test-practices review, filed in TODOS.md — "N-in-flight concurrency accounting
/// test for status sweeps"): `WorkroomStatusResolver.resolveGit`/`resolveJJ` called `GitProvider()`/
/// `RustJJProvider()` directly, bypassing any injection seam, so this invariant was untestable until
/// `GitStatusReading`/`JJStatusReading` existed. `testCISweepNeverExceedsItsConcurrencyCap` covers the
/// remaining half of that same entry: the `runCISweep` stage's own cap, over `resolveCI`/`gh`, which
/// already had an injectable `StatusCommandRunning` (see `GatedGHRunner` in `WorkroomStatusTests.swift`)
/// — the seam gap this file was filed for was only ever `resolveGit`/`resolveJJ`'s.
final class WorkroomStatusConcurrencyTests: XCTestCase {
  private var dirs: [String] = []

  override func tearDown() {
    for d in dirs { try? FileManager.default.removeItem(atPath: d) }
    dirs = []
    super.tearDown()
  }

  /// A throwaway, empty directory standing in for a project root — `resolveLocal`'s `fileExists`
  /// guard must pass, but nothing inside it is ever read (the injected double never touches disk).
  private func throwawayProject(_ name: String) -> Project {
    let path = NSTemporaryDirectory() + "wr-cap-\(name)-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    dirs.append(path)
    return Project(path: path, vcs: "git", workrooms: [])
  }

  /// More work items than the sweep's cap, across DIFFERENT projects (so `JJSnapshotGate`'s
  /// per-project serialization can't be mistaken for the thing bounding concurrency — these are all
  /// git anyway, which is never gated): asserts `runLocalSweep` never lets more than 5 local probes
  /// run at once, and that the fan-out actually overlaps at all (else this would pass even fully
  /// serial, proving nothing).
  @MainActor
  func testLocalSweepNeverExceedsItsConcurrencyCap() async {
    let store = AppStore()
    store.projects = (0..<8).map { throwawayProject("\($0)") }

    let counter = InFlightCounter()
    store.statusResolver = WorkroomStatusResolver(
      runner: MissingToolRunner(), gitStatus: CountingGitStatus(counter: counter))

    store.refreshWorkroomStatuses(force: true)
    await store.statusSweepTask?.value

    XCTAssertLessThanOrEqual(
      counter.peak, AppStore.localConcurrency,
      "runLocalSweep let more than its cap of \(AppStore.localConcurrency) local probes run at once"
    )
    XCTAssertGreaterThan(
      counter.peak, 1,
      "the fan-out never actually overlapped — this test would pass even against a fully serial "
        + "sweep, so it isn't proving the cap does any work")
  }

  /// The `runCISweep` half TODOS.md left open: same shape as the local-sweep test above, but over
  /// `resolveCI`/`gh`. 8 items across 8 distinct project roots (so each becomes CI-eligible in one
  /// pass, and the per-project repository prefetch — sequential by construction — can't be mistaken
  /// for the bound under test) must never run more than `ciConcurrency` (2) `gh`/`git` calls at once.
  @MainActor
  func testCISweepNeverExceedsItsConcurrencyCap() async throws {
    let store = AppStore()
    store.projects = (0..<8).map { throwawayProject("ci-\($0)") }
    RepositoryRouter.shared.replaceLocal(try await RepositoryRouter.prepare(store.projects))

    let ghCounter = InFlightCounter()
    // `dirty: false` (not counted here) only needs to make every item CI-eligible
    // (`workroomStatuses[sid]?.dirty != nil`) — the assertion below is entirely about `ghCounter`.
    store.statusResolver = WorkroomStatusResolver(
      runner: CountingGHRunner(counter: ghCounter),
      gitStatus: CountingGitStatus(counter: InFlightCounter()))

    store.refreshWorkroomStatuses(force: true)
    await store.statusSweepTask?.value

    XCTAssertLessThanOrEqual(
      ghCounter.peak, AppStore.ciConcurrency,
      "runCISweep let more than its cap of \(AppStore.ciConcurrency) CI probes run at once")
    XCTAssertGreaterThan(
      ghCounter.peak, 1,
      "the fan-out never actually overlapped — this test would pass even against a fully serial "
        + "sweep, so it isn't proving the cap does any work")
  }

  /// A throwaway project with `count` workrooms, each an existing directory.
  private func project(_ name: String, workrooms count: Int) -> Project {
    let root = throwawayProject(name)
    let workrooms = (0..<count).map { index -> Workroom in
      let path = root.path + "/w\(index)"
      try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
      return Workroom(name: "w\(index)", path: path, vcsName: "git", warnings: [])
    }
    return Project(path: root.path, vcs: "git", workrooms: workrooms)
  }

  /// D8: the CI sweep asks for a project's repository ONCE and hands the answer to every workroom of
  /// it. Each workroom gets its own `RepositoryGitHub`, so its per-instance lookup cannot span them —
  /// only the sweep's cache can. TWO projects (root + 2 workrooms each): one lookup PER project, and
  /// every CI query is built for its own project's repository — a cache keyed too coarsely would send
  /// project A's repository to project B's workrooms.
  @MainActor
  func testCISweepLooksUpTheRepositoryOncePerProject() async throws {
    let store = AppStore()
    let projects = [project("once-a", workrooms: 2), project("once-b", workrooms: 2)]
    store.projects = projects
    RepositoryRouter.shared.replaceLocal(try await RepositoryRouter.prepare(store.projects))

    let runner = LookupCountingRunner()
    store.statusResolver = WorkroomStatusResolver(
      runner: runner, gitStatus: CountingGitStatus(counter: InFlightCounter()))

    store.refreshWorkroomStatuses(force: true)
    await store.statusSweepTask?.value

    XCTAssertEqual(runner.lookups, 2, "expected one repository lookup per project")
    XCTAssertEqual(runner.queries.count, 6, "every root and workroom should get a CI probe")
    for project in projects {
      let name = (project.path as NSString).lastPathComponent
      let own = runner.queries.filter { $0.contains("name:\"\(name)\"") }
      XCTAssertEqual(own.count, 3, "project \(name) should get exactly its own 3 CI probes")
    }
  }

  /// D8 / D6: a transient failure of a project's lookup reaches EVERY workroom of it as `keepPrior` —
  /// one lookup, no CI probe (so nothing is blanked and nothing is guessed), and no workroom retries it.
  @MainActor
  func testCISweepSharesATransientLookupFailureAcrossWorkrooms() async throws {
    let store = AppStore()
    store.projects = [project("blip", workrooms: 3)]
    RepositoryRouter.shared.replaceLocal(try await RepositoryRouter.prepare(store.projects))

    let runner = LookupCountingRunner(
      lookupResult: CommandResult(
        stdout: "", stderr: "", exitCode: 15, timedOut: true, signaled: true))
    store.statusResolver = WorkroomStatusResolver(
      runner: runner, gitStatus: CountingGitStatus(counter: InFlightCounter()))

    store.refreshWorkroomStatuses(force: true)
    await store.statusSweepTask?.value

    XCTAssertEqual(runner.lookups, 1, "a failed lookup was retried by the project's workrooms")
    XCTAssertTrue(runner.queries.isEmpty, "a CI probe ran against an unresolved repository")
  }
}

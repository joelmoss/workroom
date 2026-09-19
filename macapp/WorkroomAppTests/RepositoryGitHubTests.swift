import XCTest

@testable import Workroom

/// Counts and records every command, optionally delaying each so concurrent probes overlap.
private final class GHRunner: StatusCommandRunning, @unchecked Sendable {
  struct Call: Equatable {
    let exe: String
    let args: [String]
    let dir: String
  }

  private let handler: @Sendable (_ exe: String, _ args: [String]) -> CommandResult
  private let delay: UInt64
  private let lock = NSLock()
  private var _calls: [Call] = []
  var calls: [Call] {
    lock.lock()
    defer { lock.unlock() }
    return _calls
  }
  /// `gh repo view` — the repository lookup.
  var lookups: [Call] { calls.filter { $0.exe == "gh" && $0.args.prefix(2) == ["repo", "view"] } }

  init(
    delay: UInt64 = 0,
    _ handler: @escaping @Sendable (_ exe: String, _ args: [String]) -> CommandResult
  ) {
    self.delay = delay
    self.handler = handler
  }

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    lock.lock()
    _calls.append(Call(exe: executable, args: args, dir: directory))
    lock.unlock()
    if delay > 0 {
      // The real runner SIGKILLs a child whose task is cancelled and returns a signalled result; a
      // double that swallowed cancellation would pass a test whose whole point is cancellation.
      do { try await Task.sleep(nanoseconds: delay) } catch {
        return CommandResult(stdout: "", stderr: "", exitCode: 9, timedOut: false, signaled: true)
      }
    }
    return handler(executable, args)
  }
}

private func ok(_ stdout: String) -> CommandResult {
  CommandResult(stdout: stdout, stderr: "", exitCode: 0, timedOut: false)
}
private func failed(_ stderr: String = "boom", exit: Int32 = 1) -> CommandResult {
  CommandResult(stdout: "", stderr: stderr, exitCode: exit, timedOut: false)
}

private let tip = "0123456789abcdef0123456789abcdef01234567"
private let passing =
  #"{"data":{"repository":{"object":{"statusCheckRollup":{"state":"SUCCESS"}}}}}"#
private let prJSON =
  #"[{"number":9,"title":"F","state":"OPEN","isDraft":false,"url":"u","reviewDecision":null}]"#
private let octoURL = "https://github.com/octo/repo\n"
private let octo = GitHubRepository(host: "github.com", owner: "octo", name: "repo")!

/// The default handler: a healthy repo with one PR and passing CI.
private func healthy(_ exe: String, _ args: [String]) -> CommandResult {
  switch exe {
  case "git": return args.contains("symbolic-ref") ? ok("main\n") : ok(tip + "\n")
  case "jj": return ok(tip + "\n")
  default:
    if args.prefix(2) == ["repo", "view"] { return ok(octoURL) }
    if args.contains("graphql") { return ok(passing) }
    if args.prefix(2) == ["pr", "checks"] { return ok(#"[{"name":"build","bucket":"pass"}]"#) }
    return ok(prJSON)
  }
}

final class RepositoryGitHubTests: XCTestCase {
  private func unique(_ tail: String) -> String {
    "/private/tmp/gh-\(UUID().uuidString)/\(tail)"
  }

  /// A registered LOCAL repository: `path` is the workroom, `shared` the project root.
  private func local(
    _ backend: RepositoryBackend, runner: GHRunner, github: GitHubRepository? = nil
  ) async throws -> (service: RepositoryGitHub, path: String, shared: String) {
    let shared = unique("proj")
    let path = shared + "/ws"
    let sharedLocation = try await RepositoryLocation.local(shared)
    let location = try await RepositoryLocation.local(path)
    let router = RepositoryRouter()
    try router.register(
      .init(location: location, backend: backend, sharedLocation: sharedLocation, github: github))
    let service = try router.registeredGitHub(
      for: location, resolver: WorkroomStatusResolver(runner: runner))
    return (service, location.path, sharedLocation.path)
  }

  /// A registered REMOTE repository whose path exists nowhere on this Mac.
  private func remote(
    _ backend: RepositoryBackend, runner: GHRunner, github: GitHubRepository? = octo
  ) throws -> RepositoryGitHub {
    let host = UUID()
    let shared = try RepositoryLocation.remote(host: host, path: "/srv/proj")
    let location = try RepositoryLocation.remote(host: host, path: "/srv/proj/ws")
    let router = RepositoryRouter()
    try router.register(
      .init(location: location, backend: backend, sharedLocation: shared, github: github))
    return try router.registeredGitHub(
      for: location, resolver: WorkroomStatusResolver(runner: runner))
  }

  // MARK: - Local hosts: behaviour is what it was

  /// git: the branch tip is read in the WORKROOM, the repository from the SHARED root, and the
  /// GitHub probe itself runs in neither.
  func testLocalGitCIReadsTipInWorkroomAndRepositoryFromSharedRoot() async throws {
    let runner = GHRunner(healthy)
    let (service, path, shared) = try await local(.git, runner: runner)
    let res = await service.ci(branch: "main")
    XCTAssertEqual(res, .state(.passing))
    let calls = runner.calls
    XCTAssertEqual(calls.first { $0.exe == "git" }?.dir, path)
    XCTAssertEqual(runner.lookups.first?.dir, shared)
    XCTAssertNotEqual(path, shared)
    XCTAssertEqual(calls.last { $0.args.contains("graphql") }?.dir, NSTemporaryDirectory())
  }

  /// jj: a secondary workspace has no `.git`. The bookmark tip is read in the workspace (jj resolves
  /// `@` from cwd), the repository from the project root, and no git is ever spawned.
  func testLocalJJCIReadsBookmarkTipInWorkspaceWithoutGit() async throws {
    let runner = GHRunner(healthy)
    let (service, path, shared) = try await local(.jj, runner: runner)
    let res = await service.ci(branch: "feature/login")
    XCTAssertEqual(res, .state(.passing))
    let calls = runner.calls
    XCTAssertEqual(calls.first { $0.exe == "jj" }?.dir, path)
    XCTAssertEqual(runner.lookups.first?.dir, shared)
    XCTAssertFalse(calls.contains { $0.exe == "git" })
    XCTAssertTrue(
      calls.first { $0.exe == "jj" }?.args.contains("feature/login") ?? false)
    XCTAssertEqual(calls.last { $0.args.contains("graphql") }?.dir, NSTemporaryDirectory())
  }

  /// REGRESSION (local behaviour unchanged): a nil branch falls back to `git symbolic-ref`.
  func testLocalGitNilBranchFallsBackToSymbolicRef() async throws {
    let runner = GHRunner(healthy)
    let (service, _, _) = try await local(.git, runner: runner)
    let res = await service.pullRequest(branch: nil)
    guard case .info = res else { return XCTFail("expected .info via symbolic-ref") }
    let gh = runner.calls.first { $0.exe == "gh" && $0.args.first == "pr" }
    XCTAssertTrue(gh?.args.contains("main") ?? false)
  }

  /// A detached HEAD has no branch: absent, and gh is never asked (not even for the repository).
  func testLocalGitDetachedHeadIsAbsentWithoutAskingGh() async throws {
    let runner = GHRunner { exe, args in
      args.contains("symbolic-ref") ? failed("", exit: 1) : healthy(exe, args)
    }
    let (service, _, _) = try await local(.git, runner: runner)
    let pr = await service.pullRequest(branch: nil)
    let ci = await service.ci(branch: nil)
    XCTAssertEqual(pr, .absent)
    XCTAssertEqual(ci, .absent)
    XCTAssertFalse(runner.calls.contains { $0.exe == "gh" })
  }

  /// A bookmark-less jj `@` has no branch: absent before ANY probe, as before.
  func testLocalJJNoBookmarkIsAbsentBeforeAnyProbe() async throws {
    let runner = GHRunner(healthy)
    let (service, _, _) = try await local(.jj, runner: runner)
    let pr = await service.pullRequest(branch: nil)
    let ci = await service.ci(branch: nil)
    XCTAssertEqual(pr, .absent)
    XCTAssertEqual(ci, .absent)
    XCTAssertTrue(runner.calls.isEmpty)
  }

  func testLocalCIWithNoResolvableCommitIsAbsent() async throws {
    let runner = GHRunner { exe, args in
      exe == "git" && args.contains("rev-parse")
        ? failed("not a repo", exit: 128) : healthy(exe, args)
    }
    let (service, _, _) = try await local(.git, runner: runner)
    let res = await service.ci(branch: "main")
    XCTAssertEqual(res, .absent)
    XCTAssertTrue(runner.lookups.isEmpty)  // the cheap local read failed first: no network lookup
  }

  // MARK: - One lookup

  /// A selection refresh fires ci, pullRequest, enrich and checks; the repository is found ONCE.
  func testConcurrentProbesShareOneLookup() async throws {
    let runner = GHRunner(delay: 30_000_000, healthy)
    let (service, _, _) = try await local(.git, runner: runner)
    async let ci = service.ci(branch: "main")
    async let pr = service.pullRequest(branch: "main")
    async let checks = service.checks(number: 9)
    async let enriched = service.enrich(.absent)
    let results = await (ci, pr, checks, enriched)
    XCTAssertEqual(results.0, .state(.passing))
    guard case .info = results.1 else { return XCTFail("expected a PR") }
    XCTAssertEqual(
      results.2, .list([CICheck(name: "build", state: .passing, workflow: nil, link: nil)]))
    XCTAssertEqual(runner.lookups.count, 1)
  }

  /// One caller being cancelled (a superseded selection) must not cancel the answer its siblings wait on.
  ///
  /// Deterministic on purpose: the doomed probe starts FIRST and is the one that owns the lookup, and
  /// it is cancelled only once that lookup is genuinely in flight. Against a lookup that inherited the
  /// caller's cancellation, the sibling would get the killed child's `keepPrior` instead of a PR.
  func testCancellingOneProbeDoesNotCancelTheSharedLookup() async throws {
    let runner = GHRunner(delay: 200_000_000, healthy)
    let (service, _, _) = try await local(.git, runner: runner)
    let doomed = Task { await service.checks(number: 9) }
    while runner.lookups.isEmpty { await Task.yield() }  // the lookup is now in flight
    async let sibling = service.pullRequest(branch: "main")
    doomed.cancel()
    guard case .info = await sibling else { return XCTFail("sibling lost the shared lookup") }
    XCTAssertEqual(runner.lookups.count, 1)
  }

  // MARK: - REGRESSION: a transient lookup failure must not blank a good panel

  func testATransientLookupFailureKeepsThePriorStateForEveryProbe() async throws {
    let runner = GHRunner { exe, args in
      if exe == "gh", args.prefix(2) == ["repo", "view"] {
        return CommandResult(stdout: "", stderr: "", exitCode: 15, timedOut: true, signaled: true)
      }
      return healthy(exe, args)
    }
    let (service, _, _) = try await local(.git, runner: runner)
    async let ci = service.ci(branch: "main")
    async let pr = service.pullRequest(branch: "main")
    async let checks = service.checks(number: 9)
    let results = await (ci, pr, checks)
    XCTAssertEqual(results.0, .keepPrior)
    XCTAssertEqual(results.1, .keepPrior)
    XCTAssertEqual(results.2, .keepPrior)
    XCTAssertEqual(runner.lookups.count, 1)  // a failed lookup is not retried by each probe
    XCTAssertFalse(runner.calls.contains { $0.args.contains("graphql") || $0.args.first == "pr" })
  }

  func testNoRepositoryIsAbsentForEveryProbe() async throws {
    let runner = GHRunner { exe, args in
      exe == "gh" && args.prefix(2) == ["repo", "view"]
        ? failed("no git remotes found") : healthy(exe, args)
    }
    let (service, _, _) = try await local(.git, runner: runner)
    let ci = await service.ci(branch: "main")
    let pr = await service.pullRequest(branch: "main")
    let checks = await service.checks(number: 9)
    XCTAssertEqual(ci, .absent)
    XCTAssertEqual(pr, .absent)
    XCTAssertEqual(checks, .absent)
  }

  /// The sweep asks once per project and hands the answer to every workroom of it.
  func testCIUsesAPreResolvedLookupWithoutAskingAgain() async throws {
    let runner = GHRunner(healthy)
    let (service, _, _) = try await local(.git, runner: runner)
    let found = await service.ci(branch: "main", repository: .found(octo))
    let kept = await service.ci(branch: "main", repository: .keepPrior)
    let absent = await service.ci(branch: "main", repository: .absent)
    XCTAssertEqual(found, .state(.passing))
    XCTAssertEqual(kept, .keepPrior)  // a blip for one project reaches every workroom's CI probe
    XCTAssertEqual(absent, .absent)
    XCTAssertTrue(runner.lookups.isEmpty)
  }

  /// Git worktrees of one repository share its remote config, so the SHARED root decides identity for
  /// all of them — two workrooms of one project agree, from one lookup location.
  func testWorktreesOfOneProjectResolveTheSameIdentityFromTheSharedRoot() async throws {
    let shared = unique("proj")
    let sharedLocation = try await RepositoryLocation.local(shared)
    let router = RepositoryRouter()
    var lookups: [String] = []
    var found: [GitHubRepositoryResolution] = []
    for name in ["wt-a", "wt-b"] {
      let runner = GHRunner(healthy)
      let location = try await RepositoryLocation.local(shared + "/" + name)
      try router.register(.init(location: location, backend: .git, sharedLocation: sharedLocation))
      let service = try router.registeredGitHub(
        for: location, resolver: WorkroomStatusResolver(runner: runner))
      found.append(await service.repository())
      lookups += runner.lookups.map(\.dir)
    }
    XCTAssertEqual(found, [.found(octo), .found(octo)])
    XCTAssertEqual(lookups, [sharedLocation.path, sharedLocation.path])
  }

  // MARK: - REMOTE hosts: identity supplied, no local path

  /// The point of #207: a repository with no checkout on this Mac resolves PR, checks and writes from
  /// its supplied identity. Its path exists nowhere here, and no `git`, `jj` or `gh repo view` runs.
  func testRemoteWithIdentityResolvesByIdentityForGitAndJJ() async throws {
    for backend in [RepositoryBackend.git, .jj] {
      let runner = GHRunner(healthy)
      let service = try remote(backend, runner: runner)
      XCTAssertFalse(FileManager.default.fileExists(atPath: service.context.location.path))

      let pr = await service.pullRequest(branch: "feature/x")
      guard case .info = pr else { return XCTFail("\(backend): expected a PR") }
      let checks = await service.checks(number: 9)
      XCTAssertEqual(
        checks, .list([CICheck(name: "build", state: .passing, workflow: nil, link: nil)]))
      let write = await service.run(["pr", "close", "9"])
      XCTAssertTrue(write.ok)

      let calls = runner.calls
      XCTAssertEqual(calls.count, 3, "\(backend)")
      XCTAssertTrue(calls.allSatisfy { $0.exe == "gh" && $0.dir == NSTemporaryDirectory() })
      XCTAssertTrue(calls.allSatisfy { Array($0.args.suffix(2)) == ["--repo", octo.flag] })
      XCTAssertTrue(calls[0].args.contains("feature/x"))
      XCTAssertEqual(Array(calls[2].args.prefix(3)), ["pr", "close", "9"])
    }
  }

  /// A remote host has no checkout to read a branch tip from, so CI is absent — with no process run —
  /// until the agent supplies a commit (Phase 3).
  func testRemoteCIIsAbsentWithoutRunningAnything() async throws {
    let runner = GHRunner(healthy)
    let service = try remote(.git, runner: runner)
    let res = await service.ci(branch: "main")
    XCTAssertEqual(res, .absent)
    let preResolved = await service.ci(branch: "main", repository: .found(octo))
    XCTAssertEqual(preResolved, .absent)
    XCTAssertTrue(runner.calls.isEmpty)
  }

  func testRemoteNilBranchIsAbsentWithoutRunningAnything() async throws {
    let runner = GHRunner(healthy)
    let service = try remote(.git, runner: runner)
    let pr = await service.pullRequest(branch: nil)
    XCTAssertEqual(pr, .absent)
    XCTAssertTrue(runner.calls.isEmpty)
  }

  /// No identity was registered with the remote, so nothing can name its repository: refused before
  /// any command — through both construction paths.
  func testRemoteWithoutIdentityIsRefusedBeforeAnyCommand() async throws {
    let host = UUID()
    let shared = try RepositoryLocation.remote(host: host, path: "/srv/proj")
    let location = try RepositoryLocation.remote(host: host, path: "/srv/proj/ws")
    let router = RepositoryRouter()
    try router.register(.init(location: location, backend: .git, sharedLocation: shared))
    XCTAssertThrowsError(try router.registeredGitHub(for: location)) {
      XCTAssertEqual($0 as? RepositoryRoutingError, .unavailable(.remote(host)))
    }
    do {
      _ = try await router.gitHub(for: location)
      XCTFail("built GitHub status for a remote with no identity")
    } catch { XCTAssertEqual(error as? RepositoryRoutingError, .unavailable(.remote(host))) }
  }

  // MARK: - Writes

  /// A write never runs against a repository that was not resolved. The result is a failure the
  /// caller's existing path (revert the optimistic flip, show stderr) handles, and `gh` is not spawned.
  func testWriteFailsClosedWhenTheRepositoryIsNotFound() async throws {
    for lookup in [
      failed("no git remotes found"),
      CommandResult(
        stdout: "", stderr: "", exitCode: 15, timedOut: true, signaled: true),
    ] {
      let runner = GHRunner { exe, args in
        exe == "gh" && args.prefix(2) == ["repo", "view"] ? lookup : healthy(exe, args)
      }
      let (service, _, _) = try await local(.git, runner: runner)
      let r = await service.run(["pr", "merge", "9", "--squash"])
      XCTAssertFalse(r.ok)
      XCTAssertFalse(r.stderr.isEmpty)
      XCTAssertEqual(runner.calls.count, 1)  // only the lookup; the merge was never spawned
    }
  }

  /// A blip is "try again"; "no repository" is not. Both fail closed, with different words.
  func testWriteTellsATransientFailureFromNoRepository() async throws {
    func message(for lookup: CommandResult) async throws -> String {
      let runner = GHRunner { exe, args in
        exe == "gh" && args.prefix(2) == ["repo", "view"] ? lookup : healthy(exe, args)
      }
      let (service, _, _) = try await local(.git, runner: runner)
      return await service.run(["pr", "close", "9"]).stderr
    }
    let blip = try await message(
      for: CommandResult(stdout: "", stderr: "", exitCode: 15, timedOut: true, signaled: true))
    let none = try await message(for: failed("no git remotes found"))
    XCTAssertTrue(blip.contains("Try again"), blip)
    XCTAssertFalse(none.contains("Try again"), none)
    XCTAssertNotEqual(blip, none)
  }

  func testLocalWriteNamesTheResolvedRepository() async throws {
    let runner = GHRunner(healthy)
    let (service, _, _) = try await local(.git, runner: runner)
    let r = await service.run(["pr", "merge", "9", "--squash"])
    XCTAssertTrue(r.ok)
    let merge = runner.calls.last
    XCTAssertEqual(merge?.args, ["pr", "merge", "9", "--squash", "--repo", "github.com/octo/repo"])
    XCTAssertEqual(merge?.dir, NSTemporaryDirectory())
  }

  // MARK: - Registry

  func testRegistrationCarriesIdentityAndSurvivesLocalRefresh() async throws {
    let host = UUID()
    let shared = try RepositoryLocation.remote(host: host, path: "/srv/proj")
    let router = RepositoryRouter()
    try router.register(
      .init(location: shared, backend: .git, sharedLocation: shared, github: octo))
    let localLocation = try await RepositoryLocation.local(unique("proj"))
    try router.register(
      .init(location: localLocation, backend: .git, sharedLocation: localLocation))
    XCTAssertEqual(router.entry(for: shared)?.github, octo)
    XCTAssertNil(router.entry(for: localLocation)?.github)  // a local host finds its own
    router.replaceLocal([])
    // A local refresh keeps a remote registration's identity.
    XCTAssertEqual(router.entry(for: shared)?.github, octo)
    XCTAssertNil(router.entry(for: localLocation))
  }

  /// The AppStore gate: local, or remote-with-identity. A remote item without an identity is refused.
  func testGitHubAccessGate() async throws {
    let host = UUID()
    let withIdentity = try RepositoryLocation.remote(host: host, path: "/srv/with")
    let without = try RepositoryLocation.remote(host: host, path: "/srv/without")
    let router = RepositoryRouter.shared
    try router.register(
      .init(location: withIdentity, backend: .git, sharedLocation: withIdentity, github: octo))
    try router.register(.init(location: without, backend: .git, sharedLocation: without))
    func item(_ location: RepositoryLocation?) -> AppStore.StatusWorkItem {
      AppStore.StatusWorkItem(
        sid: .root(project: "/srv"), path: "/srv", vcs: "git", projectRoot: "/srv",
        location: location)
    }
    let localLocation = try await RepositoryLocation.local("/private/tmp")
    XCTAssertTrue(item(localLocation).permitsGitHubAccess)
    XCTAssertTrue(item(withIdentity).permitsGitHubAccess)
    XCTAssertFalse(item(without).permitsGitHubAccess)
    XCTAssertFalse(item(withIdentity).permitsLocalAccess)  // the local gate itself is unchanged
  }
}

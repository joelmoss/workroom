import Foundation

/// GitHub status for one repository. `gh` stays on this Mac for every host: what varies is how the
/// repository is NAMED. A local host finds its identity from its own git remote (`gh repo view`); a
/// remote host has no checkout here, so its identity is supplied by whoever registered it (issue
/// #207). Either way every probe then runs by identity, in a neutral directory.
///
/// Construct before cache lookup or optimistic edits. A remote location without a supplied identity
/// fails before filesystem inspection, provider construction, or any gh command.
struct RepositoryGitHub: Sendable {
  let context: RepositoryContext
  let resolver: WorkroomStatusResolver
  private let path: String
  private let sharedPath: String
  private let supplied: GitHubRepository?
  private let lookup = RepositoryLookup()

  init(
    context: RepositoryContext, resolver: WorkroomStatusResolver = WorkroomStatusResolver(),
    repository: GitHubRepository? = nil
  ) throws {
    if context.location.host == .local {
      _ = try context.location.requireLocalURL()
    } else if repository == nil {
      throw RepositoryRoutingError.unavailable(context.location.host)
    }
    self.context = context
    self.resolver = resolver
    supplied = repository
    path = context.location.path
    if context.backend == .jj {
      sharedPath = try context.requireOwnership().path
    } else {
      sharedPath = context.sharedLocation?.path ?? path
    }
  }

  private var isLocal: Bool { context.location.host == .local }

  /// This repository's identity — asked once per `RepositoryGitHub`, however many probes want it.
  ///
  /// A selection refresh fires `ci`, `pullRequest`, `enrich` and `checks`; each needs the identity,
  /// and finding it is a network round trip (`gh repo view`). One shared lookup keeps that at one.
  /// A supplied identity needs no lookup at all.
  ///
  /// The lookup is read from the SHARED root, for git and jj alike, so CI, PR, checks and PR writes
  /// all agree on one repository for a workroom. That assumes a project's git worktrees share remote
  /// config (they do, unless `extensions.worktreeConfig` gives one a remote of its own).
  func repository() async -> GitHubRepositoryResolution {
    if let supplied { return .found(supplied) }
    let resolver = resolver
    let dir = sharedPath
    return await lookup.resolve { await resolver.resolveRepository(in: dir) }
  }

  /// `repository` is a lookup the caller already made (the CI sweep asks once per project and shares
  /// the answer across that project's workrooms); nil asks this service's own.
  ///
  /// A remote host has no commit source until the agent supplies one (Phase 3), so its CI is absent.
  func ci(branch: String?, repository resolution: GitHubRepositoryResolution? = nil) async
    -> CIResolution
  {
    guard isLocal else { return .absent }
    // The branch tip is a cheap local read; do it before the network lookup, as before.
    guard
      let commit = await resolver.localCICommit(
        path: path, vcs: context.backend.rawValue, branch: branch)
    else { return .absent }
    let found: GitHubRepositoryResolution
    if let resolution { found = resolution } else { found = await repository() }
    // Superseded while waiting on the lookup: spawn nothing (the caller discards the answer anyway).
    if Task.isCancelled { return .keepPrior }
    switch found {
    case .absent: return .absent
    case .keepPrior: return .keepPrior
    case .found(let repo): return await resolver.resolveCI(repo: repo, commit: commit)
    }
  }

  func pullRequest(branch: String?) async -> PRResolution {
    let resolved: String?
    if isLocal {
      resolved = await resolver.localBranch(
        path: path, vcs: context.backend.rawValue, branch: branch)
    } else {
      resolved = branch
    }
    guard let resolved, !resolved.isEmpty else { return .absent }
    let found = await repository()
    if Task.isCancelled { return .keepPrior }
    switch found {
    case .absent: return .absent
    case .keepPrior: return .keepPrior
    case .found(let repo): return await resolver.resolvePRRaw(repo: repo, branch: resolved)
    }
  }

  func enrich(_ resolution: PRResolution) async -> PRResolution {
    let found = await repository()
    if Task.isCancelled { return resolution }
    guard case .found(let repo) = found else { return resolution }
    return await resolver.enrichPR(resolution, repo: repo)
  }

  func checks(number: Int) async -> ChecksResolution {
    let found = await repository()
    if Task.isCancelled { return .keepPrior }
    switch found {
    case .absent: return .absent
    case .keepPrior: return .keepPrior
    case .found(let repo): return await resolver.resolveChecks(repo: repo, number: number)
    }
  }

  /// Fails closed: a write never runs against a repository that was not resolved. `gh` is not
  /// spawned, and the result is a synthesized failure (its exit code is NOT from `gh`) that the
  /// caller's existing failure path — revert the optimistic flip, show `stderr` — already handles.
  func run(_ arguments: [String]) async -> CommandResult {
    let message: String
    switch await repository() {
    case .found(let repo): return await resolver.runPRCommand(arguments, repo: repo)
    // A blip is a retry-in-a-minute condition; "no repository" reads as a permanent problem.
    case .keepPrior:
      message = "Couldn’t reach GitHub to find this workroom’s repository. Try again."
    // Also what an offline Mac gets: a plain connection failure classifies as absent (see TODOS.md).
    case .absent:
      message =
        "Couldn’t determine the GitHub repository for this workroom. "
        + "Check that gh is installed, signed in and online."
    }
    return CommandResult(stdout: "", stderr: message, exitCode: 1, timedOut: false)
  }
}

/// Holds ONE repository lookup for every probe of a `RepositoryGitHub`. The lookup runs in its own
/// unstructured `Task`, so cancelling one probe (a superseded selection) never cancels the answer its
/// siblings are still waiting on — but when the LAST waiter leaves, the lookup is cancelled, which
/// kills its `gh repo view` child (a structured lookup would have died with its refresh too). Without
/// that, every superseded refresh leaves a live `gh` process behind, unbounded by any sweep cap, at
/// exactly the moment GitHub is slow. A failed lookup is cached, for this instance only — one refresh
/// — so a blip is not retried by each of four probes; a cancelled one is not, so the next caller
/// starts fresh.
private actor RepositoryLookup {
  private var task: Task<GitHubRepositoryResolution, Never>?
  private var waiters: Set<UUID> = []
  private var completed = false

  func resolve(_ work: @escaping @Sendable () async -> GitHubRepositoryResolution) async
    -> GitHubRepositoryResolution
  {
    let id = UUID()
    let current = task ?? start(work)
    waiters.insert(id)
    let result = await withTaskCancellationHandler {
      await current.value
    } onCancel: {
      Task { await self.leave(id, from: current) }
    }
    if task == current { completed = true }
    waiters.remove(id)
    return result
  }

  private func start(_ work: @escaping @Sendable () async -> GitHubRepositoryResolution)
    -> Task<GitHubRepositoryResolution, Never>
  {
    let started = Task { await work() }
    task = started
    completed = false
    return started
  }

  private func leave(_ id: UUID, from owner: Task<GitHubRepositoryResolution, Never>) {
    waiters.remove(id)
    guard waiters.isEmpty, task == owner, !completed else { return }
    owner.cancel()
    task = nil
  }
}

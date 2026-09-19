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
    switch await repository() {
    case .absent: return .absent
    case .keepPrior: return .keepPrior
    case .found(let repo): return await resolver.resolvePRRaw(repo: repo, branch: resolved)
    }
  }

  func enrich(_ resolution: PRResolution) async -> PRResolution {
    guard case .found(let repo) = await repository() else { return resolution }
    return await resolver.enrichPR(resolution, repo: repo)
  }

  func checks(number: Int) async -> ChecksResolution {
    switch await repository() {
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
    case .absent: message = "Couldn’t determine the GitHub repository for this workroom."
    }
    return CommandResult(stdout: "", stderr: message, exitCode: 1, timedOut: false)
  }
}

/// Holds ONE repository lookup for every probe of a `RepositoryGitHub`. The lookup runs in its own
/// unstructured `Task`, so a probe being cancelled (a superseded selection) never cancels the answer
/// its siblings are still waiting on. A failed lookup is cached too, for this instance only — one
/// refresh — so a blip is not retried by each of four probes.
///
/// The cost of that detachment: a refresh that is superseded entirely no longer reclaims the `gh`
/// child (a structured lookup would have been SIGKILLed with it). It is one `gh repo view` per
/// refresh, bounded by `ciTimeout`, and cancelling one probe must not fail its siblings.
private actor RepositoryLookup {
  private var task: Task<GitHubRepositoryResolution, Never>?

  func resolve(_ work: @escaping @Sendable () async -> GitHubRepositoryResolution) async
    -> GitHubRepositoryResolution
  {
    if let task { return await task.value }
    let started = Task { await work() }
    task = started
    return await started.value
  }
}

import Defaults
import HostDrivers
import WorkroomDomain
import WorkroomVCS

/// What a remote create needs from the project before it makes anything (the `repository` step).
struct RemoteCreatePlan: Sendable {
  let repository: GitHubRepository
  let cloneURL: String
  /// The branch on origin it starts from, or nil for origin's default.
  let startBranch: String?
  /// The app-wide default base branch, when a remote machine can't use it.
  let defaultNotUsed: String?
  var origin: String? = nil
}

/// Where a remote create makes its workroom.
struct RemoteCreateHost {
  let key: RemoteHosts.DriverKey
  let driver: any HostTerminalDriver
  let environment: RemoteProvisioning.Environment
  /// A container runtime's driver, for a container create: it builds or pulls the devcontainer's
  /// image and makes the container from it (#308).
  var container: ContainerHostDriver? = nil
  /// An SSH create's checked host and the parent folder its workroom's folder goes in (ADR 0056).
  var ssh: (driver: SSHHostDriver, parent: String)? = nil
}

/// What a remote create reaches beyond the app (#483): GitHub and the project's git, the provider's
/// account, and its hosts. `live` in the app; tests stand in fakes.
struct RemoteCreateServices {
  /// The project's plan, from the base branch its new workrooms start from (`effectiveBaseBranch`:
  /// its own, else the app-wide one, else nil for origin's default).
  var plan: @MainActor (Project, String?) async throws -> RemoteCreatePlan
  var setupNeeded: @MainActor (HostKind) async -> (any RemoteSetup)?
  /// The provider's host and how it is reached, made with the resolved host options a boxd or
  /// exe.dev create takes (#575); nil for any other place.
  var host: @MainActor (HostKind, ResolvedHostOptions?) async throws -> RemoteCreateHost
  /// The project's and Settings' host options for `provider` (#575), read afresh at each try.
  var hostOptionLevels:
    @MainActor (Project, HostKind) -> (project: HostOptions?, settings: HostOptions?) = {
      _, _ in (nil, nil)
    }
  /// Runs the setup script on the new workroom's host (`RemoteWorkrooms.runScript`). A test's fakes
  /// have no script unless they say so.
  var script: @MainActor (RemoteWorkrooms.ScriptRequest) async -> RemoteProvisioning.ScriptRun = {
    _ in .absent
  }
  /// The CLI's `trust status` at the origin branch the plan checks out, asked through the CLI it is
  /// handed: the setup script a create would run, judged against this Mac's approvals (#363), and
  /// the local work that start leaves out. Its last argument judges the devcontainer.json a container
  /// create would use too (#308). A test's fakes approve every script and find no local work unless
  /// they say.
  var trustStatus:
    @MainActor (any WorkroomCLIProtocol, Project, RemoteCreatePlan, Bool) async throws ->
      TrustStatus = { _, _, _, _ in
        TrustStatus(trusted: true, scripts: [])
      }

  static var live: RemoteCreateServices {
    RemoteCreateServices(
      plan: { project, base in try await RemoteCreatePlan.resolve(for: project, base: base) },
      // Checked once a launch per provider, so later creates go straight ahead.
      setupNeeded: { place -> (any RemoteSetup)? in
        switch place {
        case .exeDev:
          return await ExeDevSetup.needed(driver: HostDriverRegistry.exeDev())
        case .boxd:
          return await BoxdSetup.needed()
        case .container:
          return nil
        case .ssh:
          return SSHHostSetup()
        }
      },
      host: { place, options in
        let key = try await RemoteHosts.shared.key(for: place)
        var (driver, environment) = try RemoteHosts.shared.environment(key)
        if let options { environment.made(with: options, by: driver) }
        return RemoteCreateHost(
          key: key, driver: driver, environment: environment,
          container: key.runtime == nil ? nil : try RemoteHosts.shared.containerDriver(key))
      },
      hostOptionLevels: { project, provider in
        (
          project: Defaults[.projectHostOptions][project: project.path, provider: provider],
          settings: Defaults[.hostOptions][provider: provider]
        )
      },
      script: { request in await RemoteWorkrooms.runScript(request) },
      trustStatus: { cli, project, plan, devcontainer in
        // origin named, so a branch like `release/1.0` is never read as a remote's.
        let base = plan.startBranch.map { "origin/\($0)" } ?? ""
        return try await cli.trustStatus(
          project: project.path, base: base, devcontainer: devcontainer)
      })
  }

  /// How a create of `place` in `project` resolves its host options (#575), with each value's
  /// source: nil for a place that takes none. `create` is this create's own.
  @MainActor func hostOptionResolution(
    for place: HostKind, in project: Project, create: HostOptions?
  ) -> HostOptions.Resolution? {
    guard place.takesHostOptions else { return nil }
    let levels = hostOptionLevels(project, place)
    return HostOptions.resolve(
      for: place, create: create, project: levels.project, settings: levels.settings)
  }
}

extension RemoteCreatePlan {
  /// The project's GitHub repository and the branch its remote workroom starts from, `base` (the
  /// base branch its new workrooms start from, nil for origin's default), or why it can't have one.
  @MainActor
  static func resolve(for project: Project, base: String?) async throws -> RemoteCreatePlan {
    // gh first, as it knows which remote is GitHub's; without it (not installed, or signed out,
    // which a remote provider's workroom doesn't need) origin says (#260).
    let git = GitRepositoryProbe()
    var repository: GitHubRepository?
    if case .found(let found) = await GitHubStatusResolver().resolveRepository(in: project.path) {
      repository = found
    } else {
      repository = await git.originRepository(in: project.path)
    }
    guard let repository else {
      throw RemoteWorkrooms.Failure.notOnGitHub(
        "Its origin remote names no GitHub repository, and gh couldn't say which one it is.")
    }
    guard repository.host == "github.com" else {
      throw RemoteWorkrooms.Failure.notOnGitHub("Its origin is on \(repository.host).")
    }
    // A remote host has only origin, so a base on another remote, or one only this Mac has, would
    // fail its checkout minutes in. Unreachable (nil) is left to the checkout, which says so.
    // A project's own base that can't be used fails; the app-wide default only falls back to
    // origin's default branch, with a notice, as a local create does.
    var startBranch: String?
    var defaultNotUsed: String?
    if let base {
      let (remote, branch) = RemoteWorkrooms.splitBase(
        base, remotes: await git.remoteNames(in: project.path))
      let fromDefault = project.baseBranch == nil
      if remote != "origin" {
        guard fromDefault else { throw RemoteWorkrooms.Failure.baseBranchOnOtherRemote(base) }
        defaultNotUsed = base
      } else if await git.originHasBranch(branch, in: project.path) == false {
        guard fromDefault else { throw RemoteWorkrooms.Failure.baseBranchNotOnOrigin(branch) }
        defaultNotUsed = base
      } else {
        startBranch = branch
      }
    }
    let origin = await git.originURL(in: project.path)
    return RemoteCreatePlan(
      repository: repository,
      cloneURL: RemoteWorkrooms.cloneURL(
        for: repository, origin: origin),
      startBranch: startBranch, defaultNotUsed: defaultNotUsed, origin: origin)
  }
}

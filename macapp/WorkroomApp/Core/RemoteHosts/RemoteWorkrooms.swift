import DaemonConnection
import Defaults
import Foundation
import HostDrivers
import WorkroomDomain
import WorkroomVCS
import WorkroomWire
import os

/// Remote workrooms in the app (#253): each has its own clone, on a provisioned host or in its own
/// folder on an existing SSH server. A remote workroom belongs to a project registered on this Mac
/// (design doc, Phase 4: there are no remote projects).
enum RemoteWorkrooms {
  /// Why a workroom can't be created on a host of `kind` now, as the New Workroom menu and picker
  /// show it beside the entry, or nil when it can.
  @MainActor
  static func unavailability(of kind: HostKind) -> String? {
    switch kind {
    case .container(let runtime): unavailability(of: runtime)
    case .boxd, .exeDev, .ssh:
      // Never unavailable: a create first checks the user's account there and, when it isn't
      // ready, shows the provider's setup (`BoxdSetup`, `ExeDevSetup`), installing boxd too.
      nil
    }
  }

  /// Why a workroom can't be created on `runtime` now, as the New Workroom menu shows it beside the
  /// entry, or nil when it can (#309).
  @MainActor
  static func unavailability(of runtime: ContainerRuntime) -> String? {
    var arm64: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let appleSilicon = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0 && arm64 == 1
    return unavailability(
      of: runtime, installed: RemoteHosts.executable(for: runtime) != nil,
      appleSilicon: appleSilicon,
      macOS26: ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)),
      // gh's files, not `gh auth token`: this runs in menus' and the picker's bodies. A create
      // checks for real.
      signedIn: CredentialRelay.hasGitHubSignIn())
  }

  static func unavailability(
    of runtime: ContainerRuntime, installed: Bool, appleSilicon: Bool, macOS26: Bool,
    signedIn: Bool
  ) -> String? {
    if runtime == .apple {
      // Apple's runtime runs each container in a VM of its own, on Apple silicon and macOS 26.
      if !appleSilicon { return "needs Apple silicon" }
      if !macOS26 { return "needs macOS 26" }
    }
    if !installed { return "not installed" }
    // The Mac's own `gh`, through the relay (#309).
    if !signedIn { return "run gh auth login" }
    return nil
  }
  /// The descriptor's `provisioner`: this build, whose ssh key and Docker labels its hosts carry.
  static var provisioner: String { Bundle.main.bundleIdentifier ?? "com.developwithstyle.workroom" }

  /// The builds that share each other's boxd and exe.dev hosts: Release and Nightly, which share a
  /// config too. A Dev build keeps its own config and hosts.
  static let sharedHostBuilds: Set<String> = [
    "com.developwithstyle.workroom", "com.developwithstyle.workroom.nightly",
  ]

  /// Whether `own`'s build may open and take down `host`. Its own, always. Another
  /// build's only on a remote provider, and only between Release and Nightly: a boxd or exe.dev
  /// machine is reached through the provider's CLI and the user's own ssh, so nothing there is the
  /// build's. A container takes this build's ssh key and Docker labels, so it stays the build's
  /// alone.
  static func ownsHost(_ host: HostDescriptor, as own: String = provisioner) -> Bool {
    if host.provisioner == own { return true }
    guard let theirs = host.provisioner, RemoteHosts.DriverKey(host)?.isRemoteProvider == true
    else { return false }
    return sharedHostBuilds.contains(own) && sharedHostBuilds.contains(theirs)
  }
  /// Where a container's daemon serves (`ContainerHostDriver.containerSocket`).
  static let daemonSocket = DaemonInstall.defaultSocket
  static let user = "workroom"

  /// The image a container workroom without a devcontainer.json is made from (#308, eng review
  /// D8): the pinned devcontainers base. Another image is the repository's to name, in its
  /// devcontainer.json.
  static let defaultImage = DevContainerSetup.pinnedDefaultImage

  /// The branch a remote workroom checks out, as a local workroom's is named.
  static func branch(for name: String) -> String { "workroom/\(name)" }

  /// A base branch setting as the CLI reads it (`vcs.SplitBase`): `<remote>/<branch>` when the part
  /// before the first `/` is one of `remotes`, else a branch on origin. So `upstream/main` is
  /// upstream's main, `origin/main` is `main`, and `release/1.0` stays an origin branch.
  static func splitBase(_ base: String, remotes: [String]) -> (remote: String, branch: String) {
    if let slash = base.firstIndex(of: "/") {
      let remote = String(base[..<slash])
      let branch = String(base[base.index(after: slash)...])
      if !branch.isEmpty, remotes.contains(remote) { return (remote, branch) }
    }
    return ("origin", base)
  }

  /// How a workroom clones `repository`: with the project's `origin` URL as it is, when it names
  /// `repository` in a form every host rewrites to https: https, or `git@github.com:`, which boxd
  /// rewrites itself and an exe.dev host and a container's relay are given a rewrite for. Any other
  /// origin (another repository gh resolved, `ssh://` or a user-less scp form) gives way to https.
  static func cloneURL(
    for repository: GitHubRepository, origin: String?, onSSHHost: Bool = false
  ) -> String {
    if onSSHHost, let origin = origin?.trimmingCharacters(in: .whitespacesAndNewlines),
      GitHubRepository(remote: origin) == repository
    {
      return origin.hasPrefix("github.com:") ? "git@" + origin : origin
    }
    if let origin = origin?.trimmingCharacters(in: .whitespacesAndNewlines),
      origin.hasPrefix("https://github.com/") || origin.hasPrefix("git@github.com:"),
      GitHubRepository(remote: origin) == repository
    {
      return origin
    }
    return "https://\(repository.host)/\(repository.owner)/\(repository.name).git"
  }

  /// Where a workroom clones its repository on a host of `key`: the home of the user its
  /// driver logs in as (`workroom` in a container, `boxd` on boxd, #356).
  static func clonePath(
    for repository: GitHubRepository, on key: RemoteHosts.DriverKey = .init()
  ) -> String {
    "/home/\(key.loginUser)/\(repository.name)"
  }

  enum Failure: Error, LocalizedError, Equatable {
    case signedOut
    case notOnGitHub(String)
    case noDocker
    case noAppleContainer
    case anotherBuildsHost(String)
    case boxdNotInstalled
    case baseBranchNotOnOrigin(String)
    case baseBranchOnOtherRemote(String)
    /// The workroom's teardown script failed on its host, or the host couldn't be reached to run it:
    /// worded as the CLI words a local one ("teardown script failed: ...").
    case teardownScriptFailed(String)
    /// The host's teardown script is not one this Mac has approved, so it did not run (#363).
    case teardownScriptNotTrusted(ScriptTrust)

    var errorDescription: String? {
      switch self {
      case .teardownScriptFailed(let why):
        return why
      case .teardownScriptNotTrusted(let script):
        return "scripts/\(script.name) \(script.originLabel) is new, or changed since it was "
          + "approved on this Mac, so it did not run."
      case .signedOut:
        return "Sign in to GitHub with `gh auth login`: it gives the workroom its GitHub access."
      case .notOnGitHub(let detail):
        return "A remote workroom needs a project whose origin is on github.com. \(detail)"
      case .anotherBuildsHost(let build):
        return "It runs on a remote host another Workroom build made (\(build)), which this build "
          + "can't take down. Delete it from that build."
      case .baseBranchNotOnOrigin(let branch):
        return "This project's new workrooms start from \(branch), which origin doesn't have. A "
          + "remote workroom can only start from origin's branches. Push \(branch), or change the "
          + "base branch in Project Settings."
      case .baseBranchOnOtherRemote(let base):
        return "This project's new workrooms start from \(base), on a remote other than origin. A "
          + "remote workroom's machine has only origin, so it can't start there. To make remote "
          + "workrooms, set a base branch on origin in Project Settings."
      case .boxdNotInstalled:
        return "The boxd command wasn't found. Install it from boxd.sh, then sign in with "
          + "`boxd auth login`."
      case .noDocker:
        return "No docker command was found. Install Docker Desktop, OrbStack or Colima."
      case .noAppleContainer:
        return "Apple's container command wasn't found. Install it from "
          + "github.com/apple/container, then run `container system start`."
      }
    }
  }

  /// The router registrations of `projects`' reachable remote workrooms (#253). Each is its own
  /// shared root on its host, as an independent clone is, with the GitHub repository `create`
  /// recorded on it (`BaseRetirement` records it on one an older build derived from a base), so its
  /// PR and CI status read through `gh` here.
  static func registrations(_ projects: [Project]) -> [RepositoryRouter.Registration] {
    projects.flatMap { project in
      project.workrooms.compactMap { workroom -> RepositoryRouter.Registration? in
        guard let host = workroom.reachableHost,
          let location = try? RepositoryLocation.remote(host: host, path: workroom.path)
        else { return nil }
        let github = workroom.host?.repository.flatMap(gitHubRepository)
        return try? RepositoryRouter.Registration(
          location: location, sharedLocation: location, github: github)
      }
    }
  }

  /// A workroom's (or an older build's base's) `owner/name`, on github.com, the only host a remote
  /// workroom is made for (`notOnGitHub`).
  static func gitHubRepository(_ repository: String) -> GitHubRepository? {
    let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    return GitHubRepository(host: "github.com", owner: String(parts[0]), name: String(parts[1]))
  }

  /// What the create sequence writes to config, through the CLI.
  struct Recorder: Sendable {
    /// Registers a remote workroom under a new name with `descriptor`, at `path` on its host, and
    /// returns the name (`workroom create --host`).
    var reserve: @Sendable (_ path: String, _ descriptor: HostDescriptor) async throws -> String
    /// Stores `descriptor` on the project (`workroom` nil) or on one of its workrooms.
    var record: @Sendable (_ workroom: String?, _ descriptor: HostDescriptor) async throws -> Void
    /// Drops a workroom whose host never came to be.
    var forget: @Sendable (_ workroom: String) async throws -> Void
    /// SSH names the leaf after the CLI reserves its name.
    var reserveInParent:
      (@Sendable (_ parent: String, _ descriptor: HostDescriptor) async throws -> String)? = nil
    /// Reads persisted config after the entry was dropped; includes creating workrooms.
    var hasWorkrooms: @Sendable (UUID) async throws -> Bool = { _ in false }

    /// This recorder, taking each machine a record names off the pending list in `directory`
    /// once the record is written (#373): from then on config names it, so only a machine whose
    /// record was never written is left for the sweep.
    func forgettingPending(in directory: URL?) -> Recorder {
      guard let directory else { return self }
      var recorder = self
      let record = self.record
      recorder.record = { workroom, descriptor in
        try await record(workroom, descriptor)
        PendingMachines.forget(Set([descriptor.id].compactMap { $0 }), in: directory)
      }
      return recorder
    }
  }

  /// A workroom the sequence made: its name in config, and its instance.
  struct Created: Sendable {
    let name: String
    let instance: RemoteProvisioning.Instance
  }

  /// A folder on an existing server. Its cleanup never reaches the provisioning protocol.
  static func createSSH(
    repository: GitHubRepository, cloneURL: String, startBranch: String?, startCommit: String?,
    parent: String, driver: SSHHostDriver, environment: RemoteProvisioning.Environment,
    recorder: Recorder
  ) async throws -> Created {
    _ = try await driver.checkHost()
    let parent = try driver.resolveParent(parent)
    guard let reserve = recorder.reserveInParent else {
      throw HostDriverError.invalidConfiguration("SSH folder reservation is unavailable")
    }
    let workroom = UUID()
    var descriptor = HostDescriptor(
      state: HostLifecycle.creating.state, driver: HostKind.ssh.driver, provisioner: provisioner,
      id: SSHHostDriver.id(for: driver.destination), workroomID: workroom,
      repository: "\(repository.owner)/\(repository.name)", cloneURL: cloneURL)
    driver.record(driver.hostID, in: &descriptor)
    let name = try await reserve(parent, descriptor)
    let path = parent + "/" + name
    descriptor.path = path
    let reserved = descriptor
    do {
      // git on the user's server uses its own credentials (ADR 0056): the clone gets no token.
      let instance = try await RemoteProvisioning.place(
        SSHFolderPlacement(driver: driver, path: path, workroom: workroom), cloneURL: cloneURL,
        path: path, branch: branch(for: name), startBranch: startBranch, startCommit: startCommit,
        header: nil, in: environment,
        finish: { _ in
          var serving = reserved
          serving.lifecycle = .serving
          try await recorder.record(name, serving)
        })
      return Created(name: name, instance: instance)
    } catch {
      if case RemoteProvisioning.Failure.rollbackIncomplete = error {
        // The folder is still there: the entry keeps it, `failed`, for a delete to finish.
        var failed = reserved
        failed.lifecycle = .failed
        try? await recorder.record(name, failed)
      } else {
        try? await recorder.forget(name)
      }
      throw error
    }
  }

  /// Creates a remote workroom for a project (#253): a name in config, then the workroom's own
  /// host with its own clone, then the host's descriptor. The name is taken before the host is
  /// made, so the branch is named for it and a crash part-way leaves an entry the user can see and
  /// delete; anything the crash left on a host is the sweep's (`RemoteHosts.adopt`, and
  /// `PendingMachines` for a remote provider's machine, #373).
  ///
  /// When the create fails and undid itself, the entry is dropped. When undoing it failed too, the
  /// entry keeps the host that is still live so deleting it can finish the job.
  ///
  /// A container's dev container (#308) says where the checkout goes (`path`, its
  /// workspaceFolder), and what it was made from (`config`, for the Details pane); `startCommit` is
  /// the commit its files were judged at.
  static func create(
    repository: GitHubRepository, cloneURL: String, startBranch: String? = nil,
    startCommit: String? = nil, path: String? = nil,
    config: (digest: String, file: String?)? = nil, key: RemoteHosts.DriverKey = .init(),
    driver: any HostTerminalDriver,
    environment: RemoteProvisioning.Environment, recorder: Recorder,
    pendingIn: URL? = RemoteHosts.pendingIn, madeWith: ResolvedHostOptions? = nil
  ) async throws -> Created {
    // Before anything is made or recorded: a repository the provider can't reach fails at once. Its
    // commands go in the `repository` row's log (#483), without starting that row again: the app
    // has already moved on to the account by now. A refusal is the repository's, so it reports that
    // row, which the failure then marks, not the account or image row the checklist is on.
    do {
      try await ProvisioningProgress.step(.repository, report: false) {
        try await environment.grantRepository?(repository)
      }
    } catch {
      ProvisioningProgress.reportStep?(.repository)
      throw error
    }
    let recorder = recorder.forgettingPending(in: pendingIn)
    let origin = "\(repository.owner)/\(repository.name)"
    let path = path ?? clonePath(for: repository, on: key)
    let workroomID = UUID()
    let name = try await recorder.reserve(
      path,
      HostDescriptor(
        state: HostLifecycle.creating.state, driver: key.kind.driver, provisioner: provisioner,
        workroomID: workroomID, org: key.org, account: key.account))
    let instance: RemoteProvisioning.Instance
    do {
      instance = try await RemoteProvisioning.provision(
        cloneURL: cloneURL, path: path, branch: branch(for: name), startBranch: startBranch,
        startCommit: startCommit, in: environment
      ) { host in
        // Still `creating`, but now naming what a delete has to take down.
        try await recorder.record(
          name, remaining(.creating, workroomID: workroomID, host: host, key: key, driver: driver))
      }
    } catch RemoteProvisioning.Failure.rollbackIncomplete(let cause, let host, let left) {
      await recordLeftBehind(host) {
        try await recorder.record(
          name, remaining(.failed, workroomID: workroomID, host: host, key: key, driver: driver))
      }
      throw RemoteProvisioning.Failure.rollbackIncomplete(cause: cause, host: host, cleanup: left)
    } catch HostDriverError.leftBehind(let cause, let left, let host?) {
      // The driver could not remove the machine it made: the entry keeps it, `failed`, so deleting
      // the workroom takes it down. Forgotten, a paid machine would run on with nothing to find it.
      await recordLeftBehind(host) {
        try await recorder.record(
          name, remaining(.failed, workroomID: workroomID, host: host, key: key, driver: driver))
      }
      throw RemoteProvisioning.Failure.rollbackIncomplete(cause: cause, host: host, cleanup: left)
    } catch {
      try? await recorder.forget(name)
      throw error
    }

    guard case .remote = instance.host else {
      throw HostDriverError.unknownHost(instance.host)
    }
    do {
      var descriptor = describing(
        instance.host, key: key, driver: driver, credentials: instance.relayed)
      descriptor.workroomID = workroomID
      descriptor.madeWith = madeWith
      descriptor.container?.configDigest = config?.digest
      descriptor.container?.configFile = config?.file
      // Its own GitHub identity, for PR and CI status (`registrations`).
      descriptor.repository = origin
      descriptor.cloneURL = cloneURL
      try await recorder.record(name, descriptor)
    } catch {
      // Unrecorded, the instance would be found by nothing but the sweep.
      do {
        try await RemoteProvisioning.destroy(instance, in: environment)
      } catch RemoteProvisioning.Failure.rollbackIncomplete(_, let host, _) {
        // Something is still live: the entry stays, `failed`, for delete to finish.
        await recordLeftBehind(host) {
          try await recorder.record(
            name,
            remaining(.failed, workroomID: workroomID, host: host, key: key, driver: driver))
        }
        throw error
      } catch {
        // `destroy` throws nothing else: everything it made is gone.
      }
      try? await recorder.forget(name)
      throw error
    }
    return Created(name: name, instance: instance)
  }

  /// The descriptor of a workroom whose undoing left `host` live.
  private static func remaining(
    _ lifecycle: HostLifecycle, workroomID: UUID, host: HostID, key: RemoteHosts.DriverKey,
    driver: any HostTerminalDriver
  ) -> HostDescriptor {
    var descriptor = HostDescriptor(
      state: lifecycle.state, driver: key.kind.driver, provisioner: provisioner,
      workroomID: workroomID, org: key.org, account: key.account)
    if case .remote(let id) = host {
      descriptor.id = id
      (driver as? any HostRecording)?.record(host, in: &descriptor)
    }
    return descriptor
  }

  /// A live host's descriptor on `key`: its driver, this build, and how `key`'s driver finds it
  /// again (a container record, or a boxd org and account).
  private static func describing(
    _ host: HostID, key: RemoteHosts.DriverKey, driver: any HostTerminalDriver, credentials: Bool
  ) -> HostDescriptor {
    var descriptor = HostDescriptor(
      driver: key.kind.driver, provisioner: provisioner,
      credentials: credentials ? "relay" : nil, org: key.org, account: key.account)
    (driver as? any HostRecording)?.record(host, in: &descriptor)
    if case .remote(let id) = host { descriptor.id = id }
    return descriptor
  }

  /// Whether `host` records a box still up. A destroyed one has none, and neither has one a create
  /// left at `creating` before its driver made a box, whose container (if any) the sweep takes once
  /// no record names it.
  static func isLive(_ host: HostDescriptor) -> Bool {
    !host.isDestroyed && host.id != nil
  }

  /// Refuses to take down `hosts` when one that is live is another build's: its key and labels are
  /// not this build's (`create`). Returns whether any of them is live, so needs an environment.
  @discardableResult
  static func checkDeletable(_ hosts: [HostDescriptor]) throws -> Bool {
    let live = hosts.filter(isLive)
    if let other = live.first(where: { !ownsHost($0) }) {
      throw Failure.anotherBuildsHost(other.provisioner ?? "an unknown build")
    }
    return !live.isEmpty
  }

  /// A workroom script to run on its host: setup at the end of a create, teardown before a delete.
  struct ScriptRequest: Sendable {
    let script: RemoteProvisioning.Script
    let workroom: String
    /// The workroom's checkout on its host.
    let path: String
    let host: HostID
    let key: RemoteHosts.DriverKey
    let driver: any HostTerminalDriver
    let daemonBinary: String
    /// The project root's copy, on this Mac, for a checkout without one.
    let rootScript: URL?
    /// Judges the bytes that would run (#363).
    let judge: RemoteProvisioning.ScriptJudge
    var onStart: @Sendable () -> Void = {}
    let onLine: @Sendable (String) -> Void
    /// On top of what the script runs with: a container's `remoteEnv` (#308).
    var environment: [String: String] = [:]
  }

  /// Runs a workroom's script on its host, through the app's own connection to it
  /// (`HostReachability.ensureConnected`, then `connect`): that replaces a daemon older than this
  /// app's, so `run-script` is there, and puts a relayed host's git credentials up for the script,
  /// as its terminals get them.
  static func runScript(
    _ request: ScriptRequest, reachability: HostReachability = RemoteHosts.shared.reachability
  ) async -> RemoteProvisioning.ScriptRun {
    do {
      // Joins a connect already under way (a status read after wake) rather than fail beside it.
      // The user asked for this host, as opening its workroom does: a stopped container (every
      // Apple one after a reboot) is started and an asleep boxd box woken.
      reachability.activate(request.host)
      try await reachability.ensureConnected(request.host, wake: true)
    } catch RepositoryRoutingError.unavailable {
      // The connect's own error is logged there; "Repository service unavailable" means nothing here.
      return .failed("\(request.script.rawValue) script failed: couldn't reach the host")
    } catch {
      return .failed("\(request.script.rawValue) script failed: \(error.localizedDescription)")
    }
    return await RemoteProvisioning.runScript(
      request.script, workroom: request.workroom, at: request.path,
      hostKind: request.key.kind.workroomHost, rootScript: request.rootScript,
      daemonBinary: request.daemonBinary, on: request.host, driver: request.driver,
      judge: request.judge, environment: request.environment, onStart: request.onStart,
      onLine: request.onLine)
  }

  /// What a delete runs before the host goes: the workroom's teardown script, as the CLI runs a local
  /// one first.
  struct Teardown: Sendable {
    /// The workroom's checkout on its host.
    let path: String
    let rootScript: URL?
    /// Delete Anyway: the script failed, and the user chose to go on without it.
    var skip = false
    /// Judges the bytes that would run (#363).
    let judge: RemoteProvisioning.ScriptJudge
    let onLine: @Sendable (String) -> Void
    /// What runs the script: nil in the app, which runs it with `runScript` over the delete's own
    /// `reachability`; a fake in a test.
    var run: (@Sendable (ScriptRequest) async -> RemoteProvisioning.ScriptRun)?
  }

  /// What a delete let go of, which the app's own models of it forget too
  /// (`WorkroomLifecycle.forgetRemote`).
  enum Forgotten: Equatable, Sendable {
    /// A host gone with its workroom, or a record naming nothing live: the host's port forwards and
    /// program status.
    case host(HostID)
    /// A workroom's folder on an SSH host that stays: that workroom's own port forwards.
    case workroom(UUID, on: HostID)
    /// The last workroom on an SSH host: the host's program status. Its daemon runs on (ADR 0056).
    case lastWorkroom(on: HostID)
  }

  /// Deletes a remote workroom (#253): runs its teardown script on a ready host (`teardown`), takes
  /// down what its record says is live (`isLive`), then has the CLI drop the entry
  /// (`Recorder.forget`). The app's connection to the box goes first; a pane's own ssh goes with the
  /// box. `onForgotten` hears what went, at the step it went.
  ///
  /// A teardown script that fails, or a host that can't be reached to run it, stops the delete with
  /// nothing taken down (`Failure.teardownScriptFailed`), so deleting again retries. When part of the
  /// host's own teardown fails, the entry keeps what is still live, as `failed`, so deleting it
  /// again finishes the job. `environment` is needed only for a live one.
  static func delete(
    _ name: String, host: HostDescriptor, environment: RemoteProvisioning.Environment?,
    recorder: Recorder, teardown: Teardown? = nil,
    reachability: HostReachability = RemoteHosts.shared.reachability,
    onForgotten: @escaping @MainActor @Sendable (Forgotten) -> Void
  ) async throws {
    if host.kind == .ssh, !host.isDestroyed {
      return try await deleteSSH(
        name, host: host, environment: environment, recorder: recorder, teardown: teardown,
        reachability: reachability, onForgotten: onForgotten)
    }
    // The entry goes, and the host's port forwards with it (#380): one step for both ways out, so
    // a workroom with nothing live to take down keeps nothing made this launch.
    func forget() async throws {
      if let id = host.id { await onForgotten(.host(.remote(id))) }
      try await recorder.forget(name)
    }
    guard try checkDeletable([host]) else { return try await forget() }
    // `checkDeletable` found it live, so it has a box.
    guard let environment, let id = host.id else { throw Failure.signedOut }
    let box = HostID.remote(id)
    try await runTeardown(
      teardown, of: name, recorded: host, on: box, in: environment, reachability: reachability
    ) {
      // `deletionKey`, as the host's own delete finds its driver: a descriptor from before the
      // `driver` field is Docker's.
      guard let driver = environment.driver as? any HostTerminalDriver,
        let key = try? HostDriverRegistry.deletionKey(host)
      else {
        throw Failure.teardownScriptFailed("teardown script failed: this host's driver is unknown")
      }
      return (key, driver)
    }
    await reachability.disconnect(box)
    do {
      try await RemoteProvisioning.tearDown(host: box, in: environment)
    } catch RemoteProvisioning.Failure.rollbackIncomplete(let cause, let liveHost, let left) {
      var remaining = host
      remaining.lifecycle = .failed
      await recordLeftBehind(liveHost) { try await recorder.record(name, remaining) }
      throw RemoteProvisioning.Failure.rollbackIncomplete(
        cause: cause, host: liveHost, cleanup: left)
    }
    await reachability.forgetRelay(id)
    try await forget()
  }

  /// Runs workroom `name`'s teardown script on `box` before the workroom goes, as the CLI runs a
  /// local one first, through the host's driver and key (`reach`), connecting through
  /// `reachability`. Only on a ready host: one a create left `creating` or a delete left `failed`
  /// may not be whole, and that delete exists to finish taking it down. Never for Delete Anyway. A
  /// script that fails, or isn't approved on this Mac, stops the delete.
  private static func runTeardown(
    _ teardown: Teardown?, of name: String, recorded host: HostDescriptor, on box: HostID,
    in environment: RemoteProvisioning.Environment, reachability: HostReachability,
    reach: () throws -> (key: RemoteHosts.DriverKey, driver: any HostTerminalDriver)
  ) async throws {
    guard let teardown, !teardown.skip, host.lifecycle == .serving else { return }
    let (key, driver) = try reach()
    let request = ScriptRequest(
      script: .teardown, workroom: name, path: teardown.path, host: box, key: key,
      driver: driver, daemonBinary: environment.daemonBinary(on: box),
      rootScript: teardown.rootScript, judge: teardown.judge, onLine: teardown.onLine)
    let run =
      if let fake = teardown.run {
        await fake(request)
      } else {
        await runScript(request, reachability: reachability)
      }
    switch run {
    case .failed(let why): throw Failure.teardownScriptFailed(why)
    case .notTrusted(let script): throw Failure.teardownScriptNotTrusted(script)
    case .absent, .passed: break
    }
  }

  private static func deleteSSH(
    _ name: String, host: HostDescriptor, environment: RemoteProvisioning.Environment?,
    recorder: Recorder, teardown: Teardown?, reachability: HostReachability,
    onForgotten: @escaping @MainActor @Sendable (Forgotten) -> Void
  ) async throws {
    _ = try checkDeletable([host])
    guard let id = host.id, let workroom = host.workroomID,
      let path = teardown?.path ?? host.path,
      let environment, let driver = environment.driver as? any FolderPlacingDriver
    else {
      throw HostDriverError.invalidConfiguration("The SSH workroom's folder record is incomplete")
    }
    let box = HostID.remote(id)
    let state: WorkroomFolderState?
    do {
      // The guard precedes teardown too: its root fallback must never recreate a gone folder.
      state = try await driver.folderState(path: path, workroom: workroom)
    } catch {
      guard teardown?.skip == true else { throw error }
      teardown?.onLine("Left \(path) on \(driver.destination): \(error.localizedDescription)")
      state = nil
    }
    do {
      if state == .present {
        try await runTeardown(
          teardown, of: name, recorded: host, on: box, in: environment, reachability: reachability
        ) {
          (.ssh(destination: driver.destination), driver)
        }
      }
      try await reachability.ensureConnected(box, wake: true)
      for session in try await HostConnectionManager.shared.sessions(on: box)
      where session.value(forMetadataKey: SessionMetadataKey.workroom) == workroom.uuidString {
        if let sessionID = session.identifier.uuid {
          _ = try await HostConnectionManager.shared.endSession(sessionID, on: box)
        }
      }
      if state != nil { try await driver.removeFolder(path: path, workroom: workroom) }
    } catch {
      // Delete Anyway explicitly forgets what could not be removed, naming the folder left there.
      guard teardown?.skip == true || state == .gone else { throw error }
      teardown?.onLine("Left \(path) on \(driver.destination): \(error.localizedDescription)")
    }
    try await recorder.forget(name)
    await onForgotten(.workroom(workroom, on: box))
    // A failed config read keeps the shared connection: dropping it is safe only with evidence.
    guard (try? await recorder.hasWorkrooms(id)) == false else { return }
    await onForgotten(.lastWorkroom(on: box))
    await reachability.disconnect(box)
    await reachability.forgetRelay(id)
  }

  /// Records what a failure left live (a machine). A record that fails too is logged with it named,
  /// since nothing else in the app will remember it (#356).
  private static func recordLeftBehind(_ host: HostID, _ write: () async throws -> Void) async {
    do { try await write() } catch {
      logger.error(
        "could not record \(String(describing: host), privacy: .public) left live: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "RemoteWorkrooms")
}

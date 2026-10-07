import Defaults
import Foundation
import os

/// Remote workrooms in the app (#253): a workroom derived from its project's base machine, on a
/// host the app provisions. A remote workroom always belongs to a project registered on this Mac
/// (design doc, Phase 4: there are no remote projects).
enum RemoteWorkrooms {
  /// Nightly and Dev only, and there only with `Defaults[.remoteWorkroomsPreview]`, until the
  /// Phase 4 success criteria pass on two real providers (design doc, Next Steps item 5). A stable
  /// build shows no remote UI whatever the setting says.
  static var isEnabled: Bool {
    if let enabledForTesting { return enabledForTesting }
    #if DEBUG
      let channel = true
    #else
      let channel = ReleaseChannel.isNightlyBuild
    #endif
    return channel && Defaults[.remoteWorkroomsPreview]
  }

  /// Set by tests in place of `Defaults[.remoteWorkroomsPreview]`: parallel test processes share one
  /// defaults domain, and this is per process.
  nonisolated(unsafe) static var enabledForTesting: Bool?

  /// Which container runtime makes a workroom's host (#309): Docker (Desktop, OrbStack, Colima) or
  /// Apple's `container`. The raw value is the descriptor's `driver`; `container` predates Apple's
  /// and keeps meaning Docker, so every record made before stays Docker's.
  enum Runtime: String, CaseIterable, Sendable {
    case docker = "container"
    case apple = "apple-container"

    var displayName: String { self == .docker ? "Docker" : "Apple Container" }
    /// One of its containers, in a sentence: "a Docker container", "an Apple container".
    var containerPhrase: String { self == .docker ? "a Docker container" : "an Apple container" }
  }

  /// Where a remote workroom is made (#309, #356): a container runtime on this Mac, or boxd.
  enum Place: Hashable, Sendable {
    case container(Runtime)
    case boxd

    var displayName: String {
      switch self {
      case .container(let runtime): runtime.displayName
      case .boxd: "boxd"
      }
    }

    /// One of its hosts, in a sentence: "a Docker container on this Mac", "a boxd machine".
    var hostPhrase: String {
      switch self {
      case .container(let runtime): "\(runtime.containerPhrase) on this Mac"
      case .boxd: "a boxd machine"
      }
    }
  }

  /// Why a workroom can't be created at `place` now, as the New Workroom menu and picker show it
  /// beside the entry, or nil when it can.
  @MainActor
  static func unavailability(of place: Place) -> String? {
    switch place {
    case .container(let runtime): unavailability(of: runtime)
    case .boxd:
      // Only what is cheap to read: this runs in menus' and the picker's bodies. Whether boxd is
      // signed in is a CLI call, so a create checks that (`RemoteHosts.key(for:)`).
      unavailability(
        ofBoxdInstalled: RemoteHosts.boxdExecutable() != nil,
        codasetSignedIn: BrokerSession.shared.isSignedIn)
    }
  }

  /// A boxd workroom fetches and pushes with the broker's tokens, never the Mac's `gh` (OQ20): it
  /// must keep working with the Mac closed. So Codaset is required, where a container is not.
  static func unavailability(ofBoxdInstalled installed: Bool, codasetSignedIn: Bool) -> String? {
    if !installed { return "not installed" }
    if !codasetSignedIn { return "sign in to Codaset" }
    return nil
  }

  /// The descriptor's `driver` for a Docker host.
  static let containerDriver = Runtime.docker.rawValue
  /// The descriptor's `driver` for a boxd host (#356).
  static let boxdDriver = "boxd"

  /// Why a workroom can't be created on `runtime` now, as the New Workroom menu shows it beside the
  /// entry, or nil when it can (#309).
  @MainActor
  static func unavailability(of runtime: Runtime) -> String? {
    var arm64: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let appleSilicon = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0 && arm64 == 1
    return unavailability(
      of: runtime, installed: RemoteHosts.executable(for: runtime) != nil,
      appleSilicon: appleSilicon,
      macOS26: ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)),
      // The session's state, not `client()`: that reads the Keychain and rebuilds the device key,
      // and this runs in menus' and the picker's bodies. A create checks for real.
      signedIn: BrokerSession.shared.isSignedIn || CredentialRelay.hasGitHubSignIn())
  }

  static func unavailability(
    of runtime: Runtime, installed: Bool, appleSilicon: Bool, macOS26: Bool, signedIn: Bool
  ) -> String? {
    if runtime == .apple {
      // Apple's runtime runs each container in a VM of its own, on Apple silicon and macOS 26.
      if !appleSilicon { return "needs Apple silicon" }
      if !macOS26 { return "needs macOS 26" }
    }
    if !installed { return "not installed" }
    // Codaset's broker, or the Mac's own `gh` through the relay (#309).
    if !signedIn { return "sign in to Codaset or run gh auth login" }
    return nil
  }
  /// The descriptor's `provisioner`: this build, whose ssh key and Docker labels its hosts carry.
  static var provisioner: String { Bundle.main.bundleIdentifier ?? "com.developwithstyle.workroom" }
  /// Fixed by the host image's entrypoint (`vcs/scripts/ssh-fixture/entrypoint.sh`).
  static let agentSocket = "/run/workroom/agent.sock"
  static let user = "workroom"

  /// The image a new base runs (#309): the hidden `remoteHostImage` override, else the published
  /// image this build pins by digest (`WorkroomHostImage`, from CI), else a local `workroom-host`,
  /// as `make remote-host-image` builds it for a Dev build.
  static var hostImage: String {
    hostImage(
      override: Defaults[.remoteHostImage],
      pinned: Bundle.main.object(forInfoDictionaryKey: "WorkroomHostImage") as? String)
  }

  static func hostImage(override: String?, pinned: String?) -> String {
    for image in [override, pinned] {
      if let image = image?.trimmingCharacters(in: .whitespaces), !image.isEmpty { return image }
    }
    return "workroom-host"
  }

  /// The branch a remote workroom checks out, as a local workroom's is named.
  static func branch(for name: String) -> String { "workroom/\(name)" }

  /// How a base clones `repository`: over https, which is how the broker's tokens work.
  static func cloneURL(for repository: GitHubRepository) -> String {
    "https://\(repository.host)/\(repository.owner)/\(repository.name).git"
  }

  /// Where a project's base clones its repository on a host of `key`: the home of the user its
  /// driver logs in as (`workroom` in a container, `boxd` on boxd, #356).
  static func clonePath(
    for repository: GitHubRepository, on key: RemoteHosts.DriverKey = .init()
  ) -> String {
    "/home/\(key.isBoxd ? BoxdHostDriver.user : user)/\(repository.name)"
  }

  enum Failure: Error, LocalizedError, Equatable {
    case signedOut
    case notOnGitHub(String)
    case noDocker
    case noAppleContainer
    case baseOnOtherRuntime(String)
    case anotherBuildsBase(String)
    case anotherBuildsHost(String)
    case baseRepositoryChanged(base: String, origin: String)
    case incompleteBase
    case codasetRequired
    case boxdNotInstalled

    var errorDescription: String? {
      switch self {
      case .signedOut:
        return "Sign in to Codaset in Settings → Remote workrooms, or to GitHub with "
          + "`gh auth login`: one of them gives the workroom its GitHub access."
      case .notOnGitHub(let detail):
        return "A remote workroom needs a project whose origin is on github.com. \(detail)"
      case .anotherBuildsBase(let build):
        return "This project's base machine was made by another Workroom build (\(build)), "
          + "whose remote hosts this build can't reach. Create the remote workroom from that build."
      case .anotherBuildsHost(let build):
        return "It runs on a remote host another Workroom build made (\(build)), which this build "
          + "can't take down. Delete it from that build."
      case .baseRepositoryChanged(let base, let origin):
        return
          "This project's base machine is a clone of \(base), but its GitHub repository is now "
          + "\(origin): its origin changed, or the repository was renamed or moved. Its remote "
          + "workrooms would clone \(base). To start over from \(origin), delete the project (its "
          + "remote workrooms and base go with it) and add it again."
      case .incompleteBase:
        return "This project's base machine record is incomplete, so it can't be reused, and "
          + "building another would leave it running unrecorded. Delete the project (its remote "
          + "workrooms and base go with it) and add it again."
      case .codasetRequired:
        return "A boxd workroom fetches and pushes with Codaset's repository tokens, so it keeps "
          + "working with this Mac closed. Sign in to Codaset in Settings → Remote workrooms."
      case .boxdNotInstalled:
        return "The boxd command wasn't found. Install it from boxd.sh, then sign in with "
          + "`boxd auth login`."
      case .noDocker:
        return "No docker command was found. Install Docker Desktop, OrbStack or Colima."
      case .noAppleContainer:
        return "Apple's container command wasn't found. Install it from "
          + "github.com/apple/container, then run `container system start`."
      case .baseOnOtherRuntime(let runtime):
        return "This project's base machine runs on \(runtime), so its workrooms are created there "
          + "too."
      }
    }
  }

  /// The base a workroom on `key` derives from, in a project whose descriptor is `host` (#309): the
  /// one made on that runtime and Docker context, else for Docker one made before #309, which names
  /// no context and follows the current one, as `key` does.
  static func base(in host: HostDescriptor?, for key: RemoteHosts.DriverKey) -> HostDescriptor? {
    let bases = host?.allBases ?? []
    if let exact = bases.first(where: { RemoteHosts.DriverKey($0) == key }) { return exact }
    // Only Docker has an unpinned form; a boxd base belongs to exactly one org and account.
    guard let runtime = key.runtime else { return nil }
    return bases.first { RemoteHosts.DriverKey($0) == RemoteHosts.DriverKey(runtime: runtime) }
  }

  /// A project's descriptor `host` with `base` recorded in it, in place of any base on the same
  /// runtime and context (#309). A project with one base keeps the one-base form.
  static func recording(_ base: HostDescriptor, in host: HostDescriptor?) -> HostDescriptor {
    let key = RemoteHosts.DriverKey(base)
    let others = (host?.allBases ?? []).filter { $0.id != nil && RemoteHosts.DriverKey($0) != key }
    return others.isEmpty ? base : HostDescriptor(bases: others + [base])
  }

  /// A project's descriptor `host` without the base `id`, or nil when it had no other.
  static func removing(_ id: UUID, from host: HostDescriptor?) -> HostDescriptor? {
    let others = (host?.allBases ?? []).filter { $0.id != nil && $0.id != id }
    return others.count > 1 ? HostDescriptor(bases: others) : others.first
  }

  /// The router registrations of `projects`' reachable remote workrooms (#253). Each is its own
  /// shared root on its host, as an independent clone is. Its GitHub identity is its own base's, so
  /// its PR and CI status read through `gh` here: a project's bases on other runtimes may be clones
  /// of another repository, made before its origin changed (#309).
  static func registrations(_ projects: [Project]) -> [RepositoryRouter.Registration] {
    projects.flatMap { project in
      let any = project.host?.allBases.lazy.compactMap(\.repository).first
      return project.workrooms.compactMap { workroom -> RepositoryRouter.Registration? in
        guard let host = workroom.reachableHost,
          let location = try? RepositoryLocation.remote(host: host, path: workroom.path)
        else { return nil }
        let own = workroom.host.flatMap(RemoteHosts.DriverKey.init).flatMap {
          base(in: project.host, for: $0)?.repository
        }
        let github = (own ?? any).flatMap(gitHubRepository)
        return try? RepositoryRouter.Registration(
          location: location, sharedLocation: location, github: github)
      }
    }
  }

  /// A base's `owner/name` (`buildBase`), on github.com, the only host the broker mints for.
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
  }

  /// A workroom the sequence made: its name in config, and its instance.
  struct Created: Sendable {
    let name: String
    let instance: RemoteProvisioning.Instance
  }

  /// Creates a remote workroom for a project (#253): its base first if it has none, then a name
  /// in config, then the derived instance, then the instance's descriptor. The name is taken
  /// before the derive, so the branch is named for it and a crash part-way leaves an entry the
  /// user can see and delete; anything the crash left on the host is the sweep's
  /// (`RemoteHosts.adopt`).
  ///
  /// When the derive fails and undid itself, the entry is dropped. When undoing it failed too,
  /// the entry keeps what is still live (host, grant) so deleting it can finish the job.
  static func create(
    repository: GitHubRepository, cloneURL: String, base existing: HostDescriptor?,
    project projectHost: HostDescriptor? = nil, key: RemoteHosts.DriverKey = .init(),
    driver: any HostTerminalDriver,
    environment: RemoteProvisioning.Environment, recorder: Recorder
  ) async throws -> Created {
    let base: RemoteProvisioning.Base
    if let existing, existing.provisioner != provisioner {
      // Its key and labels are another build's, so this one can neither reach nor replace it.
      throw Failure.anotherBuildsBase(existing.provisioner ?? "an unknown build")
    }
    // A workroom is derived from its base, on the base's driver: a base of another runtime, or of
    // boxd when the workroom isn't (or the reverse), is never derived from (#356).
    if let existing, existing.id != nil {
      let other = (try? RemoteHosts.deletionKey(existing)) ?? .init()
      if other.runtime != key.runtime {
        throw Failure.baseOnOtherRuntime(other.place.displayName)
      }
    }
    if let recorded = existing?.base {
      // Reused only for the repository it cloned: a changed origin would otherwise get workrooms of
      // the old one, with credentials for it.
      let origin = "\(repository.owner)/\(repository.name)"
      // GitHub names are case-insensitive.
      guard recorded.repository.lowercased() == origin.lowercased() else {
        throw Failure.baseRepositoryChanged(base: recorded.repository, origin: origin)
      }
      base = recorded
    } else if existing?.id != nil {
      // A host is recorded but not enough of it to derive from: a second base would leave this one
      // live with nothing pointing at it.
      throw Failure.incompleteBase
    } else {
      base = try await RemoteProvisioning.buildBase(
        repository: "\(repository.owner)/\(repository.name)",
        cloneURL: cloneURL,
        path: clonePath(for: repository, on: key), in: environment
      ) { base in
        // Beside the project's bases on other runtimes and contexts (#309).
        var descriptor = describing(
          .remote(base.host), key: key, driver: driver, credentials: base.relayed)
        descriptor.repository = base.repository
        descriptor.cloneURL = base.cloneURL
        descriptor.path = base.path
        try await recorder.record(nil, recording(descriptor, in: projectHost))
      }
    }

    let workroomID = UUID()
    let name = try await recorder.reserve(
      base.path,
      HostDescriptor(
        state: "creating", driver: driverName(key), provisioner: provisioner,
        workroomID: workroomID, org: key.org, account: key.account))
    let instance: RemoteProvisioning.Instance
    do {
      instance = try await RemoteProvisioning.derive(
        from: base, workroom: workroomID, branch: branch(for: name), in: environment
      ) { host, grant in
        // Still `creating`, but now naming what a delete has to take down.
        try await recorder.record(
          name,
          remaining(
            state: "creating", workroomID: workroomID, host: host, grant: grant, key: key,
            driver: driver))
      }
    } catch RemoteProvisioning.Failure.rollbackIncomplete(let cause, let host, let grant, let left)
    {
      // `destroyed` only with nothing live: the CLI deletes a destroyed entry, and a live grant
      // must keep its record until the app's delete cancels it.
      try? await recorder.record(
        name,
        remaining(
          state: host == nil && grant == nil ? "destroyed" : "failed", workroomID: workroomID,
          host: host, grant: grant, key: key, driver: driver))
      throw RemoteProvisioning.Failure.rollbackIncomplete(
        cause: cause, host: host, grantID: grant, cleanup: left)
    } catch {
      try? await recorder.forget(name)
      throw error
    }

    guard case .remote = instance.host else {
      throw HostDriverError.unknownHost(instance.host)
    }
    do {
      var descriptor = describing(
        instance.host, key: key, driver: driver, credentials: base.relayed)
      descriptor.grantID = instance.grantID
      descriptor.workroomID = workroomID
      try await recorder.record(name, descriptor)
    } catch {
      // Unrecorded, the instance would be found by nothing but the sweep, and its grant by nothing.
      do {
        try await RemoteProvisioning.destroy(instance, workroom: workroomID, in: environment)
      } catch RemoteProvisioning.Failure.rollbackIncomplete(_, let host, let grant, _) {
        // Something is still live: the entry stays, `failed`, for delete to finish.
        try? await recorder.record(
          name,
          remaining(
            state: "failed", workroomID: workroomID, host: host, grant: grant, key: key,
            driver: driver))
        throw error
      } catch {
        // `destroy` throws nothing else: everything it made is gone.
      }
      try? await recorder.forget(name)
      throw error
    }
    return Created(name: name, instance: instance)
  }

  /// The descriptor of a workroom whose undoing left `host` and `grant` live.
  private static func remaining(
    state: String, workroomID: UUID, host: HostID?, grant: String?, key: RemoteHosts.DriverKey,
    driver: any HostTerminalDriver
  ) -> HostDescriptor {
    var descriptor = HostDescriptor(
      state: state, driver: driverName(key), provisioner: provisioner, grantID: grant,
      workroomID: workroomID, org: key.org, account: key.account)
    if case .remote(let id) = host {
      descriptor.id = id
      descriptor.container = (driver as? ContainerHostDriver)?.record(of: .remote(id))
    }
    return descriptor
  }

  /// A live host's descriptor on `key`: its driver, this build, and how `key`'s driver finds it
  /// again (a container record, or a boxd org and account).
  private static func describing(
    _ host: HostID, key: RemoteHosts.DriverKey, driver: any HostTerminalDriver, credentials: Bool?
  ) -> HostDescriptor {
    var descriptor = HostDescriptor(
      driver: driverName(key), provisioner: provisioner,
      container: (driver as? ContainerHostDriver)?.record(of: host),
      credentials: credentials == true ? "relay" : nil, org: key.org, account: key.account)
    if case .remote(let id) = host { descriptor.id = id }
    return descriptor
  }

  /// The descriptor's `driver` for `key`.
  static func driverName(_ key: RemoteHosts.DriverKey) -> String {
    key.runtime?.rawValue ?? boxdDriver
  }

  /// Whether `host` records anything still up: a box or a grant. A destroyed one has nothing, and
  /// neither has one a create left at `creating` before its derive made a box, whose container (if
  /// any) the sweep takes once no record names it.
  static func isLive(_ host: HostDescriptor) -> Bool {
    !host.isDestroyed && (host.id != nil || host.grantID != nil)
  }

  /// Refuses to take down `hosts` when one that is live is another build's: its key and labels are
  /// not this build's (`create`). Returns whether any of them is live, so needs an environment.
  @discardableResult
  static func checkDeletable(_ hosts: [HostDescriptor]) throws -> Bool {
    let live = hosts.filter(isLive)
    if let other = live.first(where: { $0.provisioner != provisioner }) {
      throw Failure.anotherBuildsHost(other.provisioner ?? "an unknown build")
    }
    return !live.isEmpty
  }

  /// Deletes a remote workroom (#253): takes down what its record says is live (`isLive`), then has
  /// the CLI drop the entry (`Recorder.forget`). The app's connection to the box goes first; a
  /// pane's own ssh goes with the box.
  ///
  /// When part of the teardown fails, the entry keeps what is still live, as `failed`, so deleting
  /// it again finishes the job. `environment` is needed only for a live one.
  static func delete(
    _ name: String, host: HostDescriptor, environment: RemoteProvisioning.Environment?,
    recorder: Recorder
  ) async throws {
    // The entry goes, and the host's prompt watch with it (#257): one step for both ways out, so a
    // workroom with nothing live to take down does not keep a model made earlier this launch.
    func forget() async throws {
      if let id = host.id { await MainActor.run { WakefulnessModel.forgetHost(id) } }
      try await recorder.forget(name)
    }
    guard try checkDeletable([host]) else { return try await forget() }
    guard let environment else { throw Failure.signedOut }
    let box = host.id.map(HostID.remote)
    if let box, let lease = await HostConnectionManager.shared.snapshot(for: box).lease {
      await HostConnectionManager.shared.disconnect(lease)
    }
    do {
      try await RemoteProvisioning.tearDown(
        host: box, grantID: host.grantID, workroom: host.workroomID, in: environment)
    } catch RemoteProvisioning.Failure.rollbackIncomplete(
      let cause, let liveHost, let grant, let left)
    {
      var remaining = host
      remaining.state = "failed"
      remaining.grantID = grant
      if liveHost == nil {
        // The box is gone though its grant is not: the record forgets the host, so a later delete
        // could not find its prompt watch to stop (#257).
        if let id = host.id { await MainActor.run { WakefulnessModel.forgetHost(id) } }
        (remaining.id, remaining.container) = (nil, nil)
      }
      try? await recorder.record(name, remaining)
      throw RemoteProvisioning.Failure.rollbackIncomplete(
        cause: cause, host: liveHost, grantID: grant, cleanup: left)
    }
    if let id = host.id { await RemoteHosts.shared.forgetRelay(id) }
    try await forget()
  }

  /// Destroys a project's base (#253), for an explicit project delete, then clears its record
  /// (`clear`). Its workrooms go first: config keeps a project with a base when its last workroom is
  /// removed, and only while it has one.
  static func deleteBase(
    _ host: HostDescriptor, environment: RemoteProvisioning.Environment?,
    clear: @Sendable () async throws -> Void
  ) async throws {
    guard try checkDeletable([host]), let id = host.id else { return try await clear() }
    guard let environment else { throw Failure.signedOut }
    try await RemoteProvisioning.destroyBase(id, in: environment, forget: clear)
  }
}

/// The app's remote hosts (#253): a `ContainerHostDriver` per container runtime and Docker context
/// on this Mac (#309), the hosts config records adopted into theirs at each reload, and one sweep
/// per launch for what no record names.
final class RemoteHosts: @unchecked Sendable {
  static let shared = RemoteHosts()

  private let lock = NSLock()
  /// Which driver a host is in (#309, #356): a container runtime on this Mac, and for Docker the
  /// context it names (nil names none); or a boxd org (nil is the account's own) and account.
  enum DriverKey: Hashable, Sendable {
    case container(RemoteWorkrooms.Runtime, context: String?)
    case boxd(org: String?, account: String?)

    /// The driver a recorded host is in, or nil for a descriptor of no driver this build knows.
    init?(_ descriptor: HostDescriptor) {
      if descriptor.driver == RemoteWorkrooms.boxdDriver {
        self = .boxd(org: descriptor.org, account: descriptor.account)
        return
      }
      guard let runtime = RemoteWorkrooms.Runtime(rawValue: descriptor.driver ?? "") else {
        return nil
      }
      self.init(runtime: runtime, context: descriptor.container?.context)
    }

    init(runtime: RemoteWorkrooms.Runtime = .docker, context: String? = nil) {
      // Apple's runtime has no contexts.
      self = .container(runtime, context: runtime == .docker ? context : nil)
    }

    /// Whether the key names a boxd account rather than a container runtime.
    var isBoxd: Bool {
      if case .boxd = self { return true }
      return false
    }

    /// The container runtime, or nil for boxd.
    var runtime: RemoteWorkrooms.Runtime? {
      if case .container(let runtime, _) = self { return runtime }
      return nil
    }

    /// The Docker context a container key names; nil for none, and for boxd.
    var context: String? {
      if case .container(_, let context) = self { return context }
      return nil
    }

    /// A boxd key's org and account; nil for a container key.
    var org: String? {
      if case .boxd(let org, _) = self { return org }
      return nil
    }
    var account: String? {
      if case .boxd(_, let account) = self { return account }
      return nil
    }

    /// Where this key's workrooms are made.
    var place: RemoteWorkrooms.Place { runtime.map(RemoteWorkrooms.Place.container) ?? .boxd }
  }

  /// The drivers made so far.
  private var made: [DriverKey: any HostTerminalDriver] = [:]
  /// The driver each host config records it in, whether or not that driver has been made.
  private var keys: [UUID: DriverKey] = [:]
  /// Workroom hosts whose git credentials come through the Mac's relay (#309).
  private var relayed: Set<UUID> = []
  private var swept = false
  /// A call reached the sweep while a delete was in flight and left it for later (#296).
  private var held = false
  /// The connection attempt running for each host, which `ensureConnected` callers share, and
  /// whether it starts a stopped container first.
  private var connecting: [HostID: (task: Task<Void, Error>, starts: Bool)] = [:]
  /// When each host's last attempt failed, which answers for it for `retryAfter`.
  private var failedAt: [HostID: ContinuousClock.Instant] = [:]
  /// When boxd last said each host was asleep, which answers for it for `retryAfter` (#356).
  private var asleepAt: [HostID: ContinuousClock.Instant] = [:]
  /// boxd hosts the app let go of because they reported IDLE while not selected (#356): boxd counts
  /// inbound traffic as activity, so a connection's ssh keepalives and the badge's polls kept an
  /// idle box awake for good (measured, eng review D8). Each with when it was let go of: a background
  /// read never reconnects one inside `revisitAfter(_:)` of that; selecting or opening its
  /// workroom, or a click (`wake`), does.
  private var letGoAt: [HostID: ContinuousClock.Instant] = [:]
  /// When the app last connected each host, which an IDLE reading must outlast to let it go.
  private var connectedAt: [HostID: ContinuousClock.Instant] = [:]
  /// Each boxd host's idle window as its provider last said, read on connect.
  private var idleWindows: [HostID: TimeInterval] = [:]
  /// The host of the workroom selected in each window (one `AppStore` per window), none of which
  /// is ever let go of.
  private var selectedHosts: [AnyHashable: HostID] = [:]
  /// Hosts of workrooms the user has opened this launch (`activate`), whose connect starts a
  /// stopped container first.
  private var activated: Set<HostID> = []
  /// Relayed hosts whose relay couldn't be set up on their connection, and when that was last
  /// tried (#309): nothing else tries again before a reconnect, so a connection check does.
  private var relayPending: [UUID: ContinuousClock.Instant] = [:]
  /// `ensureConnected`'s seams, nil in the app: the connect itself, whether a host is up, the clock.
  private let connectHost: (@Sendable (HostID) async throws -> Void)?
  /// Sets up a relayed host's credential relay on its connection; nil in the app.
  private let relayHost: (@Sendable (HostID) async throws -> Void)?
  /// `connect`'s agent connection, bootstrap included; nil in the app (`AgentBootstrap.connect`).
  private let connectAgent:
    (@Sendable (HostID, any HostTerminalDriver) async throws -> AgentVCSConnection)?
  private let isConnected: (@Sendable (HostID) async -> Bool)?
  /// What boxd says of a boxd host (`BoxdHostDriver.presence`); nil in the app.
  private let presenceSeam: (@Sendable (HostID) async -> BoxdHostDriver.Presence?)?
  private let startHost: (@Sendable (HostID) async throws -> Void)?
  private let now: @Sendable () -> ContinuousClock.Instant
  /// `adopt`'s seams, nil in the app: making a key's driver, and sweeping one.
  private let makeDriver: (@Sendable (DriverKey) throws -> any HostTerminalDriver)?
  private let sweepDriver:
    (@Sendable (ContainerHostDriver, Set<UUID>, Set<String>) async -> [String])?

  init(
    connectHost: (@Sendable (HostID) async throws -> Void)? = nil,
    isConnected: (@Sendable (HostID) async -> Bool)? = nil,
    startHost: (@Sendable (HostID) async throws -> Void)? = nil,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    makeDriver: (@Sendable (DriverKey) throws -> any HostTerminalDriver)? = nil,
    sweepDriver: (@Sendable (ContainerHostDriver, Set<UUID>, Set<String>) async -> [String])? = nil,
    relayHost: (@Sendable (HostID) async throws -> Void)? = nil,
    connectAgent: (@Sendable (HostID, any HostTerminalDriver) async throws -> AgentVCSConnection)? =
      nil,
    presence: (@Sendable (HostID) async -> BoxdHostDriver.Presence?)? = nil
  ) {
    self.presenceSeam = presence
    self.connectHost = connectHost
    self.relayHost = relayHost
    self.connectAgent = connectAgent
    self.isConnected = isConnected
    self.startHost = startHost
    self.now = now
    self.makeDriver = makeDriver
    self.sweepDriver = sweepDriver
  }

  /// How long a failed connect answers for its host before another is tried. The status sweep and
  /// every panel ask again, and each attempt at a host that is down waits out ssh's connect
  /// timeout. ponytail: a fixed window, so a Reload inside it fails fast too; upgrade path: let a
  /// read the user asked for bypass it.
  static let retryAfter: Duration = .seconds(30)
  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "RemoteWorkrooms")

  /// The driver for `key`, made on first use. A container driver needs that runtime's CLI and this
  /// Mac's ssh key; a boxd driver reaches its hosts through the ssh details the boxd CLI wrote, so
  /// making one never fails (#356). The default key is Docker naming no context, as every driver
  /// did before #309. Each driver writes its hosts' ssh files under their own IDs, so they share
  /// one directory.
  func driver(_ key: DriverKey = DriverKey()) throws -> any HostTerminalDriver {
    try lock.withLock {
      if let made = made[key] { return made }
      let hosts = Self.directory.appendingPathComponent("hosts", isDirectory: true)
      let driver: any HostTerminalDriver
      if let makeDriver {
        driver = try makeDriver(key)
      } else if case .boxd(let org, let account) = key {
        let cli = Self.boxdExecutable()
        driver = BoxdHostDriver(
          configuration: BoxdHostDriver.Configuration(
            cli: URL(fileURLWithPath: cli ?? Self.boxdCandidates[0]), org: org, account: account),
          directory: hosts)
        // Not kept while the CLI is missing, so installing it later takes without a relaunch.
        guard cli != nil else { return driver }
      } else {
        driver = ContainerHostDriver(
          hosts: [:], directory: hosts, provisioning: try Self.provisioning(key))
      }
      made[key] = driver
      return driver
    }
  }

  /// `key`'s driver, which must be a container runtime's: adopting, sweeping, starting and naming
  /// contexts are theirs alone.
  private func containerDriver(_ key: DriverKey = DriverKey()) throws -> ContainerHostDriver {
    guard let driver = try driver(key) as? ContainerHostDriver else {
      throw HostDriverError.invalidConfiguration("\(key) is not a container runtime")
    }
    return driver
  }

  /// Whether this call runs the launch's one sweep. A call that isn't allowed leaves it for the
  /// next.
  func claimSweep(allowed: Bool) -> Bool {
    return lock.withLock {
      guard allowed else {
        held = held || !swept
        return false
      }
      defer { swept = true }
      return !swept
    }
  }

  /// Whether a sweep was held back and has yet to run. False when no call has reached the sweep,
  /// so a launch with nothing recorded never reads config again for one.
  var sweepHeld: Bool { lock.withLock { held && !swept } }

  /// The driver that holds host `id`, for a pane, which must not probe Docker: nil when no driver
  /// made so far has it. A boxd host's driver is made here if need be: it reaches the host by name,
  /// with nothing to adopt and no runtime to probe (#356).
  func existingDriver(holding id: UUID) -> (any HostTerminalDriver)? {
    let key = lock.withLock { keys[id] }
    if let key, case .boxd = key { return try? driver(key) }
    return lock.withLock {
      made.values.first { ($0 as? ContainerHostDriver)?.record(of: .remote(id)) != nil }
    }
  }

  /// Takes on every host `projects` record, each into the driver for its Docker context, so their
  /// panes and services reach them after a relaunch, then sweeps once per launch what carries this
  /// app's labels and no record names. Does nothing, and never touches Docker, when nothing is
  /// recorded and nothing has been made. `sweep: false` holds the sweep for a later call: a list
  /// with a delete in flight leaves out hosts config still records (#296).
  func adopt(_ projects: [Project], sweep: Bool = true) {
    let descriptors =
      projects.flatMap { $0.host?.allBases ?? [] }
      + projects.flatMap { $0.workrooms.compactMap(\.host) }
    // Another build's hosts take another key: adopted here, they would refuse every login.
    let recorded = descriptors.filter {
      DriverKey($0) != nil && $0.provisioner == RemoteWorkrooms.provisioner
    }
    // Only a base is derived from; on Apple nothing in its record says which a host is.
    let bases = Set(projects.flatMap { $0.host?.allBases.compactMap(\.id) ?? [] })
    let already = lock.withLock {
      for descriptor in recorded {
        if let id = descriptor.id, let key = DriverKey(descriptor) { keys[id] = key }
        // A base never has git ask for credentials; only its workrooms are relayed.
        if let id = descriptor.id, descriptor.isRelayed, !bases.contains(id) { relayed.insert(id) }
      }
      return Set(made.keys)
    }
    guard !recorded.isEmpty || !already.isEmpty else { return }
    // A descriptor with no container record yet goes to its runtime's driver that names no
    // context, where the one driver before #309 would have had it.
    // A boxd host needs no adopting: its driver reaches it by name. Nor is boxd swept: machine
    // names carry no build, so one build's sweep would take another's live workrooms (#284).
    // gstack-shortcut(dec-boxd-no-sweep): a crashed create can leave a paid boxd machine running,
    // upgrade when #284 makes sweeps safe and boxd machine names carry the build.
    let keys = already.union(recorded.compactMap(DriverKey.init)).filter { $0.runtime != nil }
    var drivers: [ContainerHostDriver] = []
    for key in keys {
      let driver: ContainerHostDriver
      do { driver = try containerDriver(key) } catch {
        // That runtime isn't installed; another's may be.
        Self.logger.error("remote hosts: \(error.localizedDescription, privacy: .public)")
        continue
      }
      drivers.append(driver)
      for descriptor in recorded where !descriptor.isDestroyed && DriverKey(descriptor) == key {
        guard let id = descriptor.id, let record = descriptor.container,
          driver.record(of: .remote(id)) == nil
        else { continue }
        do { try driver.adopt(id, record, isBase: bases.contains(id)) } catch {
          Self.logger.error("adopting host \(id, privacy: .public): \(error, privacy: .public)")
        }
      }
    }
    guard claimSweep(allowed: sweep) else { return }
    // Every driver keeps every recorded host, not only its own: two contexts can name one daemon
    // (the nil driver's current context and that context by name), and a sweep that kept only its
    // own hosts would remove the other's, labelled as this build's and old enough.
    let known = Set(recorded.compactMap(\.id))
    let images = Set(recorded.compactMap { $0.container?.image })
    let sweep = sweepDriver ?? { await $0.sweep(keeping: $1, images: $2) }
    // At once: a context whose daemon is slow to answer holds up no other context's sweep.
    Task.detached(priority: .utility) {
      await withTaskGroup(of: [String].self) { group in
        for driver in drivers { group.addTask { await sweep(driver, known, images) } }
        for await failures in group {
          for failure in failures {
            Self.logger.error("remote host sweep: \(failure, privacy: .public)")
          }
        }
      }
    }
  }

  /// The driver key a new workroom at `place` wants: a container runtime's (`key(for:)` below), or
  /// for boxd the org and account it is signed in to now (#356).
  func key(for place: RemoteWorkrooms.Place) async throws -> DriverKey {
    switch place {
    case .container(let runtime): return try await key(for: runtime)
    case .boxd:
      // The org and account boxd is signed in to now, which a new base is made in. Throws, naming
      // `boxd auth login`, when nobody is signed in.
      guard let cli = Self.boxdExecutable() else { throw RemoteWorkrooms.Failure.boxdNotInstalled }
      let account = try await BoxdHostDriver(
        configuration: .init(cli: URL(fileURLWithPath: cli)), directory: Self.directory
      ).signedIn()
      return .boxd(org: account.activeOrg, account: try account.requiredUserID())
    }
  }

  /// The driver key a new workroom on `runtime` wants (#309): Apple's runtime has one, and Docker's
  /// is the context the CLI uses now, which a new base is pinned to. `RemoteWorkrooms.base(in:for:)`
  /// then finds the project's base there, if it has one.
  func key(for runtime: RemoteWorkrooms.Runtime) async throws -> DriverKey {
    guard runtime == .docker else { return DriverKey(runtime: runtime) }
    return DriverKey(runtime: .docker, context: try await containerDriver().currentContext())
  }

  /// The sequence's environment over `key`'s driver, signed in as this Mac.
  @MainActor
  func environment(_ key: DriverKey = DriverKey()) throws -> (
    any HostTerminalDriver, RemoteProvisioning.Environment
  ) {
    // Signed out of Codaset, a local container workroom's git credentials come from the Mac's own
    // `gh` instead (#309). A remote host's never do: it must fetch and push with the Mac closed,
    // so it takes the broker's repo-scoped tokens only (OQ20, #356).
    let client = BrokerSession.shared.client()
    let driver = try driver(key)
    var environment = RemoteProvisioning.Environment(
      driver: driver, agentSocket: Self.agentSocket(of: driver), client: client,
      gitHubToken: key.isBoxd ? nil : CredentialRelay.gitHubToken)
    #if DEBUG
      // A Debug agent reaches this Mac's Codaset through a listener on its host, which lives on
      // the host's service connection (`BrokerReverseForwards`), so that connection comes first.
      let standard = environment.agentBroker
      environment.agentBroker.url = { client, workroom, host in
        try await self.connect(host, driver: driver)
        return try await standard.url(client, workroom, host)
      }
    #endif
    return (driver, environment)
  }

  /// What deleting `hosts` needs, checked before anything is removed (#253): an environment per
  /// runtime and Docker context they are on (#309), or nil when none of them is live. Throws when
  /// signed out or without a runtime they need. Refuses one another build made
  /// (`RemoteWorkrooms.checkDeletable`).
  @MainActor
  func environment(toDelete hosts: [HostDescriptor], bases: Set<UUID> = []) throws -> Deletion? {
    guard try RemoteWorkrooms.checkDeletable(hosts) else { return nil }
    var environments: [DriverKey: RemoteProvisioning.Environment] = [:]
    for host in hosts where RemoteWorkrooms.isLive(host) {
      let key = try Self.deletionKey(host)
      if environments[key] == nil { environments[key] = try environment(key).1 }
      // Taking a box down needs it on its driver, whatever a reload adopted: with previews off it
      // adopted nothing, and the box would read as unknown. A boxd driver needs nothing adopted.
      guard key.runtime != nil else { continue }
      let driver = try containerDriver(key)
      guard let id = host.id, let record = host.container, driver.record(of: .remote(id)) == nil
      else { continue }
      // Whether it is a base sticks for the launch: a later create derives from it.
      do { try driver.adopt(id, record, isBase: bases.contains(id)) } catch {
        Self.logger.error("adopting host \(id, privacy: .public): \(error, privacy: .public)")
      }
    }
    return environments.isEmpty ? nil : Deletion(environments: environments)
  }

  /// The driver a host to take down is in. A descriptor that names no driver predates the field
  /// and is Docker's; one naming a driver this build doesn't know is refused, never taken down
  /// with another driver (a boxd host once fell back to Docker here).
  static func deletionKey(_ host: HostDescriptor) throws -> DriverKey {
    if let key = DriverKey(host) { return key }
    guard host.driver == nil else {
      throw HostDriverError.invalidConfiguration(
        "this build doesn't know how to take down a \(host.driver ?? "") host")
    }
    return DriverKey()
  }

  /// The environments a delete takes hosts down with, one per driver key.
  struct Deletion {
    let environments: [DriverKey: RemoteProvisioning.Environment]

    /// The environment for `host`, or nil when it isn't live and needs none.
    func environment(for host: HostDescriptor) -> RemoteProvisioning.Environment? {
      (try? RemoteHosts.deletionKey(host)).flatMap { environments[$0] }
    }
  }

  /// The app's service connection to `host` (`HostConnectionManager`), with its agent bootstrapped
  /// first. One already there is kept.
  func connect(_ host: HostID, driver: any HostTerminalDriver) async throws {
    _ = try await HostConnectionManager.shared.connectIfDisconnected(host: host) {
      [connectAgent] in
      if let connectAgent { return try await connectAgent(host, driver) }
      return try await AgentBootstrap.connect(
        host: host, driver: driver, socket: Self.agentSocket(of: driver))
    }
    // Its ceiling prompts are watched from here (#257): the agent was just handed this Mac's
    // ask-at-ceiling setting, and a prompt nobody shows lets the box sleep under a running job.
    if case .remote(let id) = host {
      await MainActor.run {
        WakefulnessModel.model(forHost: id).hostSleeps = driver.traits.sleepsWhenIdle
      }
      // A provider timer shorter than the heartbeat can beat sleeps a box under a running job
      // however healthy the heartbeat is, so the badge says so (#356). Read on every connect, as
      // a machine's timers can change; not awaited, as the CLI call must not hold up the connect.
      if let boxd = driver as? BoxdHostDriver {
        // Its verdict is polled while it is connected, whatever is on screen, so an IDLE one lets
        // it go (`observed`).
        // Stamped before the poll starts, so its first reading already sees the grace.
        lock.withLock { connectedAt[host] = now() }
        await MainActor.run { WakefulnessModel.model(forHost: id).pollWhileConnected() }
        Task {
          // A failed read keeps the window last read, rather than forgetting it; an answer with no
          // timer set (or none boxd would use) clears it.
          let window: TimeInterval?
          do { window = try await boxd.idleWindow(host) } catch { return }
          lock.withLock { idleWindows[host] = window }
          await MainActor.run { WakefulnessModel.model(forHost: id).idleWindow = window }
        }
      }
    }
    // A relayed workroom's git asks this Mac for credentials (#309): its listener goes with the
    // connection, and its secret with this launch, so it is set up again on every connect. A
    // failure leaves the workroom usable except for git's remote commands, so it is logged.
    guard case .remote(let id) = host, isRelayed(id) else { return }
    // Tried a few times: a listen can lose a race with the last connection's teardown.
    await installRelay(host, attempts: 3, driver: driver)
  }

  /// Sets up `host`'s credential relay on its connection, up to `attempts` times. One that never
  /// takes is left pending, for a later connection check to try again.
  func installRelay(
    _ host: HostID, attempts: Int, driver: (any HostTerminalDriver)? = nil
  ) async {
    guard case .remote(let id) = host else { return }
    for attempt in 1...attempts {
      do {
        if let relayHost {
          try await relayHost(host)
        } else {
          let held = try driver ?? heldDriver(host)
          try await CredentialRelay.shared.install(
            on: host, driver: held,
            agentBinary: AgentBootstrap.binary(besideSocket: Self.agentSocket(of: held)))
        }
        _ = lock.withLock { relayPending.removeValue(forKey: id) }
        return
      } catch {
        Self.logger.error(
          "credential relay for \(id, privacy: .public) (attempt \(attempt)): \(error.localizedDescription, privacy: .public)"
        )
        if attempt < attempts { try? await Task.sleep(for: .seconds(1)) }
      }
    }
    lock.withLock { relayPending[id] = now() }
  }

  /// A relayed workroom's host is gone: its relay with it (#309).
  func forgetRelay(_ id: UUID) async {
    guard lock.withLock({ relayed.remove(id) }) != nil else { return }
    await CredentialRelay.shared.close(id)
  }

  /// Whether host `id` is a workroom whose git credentials come through the Mac's relay (#309).
  func isRelayed(_ id: UUID) -> Bool { lock.withLock { relayed.contains(id) } }

  /// Connects `host`'s service connection unless it is up, for a read, write or listing that needs
  /// it (`RepositoryRouter`). One attempt per host at a time: the inspector's panels ask together
  /// when a remote workroom is selected, and every caller after the first waits for that attempt
  /// rather than fail, as `connectIfDisconnected` would have it while one is running.
  ///
  /// Any failure is `RepositoryRoutingError.unavailable`, which every panel shows as the host being
  /// out of reach. Untyped, a stopped host's ssh failure read as "Not a repository". The cause is
  /// logged.
  ///
  /// `wake` for a click (closing a pane, Keep awake): the user asked for this host, so a boxd box
  /// let go of or asleep is connected, and woken, rather than refused as a background read is.
  func ensureConnected(_ host: HostID, wake: Bool = false) async throws {
    guard case .remote = host else { return }
    // A click is tried whatever came of the last attempt, as an opened host is: waking a box can
    // fail once while it resumes, and a second click must not wait out the window. Cleared before
    // the connection is looked at, so a click that lands while a let-go's disconnect is in flight
    // still takes the host back.
    if wake {
      lock.withLock {
        letGoAt[host] = nil
        asleepAt[host] = nil
        failedAt[host] = nil
      }
    }
    let up: Bool
    if let isConnected {
      up = await isConnected(host)
    } else {
      up = await HostConnectionManager.shared.snapshot(for: host).status == .connected
    }
    // An opened host is up already: there is nothing to start, and later probes mustn't start it.
    if up {
      _ = lock.withLock { activated.remove(host) }
      // A relay that didn't take on this connection is tried again, at most once a `retryAfter`.
      if case .remote(let id) = host,
        let tried = lock.withLock({ relayPending[id] }), now() - tried >= Self.retryAfter
      {
        await installRelay(host, attempts: 1)
      }
      return
    }
    // An opened host is tried whatever a probe of it found: its connect starts it.
    let opened = lock.withLock { activated.contains(host) }
    // A selected workroom's box is reached as an opened one is: it is on screen, and a Mac waking
    // from sleep must not leave it reading as asleep until it is selected again.
    let selected = lock.withLock { selectedHosts.values.contains(host) }
    if !wake, !opened, let failed = lock.withLock({ failedAt[host] }),
      now() - failed < Self.retryAfter
    {
      throw RepositoryRoutingError.unavailable(host)
    }
    // A boxd box wakes on an ssh login, so a background read must not connect to one that is
    // asleep: every status sweep would wake every box and keep it billing (#356). Only opening the
    // workroom, or a click (`wake`), wakes it. When boxd can't say, the read goes ahead as before.
    // Nor does one reconnect a box let go of as idle until its idle window has passed, which would
    // hold it awake again: then boxd is asked again, and a box it says is still awake has something
    // on it holding it (work resumed), so it is connected again and its ceiling prompts are heard.
    // One boxd says is gone is reported as such, not as asleep.
    if !opened, !wake, !selected, let since = lock.withLock({ letGoAt[host] }) {
      guard now() - since >= revisitAfter(host) else { throw RepositoryRoutingError.idle(host) }
      _ = lock.withLock { letGoAt.removeValue(forKey: host) }
    }
    if !opened, !wake, !selected {
      switch try await boxdPresence(host) {
      case .asleep: throw RepositoryRoutingError.asleep(host)
      case .gone:
        lock.withLock { failedAt[host] = now() }
        throw RepositoryRoutingError.gone(host)
      case .awake, nil: break
      }
    }
    do {
      let connect =
        try connectHost ?? { [driver = try heldDriver(host)] in
          try await self.connect($0, driver: driver)
        }
      // Only a workroom the user opened has its container started: the status sweep connects to
      // every remote workroom, and would otherwise start them all.
      let start =
        lock.withLock({ activated.contains(host) })
        ? try startHost ?? { [driver = try heldDriver(host)] in
          // A boxd box needs no start: the connect's ssh login wakes it.
          try await (driver as? ContainerHostDriver)?.startIfStopped($0)
        }
        : nil
      let task = lock.withLock { () -> Task<Void, Error> in
        if let running = connecting[host], running.starts || start == nil { return running.task }
        // A probe that won't start the container is under way: joined, it would fail on a stopped
        // one and hold the opened workroom back for `retryAfter`. This one goes after it instead.
        let probe = connecting[host]?.task
        let task = Task {
          // Once, whatever comes of it: a container the user stops later, or one that won't start,
          // is left to the status sweep's backoff until its workroom is opened again.
          defer { if start != nil { _ = self.lock.withLock { self.activated.remove(host) } } }
          if let probe, (try? await probe.value) != nil { return }
          try await start?(host)
          try await connect(host)
        }
        connecting[host] = (task, start != nil)
        return task
      }
      defer { lock.withLock { if connecting[host]?.task == task { connecting[host] = nil } } }
      try await task.value
      lock.withLock {
        failedAt[host] = nil
        connectedAt[host] = now()
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      lock.withLock { failedAt[host] = now() }
      Self.logger.error(
        "connecting \(String(describing: host), privacy: .public): \(error, privacy: .public)")
      throw RepositoryRoutingError.unavailable(host)
    }
  }

  /// The user opened a workroom on `host` (#309): its next connect starts its container if it is
  /// stopped (or wakes its boxd box), and a failure from before, such as a status probe of the
  /// stopped container, no longer holds that attempt back.
  func activate(_ host: HostID) {
    lock.withLock {
      activated.insert(host)
      failedAt[host] = nil
      asleepAt[host] = nil
      letGoAt[host] = nil
    }
  }

  /// The workroom selected in `window` is on `host` (nil for one on this Mac, or a window closing).
  /// A host selected in any window is never let go of (#356).
  func select(_ host: HostID?, in window: AnyHashable = "default") {
    lock.withLock {
      selectedHosts[window] = host
      if let host { letGoAt[host] = nil }
    }
  }

  /// A connected host's agent reported its published verdict (`WakefulnessModel`). A boxd host
  /// that is not busy (IDLE, its service stopped, or an untrusted reading past its ceiling), not
  /// selected, forwarding no port and with no pane attached is let go of: its connection is closed,
  /// so nothing the app sends reaches the box and boxd's idle timer can sleep it (#356). An IDLE
  /// that comes of an unanswered prompt lets it sleep the same way. A pane's own ssh holds its box
  /// awake whatever the app does, so letting go of that one would only blank its status. Nor is a
  /// host let go of within `letGoGrace` of its connect, so the read that connected it is answered
  /// first. Returns whether it was let go of.
  @discardableResult
  func observed(_ host: HostID, busy: Bool) async -> Bool {
    guard !busy, case .remote(let id) = host else { return false }
    let eligible = lock.withLock { () -> Bool in
      guard let key = keys[id], case .boxd = key else { return false }
      if let connected = connectedAt[host], now() - connected < Self.letGoGrace { return false }
      return !selectedHosts.values.contains(host) && letGoAt[host] == nil
    }
    guard eligible,
      await !MainActor.run(body: {
        PortForwardingModel.hasForwards(host)
          || PersistentSessionService.shared.hasAttachedPane(on: host)
      })
    else { return false }
    // Checked again across the wait: a window may have selected it meanwhile.
    let letGo = lock.withLock { () -> Bool in
      guard !selectedHosts.values.contains(host), letGoAt[host] == nil else { return false }
      letGoAt[host] = now()
      return true
    }
    guard letGo else { return false }
    let lease = await HostConnectionManager.shared.snapshot(for: host).lease
    await MainActor.run { WakefulnessModel.Hosts.shared.models[id]?.stopPollingWhileConnected() }
    // A pane may have attached across those waits, and its ssh holds the box whatever happens here.
    let paneAttached = await MainActor.run {
      PersistentSessionService.shared.hasAttachedPane(on: host)
    }
    // The last check before the disconnect, after every wait: a selection, a click or a pane
    // across them takes the host back, which keeps its connection and resumes its poll.
    let committed = lock.withLock { () -> Bool in
      if paneAttached { letGoAt[host] = nil }
      return letGoAt[host] != nil && !selectedHosts.values.contains(host)
    }
    guard committed else {
      await MainActor.run {
        WakefulnessModel.Hosts.shared.models[id]?.pollWhileConnected(connected: false)
      }
      return false
    }
    if let lease { await HostConnectionManager.shared.disconnect(lease) }
    Self.logger.notice("let go of idle boxd host \(id, privacy: .public)")
    return true
  }

  /// Whether the app let go of `host` as idle (`observed`).
  func isLetGo(_ host: HostID) -> Bool { lock.withLock { letGoAt[host] != nil } }

  /// How long after a connect an IDLE reading is ignored: one `WakefulnessModel.pollInterval`, so
  /// the read that connected the host finishes before its connection is closed.
  static let letGoGrace = WakefulnessModel.pollInterval

  /// How long a host let go of is left before boxd is asked about it again: its idle window, by
  /// when boxd sleeps a box nothing holds, plus a `retryAfter`. ponytail: an unknown window is
  /// taken as an hour; a box with a longer one is reconnected, and so held awake, once an hour.
  func revisitAfter(_ host: HostID) -> Duration {
    .seconds(lock.withLock { idleWindows[host] } ?? Self.unknownIdleWindow) + Self.retryAfter
  }

  static let unknownIdleWindow: TimeInterval = 3600

  /// What boxd says of `host` (awake, asleep, or gone), or nil when it isn't a boxd host or boxd
  /// can't say, asking boxd at most once a `retryAfter` for an asleep answer.
  // ponytail: one `machine get` per host per window; one `machine list` per sweep is the upgrade
  // if many boxd workrooms make it slow.
  private func boxdPresence(_ host: HostID) async throws -> BoxdHostDriver.Presence? {
    guard case .remote(let id) = host, let key = lock.withLock({ keys[id] }), case .boxd = key
    else { return nil }
    if let slept = lock.withLock({ asleepAt[host] }), now() - slept < Self.retryAfter {
      return .asleep
    }
    let presence: BoxdHostDriver.Presence?
    if let presenceSeam {
      presence = await presenceSeam(host)
    } else {
      presence = await (try driver(key) as? BoxdHostDriver)?.presence(host) ?? nil
    }
    lock.withLock { asleepAt[host] = presence == .asleep ? now() : nil }
    return presence
  }

  /// Whether `host`'s runtime is missing from this Mac, so nothing can be running on it: the
  /// runtime config records it on, or with none recorded, every runtime.
  ///
  /// Never for a boxd host (#356): it runs on boxd whether or not this Mac has the boxd CLI, and its
  /// panes reach it over ssh without one.
  func runtimeIsMissing(for host: HostID) -> Bool {
    guard case .remote(let id) = host else { return false }
    let key = lock.withLock { keys[id] }
    if let key, case .boxd = key { return false }
    return (key?.runtime.map { [$0] } ?? RemoteWorkrooms.Runtime.allCases).allSatisfy {
      Self.executable(for: $0) == nil
    }
  }

  /// The driver holding `host`, which a reload adopted it into (`adopt`) or which made it.
  private func heldDriver(_ host: HostID) throws -> any HostTerminalDriver {
    guard case .remote(let id) = host, let driver = existingDriver(holding: id) else {
      throw HostDriverError.unknownHost(host)
    }
    return driver
  }

  /// `Application Support/Workroom/<bundle id>/remote`.
  static var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Workroom", isDirectory: true)
      .appendingPathComponent(
        Bundle.main.bundleIdentifier ?? "com.developwithstyle.workroom", isDirectory: true
      )
      .appendingPathComponent("remote", isDirectory: true)
  }

  /// Where `docker` usually is. A GUI app's PATH has none of them.
  static let runtimeCandidates = [
    "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
    "/Applications/Docker.app/Contents/Resources/bin/docker",
  ]
  /// Where Apple's `container` is: its installer's, or Homebrew's.
  static let appleCandidates = ["/usr/local/bin/container", "/opt/homebrew/bin/container"]

  /// Where the boxd CLI is (#356): its installer's (`~/.local/bin`), or Homebrew's.
  static var boxdCandidates: [String] {
    [
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/boxd")
        .path,
      "/opt/homebrew/bin/boxd", "/usr/local/bin/boxd",
    ]
  }

  /// The boxd CLI on this Mac, or nil when it isn't installed.
  static func boxdExecutable() -> String? {
    boxdCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  /// The agent's socket on `driver`'s hosts.
  static func agentSocket(of driver: any HostDriver) -> String {
    (driver as? BoxdHostDriver)?.configuration.agentSocket ?? RemoteWorkrooms.agentSocket
  }

  /// `runtime`'s CLI on this Mac, or nil when it isn't installed.
  static func executable(for runtime: RemoteWorkrooms.Runtime) -> String? {
    (runtime == .docker ? runtimeCandidates : appleCandidates).first {
      FileManager.default.isExecutableFile(atPath: $0)
    }
  }

  /// What each container workroom on `runtime` gets (#309): the hidden settings, else for Apple's
  /// runtime, whose own default is a 1 GB VM per container, half this Mac's cores and a quarter of
  /// its memory, between 2 and 8 GB. Docker's containers share Docker's VM, which already bounds
  /// them, so they get nothing unless set.
  static func resources(
    for runtime: RemoteWorkrooms.Runtime, cpus: Int? = Defaults[.containerCPUs],
    memory: String? = Defaults[.containerMemory],
    cores: Int = ProcessInfo.processInfo.activeProcessorCount,
    physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
  ) -> (cpus: Int?, memory: String?) {
    guard runtime == .apple else { return (cpus, memory) }
    let gigabytes = min(max(Int(physicalMemory / 4 / 1_073_741_824), 2), 8)
    return (cpus ?? max(2, cores / 2), memory ?? "\(gigabytes)G")
  }

  private static func provisioning(_ target: DriverKey) throws -> ContainerHostDriver.Provisioning {
    guard let runtimeKind = target.runtime else {
      throw HostDriverError.invalidConfiguration("\(target) is not a container runtime")
    }
    let resources = resources(for: runtimeKind)
    guard let runtime = executable(for: runtimeKind) else {
      throw runtimeKind == .docker
        ? RemoteWorkrooms.Failure.noDocker : RemoteWorkrooms.Failure.noAppleContainer
    }
    let key = try clientKey()
    return ContainerHostDriver.Provisioning(
      runtime: URL(fileURLWithPath: runtime), image: RemoteWorkrooms.hostImage,
      user: RemoteWorkrooms.user, identityFile: key.path,
      publicKey: try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      agentSocket: RemoteWorkrooms.agentSocket,
      // Per build, so a Dev app's sweep never takes a Nightly app's hosts, nor the other way.
      labels: ["workroom.provisioner=\(RemoteWorkrooms.provisioner)"], context: target.context,
      dialect: runtimeKind == .docker ? .docker : .apple, cpus: resources.cpus,
      memory: resources.memory)
  }

  /// This Mac's ssh key for its remote hosts, in `directory`, made the first time: ed25519, no
  /// passphrase (ssh runs in `BatchMode`), in the app's own 0700 directory.
  static func clientKey(in directory: URL = RemoteHosts.directory) throws -> URL {
    let key = directory.appendingPathComponent("id_ed25519")
    let pub = key.appendingPathExtension("pub")
    if FileManager.default.fileExists(atPath: key.path) {
      // A keygen cut short can leave the private half alone; the public half follows from it.
      if !FileManager.default.fileExists(atPath: pub.path) {
        try keygen(["-y", "-f", key.path]).write(to: pub, options: .atomic)
      }
      return key
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    _ = try keygen(["-q", "-t", "ed25519", "-N", "", "-C", "workroom-remote", "-f", key.path])
    return key
  }

  /// Runs `ssh-keygen` with `arguments`, returning what it printed.
  private static func keygen(_ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    process.arguments = arguments
    let out = Pipe()
    process.standardOutput = out
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw HostDriverError.invalidConfiguration(
        "ssh-keygen \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
    }
    return data
  }
}

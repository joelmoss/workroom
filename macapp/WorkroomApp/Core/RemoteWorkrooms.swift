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

  /// The descriptor's `driver` for `ContainerHostDriver`, the only driver until boxd (#256).
  static let containerDriver = "container"
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

  /// Where a project's base clones its repository on the host.
  static func clonePath(for repository: GitHubRepository) -> String {
    "/home/\(user)/\(repository.name)"
  }

  enum Failure: Error, LocalizedError, Equatable {
    case signedOut
    case notOnGitHub(String)
    case noDocker
    case anotherBuildsBase(String)
    case anotherBuildsHost(String)
    case baseRepositoryChanged(base: String, origin: String)
    case incompleteBase

    var errorDescription: String? {
      switch self {
      case .signedOut:
        return "Sign in to Codaset in Settings → Remote workrooms first: it gives remote "
          + "workrooms their GitHub access."
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
      case .noDocker:
        return "Remote workrooms run on Docker on this Mac for now, and no docker command was "
          + "found. Install Docker Desktop, then run `make remote-host-image`."
      }
    }
  }

  /// The router registrations of `projects`' reachable remote workrooms (#253). Each is its own
  /// shared root on its host, as an independent clone is. Its GitHub identity is the base's, so its
  /// PR and CI status read through `gh` here.
  static func registrations(_ projects: [Project]) -> [RepositoryRouter.Registration] {
    projects.flatMap { project in
      let github = project.host?.repository.flatMap(gitHubRepository)
      return project.workrooms.compactMap { workroom -> RepositoryRouter.Registration? in
        guard let host = workroom.reachableHost,
          let location = try? RepositoryLocation.remote(host: host, path: workroom.path)
        else { return nil }
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
    driver: ContainerHostDriver, environment: RemoteProvisioning.Environment, recorder: Recorder
  ) async throws -> Created {
    let base: RemoteProvisioning.Base
    if let existing, existing.provisioner != provisioner {
      // Its key and labels are another build's, so this one can neither reach nor replace it.
      throw Failure.anotherBuildsBase(existing.provisioner ?? "an unknown build")
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
        path: clonePath(for: repository), in: environment
      ) { base in
        try await recorder.record(
          nil,
          HostDescriptor(
            driver: containerDriver, provisioner: provisioner, id: base.host,
            repository: base.repository,
            cloneURL: base.cloneURL, path: base.path,
            container: driver.record(of: .remote(base.host))))
      }
    }

    let workroomID = UUID()
    let name = try await recorder.reserve(
      base.path,
      HostDescriptor(
        state: "creating", driver: containerDriver, provisioner: provisioner,
        workroomID: workroomID))
    let instance: RemoteProvisioning.Instance
    do {
      instance = try await RemoteProvisioning.derive(
        from: base, workroom: workroomID, branch: branch(for: name), in: environment
      ) { host, grant in
        // Still `creating`, but now naming what a delete has to take down.
        try await recorder.record(
          name,
          remaining(
            state: "creating", workroomID: workroomID, host: host, grant: grant, driver: driver))
      }
    } catch RemoteProvisioning.Failure.rollbackIncomplete(let cause, let host, let grant, let left)
    {
      // `destroyed` only with nothing live: the CLI deletes a destroyed entry, and a live grant
      // must keep its record until the app's delete cancels it.
      try? await recorder.record(
        name,
        remaining(
          state: host == nil && grant == nil ? "destroyed" : "failed", workroomID: workroomID,
          host: host, grant: grant, driver: driver))
      throw RemoteProvisioning.Failure.rollbackIncomplete(
        cause: cause, host: host, grantID: grant, cleanup: left)
    } catch {
      try? await recorder.forget(name)
      throw error
    }

    guard case .remote(let id) = instance.host else {
      throw HostDriverError.unknownHost(instance.host)
    }
    do {
      try await recorder.record(
        name,
        HostDescriptor(
          driver: containerDriver, provisioner: provisioner, id: id, grantID: instance.grantID,
          workroomID: workroomID, container: driver.record(of: instance.host)))
    } catch {
      // Unrecorded, the instance would be found by nothing but the sweep, and its grant by nothing.
      do {
        try await RemoteProvisioning.destroy(instance, workroom: workroomID, in: environment)
      } catch RemoteProvisioning.Failure.rollbackIncomplete(_, let host, let grant, _) {
        // Something is still live: the entry stays, `failed`, for delete to finish.
        try? await recorder.record(
          name,
          remaining(
            state: "failed", workroomID: workroomID, host: host, grant: grant, driver: driver))
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
    state: String, workroomID: UUID, host: HostID?, grant: String?, driver: ContainerHostDriver
  ) -> HostDescriptor {
    var descriptor = HostDescriptor(
      state: state, driver: containerDriver, provisioner: provisioner, grantID: grant,
      workroomID: workroomID)
    if case .remote(let id) = host {
      descriptor.id = id
      descriptor.container = driver.record(of: .remote(id))
    }
    return descriptor
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
    guard try checkDeletable([host]) else { return try await recorder.forget(name) }
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
      if liveHost == nil { (remaining.id, remaining.container) = (nil, nil) }
      try? await recorder.record(name, remaining)
      throw RemoteProvisioning.Failure.rollbackIncomplete(
        cause: cause, host: liveHost, grantID: grant, cleanup: left)
    }
    try await recorder.forget(name)
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

/// The app's remote hosts (#253): a `ContainerHostDriver` per Docker context on this Mac (#309),
/// the hosts config records adopted into theirs at each reload, and one sweep per launch for what
/// no record names.
final class RemoteHosts: @unchecked Sendable {
  static let shared = RemoteHosts()

  private let lock = NSLock()
  /// The drivers made so far, by the Docker context they name; nil is the one that names none.
  private var made: [String?: ContainerHostDriver] = [:]
  private var swept = false
  /// A call reached the sweep while a delete was in flight and left it for later (#296).
  private var held = false
  /// The connection attempt running for each host, which `ensureConnected` callers share.
  private var connecting: [HostID: Task<Void, Error>] = [:]
  /// When each host's last attempt failed, which answers for it for `retryAfter`.
  private var failedAt: [HostID: ContinuousClock.Instant] = [:]
  /// `ensureConnected`'s seams, nil in the app: the connect itself, whether a host is up, the clock.
  private let connectHost: (@Sendable (HostID) async throws -> Void)?
  private let isConnected: (@Sendable (HostID) async -> Bool)?
  private let now: @Sendable () -> ContinuousClock.Instant
  /// `adopt`'s seams, nil in the app: making a context's driver, and sweeping one.
  private let makeDriver: (@Sendable (String?) throws -> ContainerHostDriver)?
  private let sweepDriver:
    (@Sendable (ContainerHostDriver, Set<UUID>, Set<String>) async -> [String])?

  init(
    connectHost: (@Sendable (HostID) async throws -> Void)? = nil,
    isConnected: (@Sendable (HostID) async -> Bool)? = nil,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    makeDriver: (@Sendable (String?) throws -> ContainerHostDriver)? = nil,
    sweepDriver: (@Sendable (ContainerHostDriver, Set<UUID>, Set<String>) async -> [String])? = nil
  ) {
    self.connectHost = connectHost
    self.isConnected = isConnected
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

  /// The driver for Docker `context`, made on first use: it needs Docker and this Mac's ssh key.
  /// nil names no context, as every driver did before #309. Each driver writes its hosts' ssh
  /// files under their own IDs, so they share one directory.
  func driver(context: String? = nil) throws -> ContainerHostDriver {
    try lock.withLock {
      if let made = made[context] { return made }
      let driver =
        try makeDriver?(context)
        ?? ContainerHostDriver(
          hosts: [:], directory: Self.directory.appendingPathComponent("hosts", isDirectory: true),
          provisioning: try Self.provisioning(context: context))
      made[context] = driver
      return driver
    }
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
  /// made so far has it.
  func existingDriver(holding id: UUID) -> ContainerHostDriver? {
    lock.withLock { made.values.first { $0.record(of: .remote(id)) != nil } }
  }

  /// Takes on every host `projects` record, each into the driver for its Docker context, so their
  /// panes and services reach them after a relaunch, then sweeps once per launch what carries this
  /// app's labels and no record names. Does nothing, and never touches Docker, when nothing is
  /// recorded and nothing has been made. `sweep: false` holds the sweep for a later call: a list
  /// with a delete in flight leaves out hosts config still records (#296).
  func adopt(_ projects: [Project], sweep: Bool = true) {
    let descriptors =
      projects.compactMap(\.host) + projects.flatMap { $0.workrooms.compactMap(\.host) }
    // Another build's hosts take another key: adopted here, they would refuse every login.
    let recorded = descriptors.filter {
      $0.driver == RemoteWorkrooms.containerDriver
        && $0.provisioner == RemoteWorkrooms.provisioner
    }
    let already = lock.withLock { Set(made.keys) }
    guard !recorded.isEmpty || !already.isEmpty else { return }
    // A descriptor with no container record yet goes to the driver that names no context, where the
    // one driver before #309 would have had it.
    let contexts = already.union(recorded.map { $0.container?.context })
    var drivers: [ContainerHostDriver] = []
    for context in contexts {
      let driver: ContainerHostDriver
      do { driver = try self.driver(context: context) } catch {
        Self.logger.error("remote hosts: \(error.localizedDescription, privacy: .public)")
        return
      }
      drivers.append(driver)
      for descriptor in recorded
      where !descriptor.isDestroyed && descriptor.container?.context == context {
        guard let id = descriptor.id, let record = descriptor.container,
          driver.record(of: .remote(id)) == nil
        else { continue }
        do { try driver.adopt(id, record) } catch {
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

  /// The Docker context a new workroom of a project with `base` goes in (#309): its base's, since
  /// it is derived from the base on that daemon, or for a project with no base yet the context the
  /// CLI would use now, which the new base is then pinned to. nil follows the environment, as
  /// every host made before #309 does.
  func context(forBase base: HostDescriptor?) async throws -> String? {
    if let base, base.id != nil { return base.container?.context }
    return try await driver(context: nil).currentContext()
  }

  /// The sequence's environment over Docker `context`'s driver, signed in as this Mac.
  @MainActor
  func environment(context: String?) throws -> (
    ContainerHostDriver, RemoteProvisioning.Environment
  ) {
    guard let client = BrokerSession.shared.client() else {
      throw RemoteWorkrooms.Failure.signedOut
    }
    let driver = try driver(context: context)
    var environment = RemoteProvisioning.Environment(
      driver: driver, agentSocket: RemoteWorkrooms.agentSocket, client: client)
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

  /// What deleting `hosts` needs, checked before anything is removed (#253): nil when none of them
  /// is live, else the environment, which throws when signed out or without Docker. Refuses one
  /// another build made (`RemoteWorkrooms.checkDeletable`).
  @MainActor
  func environment(toDelete hosts: [HostDescriptor]) throws -> RemoteProvisioning.Environment? {
    guard try RemoteWorkrooms.checkDeletable(hosts) else { return nil }
    // One environment has one driver, so one context. A project's workrooms are derived from its
    // base, on its daemon, so the hosts of one delete share it.
    let contexts = Set(
      hosts.filter(RemoteWorkrooms.isLive).compactMap(\.container).map(\.context))
    guard contexts.count <= 1 else {
      throw HostDriverError.invalidConfiguration(
        "these hosts are in different Docker contexts: "
          + contexts.map { $0 ?? "(current)" }.sorted().joined(separator: ", "))
    }
    let (driver, environment) = try environment(context: contexts.first ?? nil)
    // Taking a box down needs it on the driver, whatever a reload adopted: with previews off it
    // adopted nothing, and the box would read as unknown.
    for host in hosts where RemoteWorkrooms.isLive(host) {
      guard let id = host.id, let record = host.container, driver.record(of: .remote(id)) == nil
      else { continue }
      do { try driver.adopt(id, record) } catch {
        Self.logger.error("adopting host \(id, privacy: .public): \(error, privacy: .public)")
      }
    }
    return environment
  }

  /// The app's service connection to `host` (`HostConnectionManager`), with its agent bootstrapped
  /// first. One already there is kept.
  func connect(_ host: HostID, driver: ContainerHostDriver) async throws {
    _ = try await HostConnectionManager.shared.connectIfDisconnected(host: host) {
      try await AgentBootstrap.connect(
        host: host, driver: driver, socket: RemoteWorkrooms.agentSocket)
    }
  }

  /// Connects `host`'s service connection unless it is up, for a read, write or listing that needs
  /// it (`RepositoryRouter`). One attempt per host at a time: the inspector's panels ask together
  /// when a remote workroom is selected, and every caller after the first waits for that attempt
  /// rather than fail, as `connectIfDisconnected` would have it while one is running.
  ///
  /// Any failure is `RepositoryRoutingError.unavailable`, which every panel shows as the host being
  /// out of reach. Untyped, a stopped host's ssh failure read as "Not a repository". The cause is
  /// logged.
  func ensureConnected(_ host: HostID) async throws {
    guard case .remote = host else { return }
    let up: Bool
    if let isConnected {
      up = await isConnected(host)
    } else {
      up = await HostConnectionManager.shared.snapshot(for: host).status == .connected
    }
    if up { return }
    if let failed = lock.withLock({ failedAt[host] }), now() - failed < Self.retryAfter {
      throw RepositoryRoutingError.unavailable(host)
    }
    do {
      let connect =
        try connectHost ?? { [driver = try heldDriver(host)] in
          try await self.connect($0, driver: driver)
        }
      let task = lock.withLock { () -> Task<Void, Error> in
        if let running = connecting[host] { return running }
        let task = Task { try await connect(host) }
        connecting[host] = task
        return task
      }
      defer { lock.withLock { if connecting[host] == task { connecting[host] = nil } } }
      try await task.value
      lock.withLock { failedAt[host] = nil }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      lock.withLock { failedAt[host] = now() }
      Self.logger.error(
        "connecting \(String(describing: host), privacy: .public): \(error, privacy: .public)")
      throw RepositoryRoutingError.unavailable(host)
    }
  }

  /// The driver holding `host`, which a reload adopted it into (`adopt`) or which made it.
  private func heldDriver(_ host: HostID) throws -> ContainerHostDriver {
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

  private static func provisioning(context: String?) throws -> ContainerHostDriver.Provisioning {
    guard
      let runtime = runtimeCandidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0)
      })
    else { throw RemoteWorkrooms.Failure.noDocker }
    let key = try clientKey()
    return ContainerHostDriver.Provisioning(
      runtime: URL(fileURLWithPath: runtime), image: RemoteWorkrooms.hostImage,
      user: RemoteWorkrooms.user, identityFile: key.path,
      publicKey: try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      agentSocket: RemoteWorkrooms.agentSocket,
      // Per build, so a Dev app's sweep never takes a Nightly app's hosts, nor the other way.
      labels: ["workroom.provisioner=\(RemoteWorkrooms.provisioner)"], context: context)
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

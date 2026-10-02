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
    #if DEBUG
      let channel = true
    #else
      let channel = ReleaseChannel.isNightlyBuild
    #endif
    return channel && Defaults[.remoteWorkroomsPreview]
  }

  /// The descriptor's `driver` for `ContainerHostDriver`, the only driver until boxd (#256).
  static let containerDriver = "container"
  /// The descriptor's `provisioner`: this build, whose ssh key and Docker labels its hosts carry.
  static var provisioner: String { Bundle.main.bundleIdentifier ?? "com.developwithstyle.workroom" }
  /// Fixed by the host image's entrypoint (`vcs/scripts/ssh-fixture/entrypoint.sh`).
  static let agentSocket = "/run/workroom/agent.sock"
  static let user = "workroom"

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
      base = recorded
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
        from: base, workroom: workroomID, branch: branch(for: name), in: environment)
    } catch RemoteProvisioning.Failure.rollbackIncomplete(let cause, let host, let grant, let left)
    {
      // `destroyed` only with nothing live: the CLI deletes a destroyed entry, and a live grant
      // must keep its record until the app's delete cancels it.
      var live = HostDescriptor(
        state: host == nil && grant == nil ? "destroyed" : "failed", driver: containerDriver,
        provisioner: provisioner, grantID: grant, workroomID: workroomID)
      if case .remote(let id) = host {
        live.id = id
        live.container = driver.record(of: .remote(id))
      }
      try? await recorder.record(name, live)
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
      try? await RemoteProvisioning.destroy(instance, workroom: workroomID, in: environment)
      try? await recorder.forget(name)
      throw error
    }
    return Created(name: name, instance: instance)
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

/// The app's remote hosts (#253): one `ContainerHostDriver` on this Mac's Docker, the hosts config
/// records adopted into it at each reload, and one sweep per launch for what no record names.
final class RemoteHosts: @unchecked Sendable {
  static let shared = RemoteHosts()

  private let lock = NSLock()
  private var made: ContainerHostDriver?
  private var swept = false
  /// The connection attempt running for each host, which `ensureConnected` callers share.
  private var connecting: [HostID: Task<Void, Error>] = [:]
  /// When each host's last attempt failed, which answers for it for `retryAfter`.
  private var failedAt: [HostID: ContinuousClock.Instant] = [:]

  /// How long a failed connect answers for its host before another is tried. The status sweep and
  /// every panel ask again, and each attempt at a host that is down waits out ssh's connect
  /// timeout. ponytail: a fixed window, so a Reload inside it fails fast too; upgrade path: let a
  /// read the user asked for bypass it.
  static let retryAfter: Duration = .seconds(30)
  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "RemoteWorkrooms")

  /// The driver, made on first use: it needs Docker and this Mac's ssh key.
  func driver() throws -> ContainerHostDriver {
    try lock.withLock {
      if let made { return made }
      let driver = ContainerHostDriver(
        hosts: [:], directory: Self.directory.appendingPathComponent("hosts", isDirectory: true),
        provisioning: try Self.provisioning())
      made = driver
      return driver
    }
  }

  /// The driver if something has already made it, for a pane, which must not probe Docker.
  var existingDriver: ContainerHostDriver? { lock.withLock { made } }

  /// Takes on every host `projects` record, so their panes and services reach them after a
  /// relaunch, then sweeps once per launch what carries this app's labels and no record names.
  /// Does nothing, and never touches Docker, when nothing is recorded and nothing has been made.
  func adopt(_ projects: [Project]) {
    let descriptors =
      projects.compactMap(\.host) + projects.flatMap { $0.workrooms.compactMap(\.host) }
    // Another build's hosts take another key: adopted here, they would refuse every login.
    let recorded = descriptors.filter {
      $0.driver == RemoteWorkrooms.containerDriver
        && $0.provisioner == RemoteWorkrooms.provisioner
    }
    guard !recorded.isEmpty || existingDriver != nil else { return }
    let driver: ContainerHostDriver
    do { driver = try self.driver() } catch {
      Self.logger.error("remote hosts: \(error.localizedDescription, privacy: .public)")
      return
    }
    for descriptor in recorded where !descriptor.isDestroyed {
      guard let id = descriptor.id, let record = descriptor.container,
        driver.record(of: .remote(id)) == nil
      else { continue }
      do { try driver.adopt(id, record) } catch {
        Self.logger.error("adopting host \(id, privacy: .public): \(error, privacy: .public)")
      }
    }
    let shouldSweep = lock.withLock {
      defer { swept = true }
      return !swept
    }
    guard shouldSweep else { return }
    let known = Set(recorded.compactMap(\.id))
    Task.detached(priority: .utility) {
      for failure in await driver.sweep(keeping: known) {
        Self.logger.error("remote host sweep: \(failure, privacy: .public)")
      }
    }
  }

  /// The sequence's environment over the driver, signed in as this Mac.
  @MainActor
  func environment() throws -> (ContainerHostDriver, RemoteProvisioning.Environment) {
    guard let client = BrokerSession.shared.client() else {
      throw RemoteWorkrooms.Failure.signedOut
    }
    let driver = try driver()
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
    try RemoteWorkrooms.checkDeletable(hosts) ? environment().1 : nil
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
    if await HostConnectionManager.shared.snapshot(for: host).status == .connected { return }
    if let failed = lock.withLock({ failedAt[host] }), .now - failed < Self.retryAfter {
      throw RepositoryRoutingError.unavailable(host)
    }
    do {
      let driver = try driver()
      let task = lock.withLock { () -> Task<Void, Error> in
        if let running = connecting[host] { return running }
        let task = Task { try await self.connect(host, driver: driver) }
        connecting[host] = task
        return task
      }
      defer { lock.withLock { if connecting[host] == task { connecting[host] = nil } } }
      try await task.value
      lock.withLock { failedAt[host] = nil }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      lock.withLock { failedAt[host] = .now }
      Self.logger.error(
        "connecting \(String(describing: host), privacy: .public): \(error, privacy: .public)")
      throw RepositoryRoutingError.unavailable(host)
    }
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

  private static func provisioning() throws -> ContainerHostDriver.Provisioning {
    guard
      let runtime = runtimeCandidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0)
      })
    else { throw RemoteWorkrooms.Failure.noDocker }
    let key = try clientKey()
    return ContainerHostDriver.Provisioning(
      runtime: URL(fileURLWithPath: runtime), image: Defaults[.remoteHostImage],
      user: RemoteWorkrooms.user, identityFile: key.path,
      publicKey: try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      agentSocket: RemoteWorkrooms.agentSocket,
      // Per build, so a Dev app's sweep never takes a Nightly app's hosts, nor the other way.
      labels: ["workroom.provisioner=\(RemoteWorkrooms.provisioner)"])
  }

  /// This Mac's ssh key for its remote hosts, made the first time: ed25519, no passphrase (ssh
  /// runs in `BatchMode`), in the app's own 0700 directory.
  private static func clientKey() throws -> URL {
    let key = directory.appendingPathComponent("id_ed25519")
    if FileManager.default.fileExists(atPath: key.path) { return key }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let keygen = Process()
    keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "workroom-remote", "-f", key.path]
    try keygen.run()
    keygen.waitUntilExit()
    guard keygen.terminationStatus == 0 else {
      throw HostDriverError.invalidConfiguration(
        "ssh-keygen exited \(keygen.terminationStatus) making \(key.path)")
    }
    return key
  }
}

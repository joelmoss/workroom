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
      case .noDocker:
        return "Remote workrooms run on Docker on this Mac for now, and no docker command was "
          + "found. Install Docker Desktop, then run `make remote-host-image`."
      }
    }
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
}

/// The app's remote hosts (#253): one `ContainerHostDriver` on this Mac's Docker, the hosts config
/// records adopted into it at each reload, and one sweep per launch for what no record names.
final class RemoteHosts: @unchecked Sendable {
  static let shared = RemoteHosts()

  private let lock = NSLock()
  private var made: ContainerHostDriver?
  private var swept = false
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

  /// The app's service connection to `host` (`HostConnectionManager`), with its agent bootstrapped
  /// first. One already there is kept.
  func connect(_ host: HostID, driver: ContainerHostDriver) async throws {
    _ = try await HostConnectionManager.shared.connectIfDisconnected(host: host) {
      try await AgentBootstrap.connect(
        host: host, driver: driver, socket: RemoteWorkrooms.agentSocket)
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

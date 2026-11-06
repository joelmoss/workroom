import Foundation
import HostDrivers
import WorkroomDomain

/// The one place the app makes host drivers (ADR 0067). Each driver key's driver is made on first
/// use and kept. A provider's setup, a create's account check and the SSH host check get a fresh
/// one that reaches no host yet.
///
/// Every driver keeps its hosts' files in one folder, `RemoteHosts.hosts`, each host's under its
/// own ID. The fresh ones never write there: boxd's and exe.dev's only run the provider's CLI, and
/// the SSH check's files are the ones its destination's kept driver uses. A pane whose host no
/// driver holds gets `unreachable`, which keeps no files, so it never reads one a real driver left.
///
/// A container runtime's driver is held as what it is, `ContainerHostDriver`: adopting its
/// records, sweeping its labels and building a devcontainer's image are a container runtime's
/// alone. Anything else is asked of a driver through the capabilities in `HostDrivers`.
final class HostDriverRegistry: @unchecked Sendable {
  typealias DriverKey = RemoteHosts.DriverKey

  private let lock = NSLock()
  /// The boxd, exe.dev and SSH drivers made so far.
  private var made: [DriverKey: any HostTerminalDriver] = [:]
  /// The container runtimes' drivers made so far.
  private var containers: [DriverKey: ContainerHostDriver] = [:]
  /// Seams, nil in the app: making a provider's or an SSH host's driver, and a container runtime's.
  private let makeDriver: (@Sendable (DriverKey) throws -> any HostTerminalDriver)?
  private let makeContainerDriver: (@Sendable (DriverKey) throws -> ContainerHostDriver)?

  init(
    makeDriver: (@Sendable (DriverKey) throws -> any HostTerminalDriver)? = nil,
    makeContainerDriver: (@Sendable (DriverKey) throws -> ContainerHostDriver)? = nil
  ) {
    self.makeDriver = makeDriver
    self.makeContainerDriver = makeContainerDriver
  }

  /// The driver for `key`, made on first use. A container driver needs that runtime's CLI and this
  /// Mac's ssh key; a boxd driver reaches its hosts through the ssh details the boxd CLI wrote, so
  /// making one never fails (#356).
  func driver(_ key: DriverKey) throws -> any HostTerminalDriver {
    try lock.withLock {
      if let made = made[key] { return made }
      let driver: any HostTerminalDriver
      if let makeDriver, key.runtime == nil {
        driver = try makeDriver(key)
      } else {
        switch key {
        case .container: return try containerLocked(key)
        case .boxd(let org, let account):
          let cli = RemoteHosts.boxdExecutable()
          driver = Self.boxd(cli: cli ?? RemoteHosts.boxdCandidates[0], org: org, account: account)
          // Not kept while the CLI is missing, so installing it later takes without a relaunch.
          guard cli != nil else { return driver }
        case .exeDev(let account): driver = Self.exeDev(account: account)
        case .ssh(let destination): driver = Self.ssh(destination: destination)
        }
      }
      made[key] = driver
      return driver
    }
  }

  /// `key`'s driver, which must be a container runtime's: adopting, sweeping, starting and naming
  /// contexts are theirs alone.
  func container(_ key: DriverKey) throws -> ContainerHostDriver {
    try lock.withLock { try containerLocked(key) }
  }

  private func containerLocked(_ key: DriverKey) throws -> ContainerHostDriver {
    if let made = containers[key] { return made }
    guard let runtime = key.runtime else {
      throw HostDriverError.invalidConfiguration("\(key) is not a container runtime")
    }
    let driver =
      try makeContainerDriver?(key)
      ?? ContainerHostDriver(
        hosts: [:], directory: RemoteHosts.hosts,
        provisioning: try Self.provisioning(key, runtime: runtime))
    containers[key] = driver
    return driver
  }

  /// The container driver made so far that holds host `id`, if any.
  func container(holding id: UUID) -> ContainerHostDriver? {
    lock.withLock { containers.values.first { $0.record(of: .remote(id)) != nil } }
  }

  /// The keys whose drivers have been made.
  var madeKeys: Set<DriverKey> {
    lock.withLock { Set(made.keys).union(containers.keys) }
  }

  /// A boxd driver acting for `org` and `account` through the CLI at `cli`. With neither, the one a
  /// setup or a create asks who is signed in.
  static func boxd(cli: String, org: String? = nil, account: String? = nil) -> BoxdHostDriver {
    BoxdHostDriver(
      configuration: RemoteHosts.boxdConfiguration(cli: cli, org: org, account: account),
      directory: RemoteHosts.hosts)
  }

  /// An exe.dev driver acting for `account`. With none, the one a setup or a create asks who the
  /// user's ssh signs in as.
  static func exeDev(account: String? = nil) -> ExeDevHostDriver {
    ExeDevHostDriver(configuration: .init(account: account), directory: RemoteHosts.hosts)
  }

  /// An SSH host's driver, its home not yet known: a key's, or the one the host check makes.
  static func ssh(destination: String) -> SSHHostDriver {
    SSHHostDriver(
      configuration: .init(
        destination: destination, home: "", stateDirectoryName: RemoteHosts.sshStateDirectoryName),
      directory: RemoteHosts.hosts)
  }

  /// What a remote pane is registered against when no driver holds its host.
  static let unreachable: any HostTerminalDriver = UnreachableHostDriver()

  private static func provisioning(_ target: DriverKey, runtime runtimeKind: ContainerRuntime)
    throws -> ContainerHostDriver.Provisioning
  {
    let resources = RemoteHosts.resources(for: runtimeKind)
    guard let runtime = RemoteHosts.executable(for: runtimeKind) else {
      throw runtimeKind == .docker
        ? RemoteWorkrooms.Failure.noDocker : RemoteWorkrooms.Failure.noAppleContainer
    }
    return ContainerHostDriver.Provisioning(
      runtime: URL(fileURLWithPath: runtime), image: RemoteWorkrooms.defaultImage,
      user: RemoteWorkrooms.user, daemonSocket: RemoteWorkrooms.daemonSocket,
      // Per build, so a Dev app's sweep never takes a Nightly app's hosts, nor the other way.
      labels: ["workroom.provisioner=\(RemoteWorkrooms.provisioner)"], context: target.context,
      dialect: runtimeKind, cpus: resources.cpus,
      memory: resources.memory,
      // A container's entrypoint (#308): the daemon this build bundles for its architecture,
      // mounted on Apple's runtime from a folder of this build's own.
      daemon: { PersistentSessionPaths.linuxDaemonURL(architecture: $0) },
      daemonFolder: RemoteHosts.directory.appendingPathComponent(
        "container-daemon", isDirectory: true))
  }
}

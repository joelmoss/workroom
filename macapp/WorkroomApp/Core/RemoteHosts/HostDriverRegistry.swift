import Foundation
import HostDrivers
import WorkroomDomain
import WorkroomVCS
import os

/// The one place the app makes host drivers (ADR 0067), and the record of which driver holds each
/// host config names: a `ContainerHostDriver` per container runtime and Docker context on this Mac
/// (#309), the hosts config records adopted into theirs at each reload, and one sweep per launch
/// for what no record names. A boxd or exe.dev host is reached by name through its provider's
/// driver, never adopted (#356); of its machines, only those a create left pending are swept
/// (#373). Each driver key's driver is made on first use and kept. A provider's setup, a create's
/// account check and the SSH host check get a fresh one that reaches no host yet.
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
  /// The driver each host config records it in, whether or not that driver has been made.
  private var keys: [UUID: DriverKey] = [:]
  /// The driver keys whose sweep ran this launch, and those whose sweep is running (#284).
  private var swept: Set<DriverKey> = []
  private var sweeping: Set<DriverKey> = []
  /// A call reached the sweep while a delete was in flight and left it for later (#296).
  private var held = false
  /// Seams, nil in the app: making a provider's or an SSH host's driver, and a container runtime's.
  private let makeDriver: (@Sendable (DriverKey) throws -> any HostTerminalDriver)?
  private let makeContainerDriver: (@Sendable (DriverKey) throws -> ContainerHostDriver)?
  /// `adopt`'s seam, nil in the app: sweeping a container runtime's driver.
  private let sweepDriver:
    (@Sendable (ContainerHostDriver, Set<UUID>, Set<String>, Bool) async -> [String])?
  /// Where `adopt` looks for the runtimes with containers pending
  /// (`ContainerHostDriver.pending(in:)`), or nil to look nowhere.
  private let pendingIn: URL?

  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "RemoteWorkrooms")

  init(
    makeDriver: (@Sendable (DriverKey) throws -> any HostTerminalDriver)? = nil,
    makeContainerDriver: (@Sendable (DriverKey) throws -> ContainerHostDriver)? = nil,
    sweepDriver: (
      @Sendable (ContainerHostDriver, Set<UUID>, Set<String>, Bool) async -> [String]
    )? = nil,
    pendingIn: URL? = RemoteHosts.pendingIn
  ) {
    self.makeDriver = makeDriver
    self.makeContainerDriver = makeContainerDriver
    self.sweepDriver = sweepDriver
    self.pendingIn = pendingIn
  }

  /// The driver for `key`, made on first use. A container driver needs that runtime's CLI and this
  /// Mac's ssh key; a boxd driver reaches its hosts through the ssh details the boxd CLI wrote, so
  /// making one never fails (#356). The default key is Docker naming no context, as every driver
  /// did before #309.
  func driver(_ key: DriverKey = DriverKey()) throws -> any HostTerminalDriver {
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
        case .railway(let environment): driver = Self.railway(environment: environment)
        case .ssh(let destination): driver = Self.ssh(destination: destination)
        }
      }
      made[key] = driver
      return driver
    }
  }

  /// `key`'s driver, which must be a container runtime's: adopting, sweeping, starting and naming
  /// contexts are theirs alone.
  func container(_ key: DriverKey = DriverKey()) throws -> ContainerHostDriver {
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

  /// The driver that holds host `id`, for a pane, which must not probe Docker: nil when no driver
  /// made so far has it. A remote provider's driver (boxd, #356) is made here if need be: it reaches
  /// the host by name, with nothing to adopt and no runtime to probe.
  func existingDriver(holding id: UUID) -> (any HostTerminalDriver)? {
    let key = lock.withLock { keys[id] }
    if let key, key.isRemoteProvider { return try? driver(key) }
    return container(holding: id)
  }

  /// The hosts config records on a remote provider (boxd, exe.dev or SSH), not in a container on
  /// this Mac.
  var providerHosts: [HostID] {
    lock.withLock { keys.filter { $0.value.isRemoteProvider }.map { HostID.remote($0.key) } }
  }

  /// Whether `host`'s runtime is missing from this Mac, so nothing can be running on it: the
  /// runtime config records it on, or with none recorded, every runtime.
  ///
  /// Never for a remote provider's host (boxd, #356): it runs there whether or not this Mac has the
  /// provider's CLI, and its panes reach it over ssh without one.
  func runtimeIsMissing(for host: HostID) -> Bool {
    guard case .remote(let id) = host else { return false }
    let key = lock.withLock { keys[id] }
    if let key, key.isRemoteProvider { return false }
    return (key?.runtime.map { [$0] } ?? ContainerRuntime.allCases).allSatisfy {
      RemoteHosts.executable(for: $0) == nil
    }
  }

  /// Which of `keys` this call sweeps: each whose sweep has neither run this launch nor is running,
  /// so no key is swept twice in a launch, which the two-launch rule would count as two launches
  /// (`ContainerHostDriver.sweep`). A call that isn't allowed sweeps none and leaves them for the
  /// next.
  func claimSweep(_ keys: Set<DriverKey>, allowed: Bool) -> Set<DriverKey> {
    lock.withLock {
      let owed = keys.subtracting(swept).subtracting(sweeping)
      guard allowed else {
        held = held || !owed.isEmpty
        return []
      }
      held = false
      sweeping.formUnion(owed)
      return owed
    }
  }

  /// Ends `key`'s sweep: done for the launch when it ran, and owed again when its runtime could not
  /// list its containers (down at launch, say), so a later reload sweeps it (#284).
  func finishSweep(_ key: DriverKey, ran: Bool) {
    lock.withLock {
      sweeping.remove(key)
      if ran { swept.insert(key) }
    }
  }

  /// How many sweeps are running, for tests to wait on `finishSweep`.
  var sweepsRunning: Int { lock.withLock { sweeping.count } }

  /// Whether a sweep was held back and has yet to run. False when no call has reached the sweep,
  /// so a launch with nothing recorded never reads config again for one.
  var sweepHeld: Bool { lock.withLock { held } }

  /// Takes on every host `projects` record, each into the driver for its Docker context, so their
  /// panes and services reach them after a relaunch, then sweeps once per launch what carries this
  /// app's labels and no record names, and the remote provider machines a create left pending
  /// (#373). Does nothing, and never touches Docker, when nothing is recorded, nothing has been
  /// made, and no create left a container or machine pending (#284). `sweep: false`
  /// holds the sweep for a later call: a list with a delete in flight leaves out hosts config
  /// still records (#296). `relayed` hears each recorded workroom host whose git credentials come
  /// through the Mac's relay (#309).
  func adopt(_ projects: [Project], sweep: Bool = true, relayed: (UUID) -> Void) {
    let descriptors =
      projects.flatMap { BaseRetirement.bases(of: $0.host) }
      + projects.flatMap { $0.workrooms.compactMap(\.host) }
    // Another build's hosts take another key: adopted here, they would refuse every login. A
    // remote provider's host Release and Nightly share is both's (`ownsHost`).
    let recorded = descriptors.filter {
      DriverKey($0) != nil && RemoteWorkrooms.ownsHost($0)
    }
    // An SSH host's home and a Railway host's sandbox are in its record, which its driver must
    // hold before a pane, a read or a delete reaches it.
    for descriptor in recorded where descriptor.kind == .ssh || descriptor.kind == .railway {
      guard let key = DriverKey(descriptor), descriptor.kind != .ssh || descriptor.sshHome != nil
      else { continue }
      do { try (driver(key) as? any HostRecording)?.adopt(descriptor) } catch {
        Self.logger.error("host record: \(error.localizedDescription, privacy: .public)")
      }
    }
    // An older build's base, until `BaseRetirement` removes it: it never relays.
    let bases = Set(projects.flatMap { BaseRetirement.bases(of: $0.host).compactMap(\.id) })
    let already = lock.withLock {
      for descriptor in recorded {
        if let id = descriptor.id, let key = DriverKey(descriptor) { keys[id] = key }
      }
      return Set(made.keys).union(containers.keys)
    }
    // A base never has git ask for credentials; only its workrooms are relayed.
    for descriptor in recorded {
      if let id = descriptor.id, descriptor.isRelayed, !bases.contains(id) { relayed(id) }
    }
    // A runtime with a container a create began, which a crash may have left before config
    // recorded it (#284).
    let marked = (pendingIn.map(ContainerHostDriver.pending(in:)) ?? []).map {
      DriverKey(runtime: $0.dialect, context: $0.context)
    }
    // A boxd or exe.dev machine a create began, which config may not have recorded (#373).
    let recordedIDs = Set(recorded.compactMap(\.id))
    if let pendingIn { PendingMachines.forget(recordedIDs, in: pendingIn) }
    // Filtered here too: the forget is best-effort, and a machine config names is never swept.
    let machines = (pendingIn.map(PendingMachines.entries(in:)) ?? []).filter {
      !recordedIDs.contains($0.id)
    }
    guard !recorded.isEmpty || !already.isEmpty || !marked.isEmpty || !machines.isEmpty else {
      return
    }
    // A descriptor with no container record yet goes to its runtime's driver that names no
    // context, where the one driver before #309 would have had it.
    // A remote provider's host needs no adopting: its driver reaches it by name. Of its machines,
    // only those a create left pending are swept (`PendingMachines`).
    let containerKeys = already.union(recorded.compactMap(DriverKey.init)).union(marked).filter {
      $0.runtime != nil
    }
    var drivers: [DriverKey: ContainerHostDriver] = [:]
    for key in containerKeys {
      let driver: ContainerHostDriver
      do { driver = try container(key) } catch {
        // That runtime isn't installed; another's may be.
        Self.logger.error("remote hosts: \(error.localizedDescription, privacy: .public)")
        continue
      }
      drivers[key] = driver
      // Every recorded host, not only this key's: two contexts can name one daemon.
      driver.forgetPending(recorded.compactMap(\.id).map(ContainerHostDriver.containerName))
      for descriptor in recorded where !descriptor.isDestroyed && DriverKey(descriptor) == key {
        adoptLogged(descriptor, into: driver)
      }
    }
    let machineKeys = Set(machines.compactMap(\.key))
    let claimed = claimSweep(Set(drivers.keys).union(machineKeys), allowed: sweep)
    guard !claimed.isEmpty else { return }
    // Every driver keeps every recorded host, not only its own: two contexts can name one daemon
    // (the nil driver's current context and that context by name), and a sweep that kept only its
    // own hosts would remove the other's, labelled as this build's and old enough.
    let known = Set(recorded.compactMap(\.id))
    let images = Set(recorded.compactMap { $0.container?.image })
    // With no container host recorded, config may simply not be the one the containers were made
    // under (a lost config, a launch with a throwaway `HOME`): only what a create left pending
    // goes. A boxd host recorded says nothing of the containers.
    let onlyPending = !recorded.contains { DriverKey($0)?.runtime != nil }
    let sweep =
      sweepDriver ?? { await $0.sweep(keeping: $1, images: $2, onlyPending: $3) }
    // At once: a context whose daemon is slow to answer holds up no other context's sweep.
    Task.detached(priority: .utility) {
      await withTaskGroup(of: (DriverKey, [String], Bool).self) { group in
        for key in claimed {
          if let driver = drivers[key] {
            group.addTask {
              let failures = await sweep(driver, known, images, onlyPending)
              return (
                key, failures,
                !failures.contains { $0.hasPrefix(ContainerHostDriver.listingFailed) }
              )
            }
          } else if let pendingIn = self.pendingIn {
            let ids = Set(machines.filter { $0.key == key }.map(\.id))
            group.addTask {
              // Through `destroy`, which first checks the driver's account: another account's
              // "not found" would read as gone.
              let failures = await PendingMachines.sweep(ids, in: pendingIn) {
                guard let driver = try self.driver(key) as? any ProvisioningHostDriver else {
                  throw HostDriverError.invalidConfiguration("This host cannot be swept")
                }
                try await driver.destroy(.remote($0))
              }
              // Done for the launch either way: a removal that failed (another account signed
              // in, say) is tried at the next launch, not at every reload.
              return (key, failures, true)
            }
          }
        }
        for await (key, failures, ran) in group {
          self.finishSweep(key, ran: ran)
          for failure in failures {
            Self.logger.error("remote host sweep: \(failure, privacy: .public)")
          }
        }
      }
    }
  }

  /// The driver key a new workroom on a host of `kind` wants: a container runtime's (`key(for:)`
  /// below), or for boxd the org and account it is signed in to now (#356).
  func key(for kind: HostKind) async throws -> DriverKey {
    switch kind {
    case .ssh:
      throw HostDriverError.invalidConfiguration("Choose an SSH host first")
    case .container(let runtime): return try await key(for: runtime)
    case .boxd:
      // The org and account boxd is signed in to now, which a new base is made in. Throws, naming
      // `boxd auth login`, when nobody is signed in.
      guard let cli = RemoteHosts.boxdExecutable() else {
        throw RemoteWorkrooms.Failure.boxdNotInstalled
      }
      let account = try await Self.boxd(cli: cli).signedIn()
      return .boxd(org: account.activeOrg, account: try account.requiredUserID())
    case .exeDev:
      // The account exe.dev knows the user's key as, which a new base is made in. Throws, naming
      // the fix, when the user's ssh can't sign in to exe.dev.
      return .exeDev(account: try await Self.exeDev().signedIn())
    case .railway:
      // This Mac's environment in the `Workroom` project of the workspace the user picked, made
      // on the first create (ADR 0071). Throws `RailwaySessionError.signedOut` when signed out.
      let placement = RailwayAccount.placement
      guard let workspace = placement.read().selectedWorkspaceID ?? placement.read().workspaceID
      else { throw RemoteWorkrooms.Failure.railwayNotSetUp }
      let placed = try await placement.ensure(
        workspaceID: workspace, api: RailwayAccount.shared.api,
        environmentName: RailwayPlacementStore.environmentName())
      return .railway(environment: placed.environmentID)
    }
  }

  /// The driver key a new workroom on `runtime` wants (#309): Apple's runtime has one, and Docker's
  /// is the context the CLI uses now, which the new host is pinned to.
  func key(for runtime: ContainerRuntime) async throws -> DriverKey {
    guard runtime == .docker else { return DriverKey(runtime: runtime) }
    return DriverKey(runtime: .docker, context: try await container().currentContext())
  }

  /// The sequence's environment over `key`'s driver.
  @MainActor
  func environment(_ key: DriverKey = DriverKey()) throws -> (
    any HostTerminalDriver, RemoteProvisioning.Environment
  ) {
    // A local container workroom's git credentials come from the Mac's own `gh` (#309). A remote
    // host's never do: it must fetch and push with the Mac closed, so it takes the provider's own.
    let driver = try driver(key)
    let environment = RemoteProvisioning.Environment(
      driver: driver, daemonSocket: driver.daemonSocket,
      gitHubToken: key.isRemoteProvider ? nil : CredentialRelay.gitHubToken,
      credentialHint: key.kind.credentialHint,
      grantRepository: (driver as? any RepositoryGranting).map { granting in
        { @Sendable (repository: GitHubRepository) async throws in
          try await granting.grantGitHub(
            host: repository.host, owner: repository.owner, name: repository.name)
        }
      })
    return (driver, environment)
  }

  /// What deleting `hosts` needs, checked before anything is removed (#253): an environment per
  /// runtime and Docker context they are on (#309), or nil when none of them is live. Throws when
  /// signed out or without a runtime they need. Refuses one another build made
  /// (`RemoteWorkrooms.checkDeletable`).
  @MainActor
  func environment(toDelete hosts: [HostDescriptor]) throws -> Deletion? {
    guard try RemoteWorkrooms.checkDeletable(hosts) else { return nil }
    var environments: [DriverKey: RemoteProvisioning.Environment] = [:]
    for host in hosts where RemoteWorkrooms.isLive(host) {
      let key = try Self.deletionKey(host)
      switch key {
      case .ssh, .railway: try (driver(key) as? any HostRecording)?.adopt(host)
      default: break
      }
      if environments[key] == nil { environments[key] = try environment(key).1 }
      // Taking a box down needs it on its driver, whatever a reload adopted: one that has not
      // adopted it yet would read the box as unknown. A boxd driver needs nothing adopted.
      guard key.runtime != nil else { continue }
      adoptLogged(host, into: try container(key))
    }
    return environments.isEmpty ? nil : Deletion(environments: environments)
  }

  /// `descriptor`'s host taken on by `driver`, unless it holds it already; a record it can't take
  /// is logged.
  private func adoptLogged(_ descriptor: HostDescriptor, into driver: ContainerHostDriver) {
    do { try driver.adopt(descriptor) } catch {
      let id = descriptor.id?.uuidString ?? "?"
      Self.logger.error("adopting host \(id, privacy: .public): \(error, privacy: .public)")
    }
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
      (try? HostDriverRegistry.deletionKey(host)).flatMap { environments[$0] }
    }
  }

  /// A boxd driver acting for `org` and `account` through the CLI at `cli`. With neither, the one a
  /// setup or a create asks who is signed in.
  static func boxd(cli: String, org: String? = nil, account: String? = nil) -> BoxdHostDriver {
    BoxdHostDriver(
      configuration: boxdConfiguration(cli: cli, org: org, account: account),
      directory: RemoteHosts.hosts)
  }

  /// A boxd driver's configuration for this app: the CLI and its home (`RemoteHosts.boxdHome`).
  static func boxdConfiguration(
    cli: String, org: String? = nil, account: String? = nil
  ) -> BoxdHostDriver.Configuration {
    BoxdHostDriver.Configuration(
      cli: URL(fileURLWithPath: cli), org: org, account: account,
      sshConfig: RemoteHosts.boxdHome.appendingPathComponent(".ssh/config"),
      knownHosts: RemoteHosts.boxdHome.appendingPathComponent(".ssh/known_hosts"),
      home: RemoteHosts.boxdHome, hostSetup: .bundled)
  }

  /// An exe.dev driver acting for `account`. With none, the one a setup or a create asks who the
  /// user's ssh signs in as.
  static func exeDev(account: String? = nil) -> ExeDevHostDriver {
    ExeDevHostDriver(
      configuration: .init(account: account, hostSetup: .bundled), directory: RemoteHosts.hosts)
  }

  /// A Railway driver making its sandboxes in `environment`, and reaching any host it adopts.
  static func railway(environment: String) -> RailwayHostDriver {
    let placement = RailwayAccount.placement.read()
    var relay = RailwayHostDriver.relay
    #if DEBUG
      // A test's panes and connects reach nothing.
      if AppEnvironment.current.isTestProcess { relay = UITestFixture.railwayRelay }
    #endif
    return RailwayHostDriver(
      configuration: .init(
        environmentID: environment,
        projectID: placement.environmentID == environment ? placement.projectID : nil,
        keys: RailwayAccount.directory, relayHost: relay, hostSetup: .bundled),
      api: RailwayAccount.shared.api, directory: RemoteHosts.hosts)
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

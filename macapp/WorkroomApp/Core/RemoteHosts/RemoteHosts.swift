import DaemonConnection
import Defaults
import Foundation
import HostDrivers
import WorkroomDomain
import WorkroomVCS
import WorkroomWire
import os

/// The app's remote hosts (#253): a `ContainerHostDriver` per container runtime and Docker context
/// on this Mac (#309), the hosts config records adopted into theirs at each reload, and one sweep
/// per launch for what no record names. A boxd or exe.dev host is reached by name through its
/// provider's driver, never adopted (#356); of its machines, only those a create left pending are
/// swept (#373).
final class RemoteHosts: @unchecked Sendable {
  static let shared = RemoteHosts()

  private let lock = NSLock()
  /// Which driver a host is in (#309, #356): its kind (`HostKind`), and who that driver acts for.
  /// A container runtime on this Mac, and for Docker the context it names (nil names none); a boxd
  /// org (nil is the account's own) and account; an exe.dev account; or an SSH destination.
  enum DriverKey: Hashable, Sendable {
    case container(ContainerRuntime, context: String?)
    case boxd(org: String?, account: String?)
    /// An exe.dev account, `whoami`'s email (#259).
    case exeDev(account: String?)
    case ssh(destination: String)

    /// The driver a recorded host is in, or nil for a descriptor of no driver this build knows, and
    /// for an SSH host whose destination doesn't check out.
    init?(_ descriptor: HostDescriptor) {
      switch descriptor.kind {
      case .ssh:
        guard let destination = descriptor.sshDestination,
          (try? SSHHostDriver.validateDestination(destination)) != nil
        else { return nil }
        self = .ssh(destination: destination)
      case .boxd: self = .boxd(org: descriptor.org, account: descriptor.account)
      case .exeDev: self = .exeDev(account: descriptor.account)
      case .container(let runtime):
        self.init(runtime: runtime, context: descriptor.container?.context)
      case nil: return nil
      }
    }

    init(runtime: ContainerRuntime = .docker, context: String? = nil) {
      // Apple's runtime has no contexts.
      self = .container(runtime, context: runtime == .docker ? context : nil)
    }

    /// The kind of host this driver makes and reaches.
    var kind: HostKind {
      switch self {
      case .container(let runtime, _): .container(runtime)
      case .boxd: .boxd
      case .exeDev: .exeDev
      case .ssh: .ssh
      }
    }

    /// Whether the key names a remote provider rather than a container runtime on this Mac
    /// (`HostKind.isRemoteProvider`).
    var isRemoteProvider: Bool { kind.isRemoteProvider }

    /// The user its driver's hosts log in as, whose home holds the clone.
    var loginUser: String {
      switch self {
      case .container: RemoteWorkrooms.user
      case .boxd: BoxdHostDriver.user
      case .exeDev: ExeDevHostDriver.user
      case .ssh: ""
      }
    }

    /// The container runtime, or nil for a remote provider.
    var runtime: ContainerRuntime? {
      if case .container(let runtime) = kind { return runtime }
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
      switch self {
      case .boxd(_, let account), .exeDev(let account): account
      case .container, .ssh: nil
      }
    }
  }

  /// The drivers made so far.
  private var made: [DriverKey: any HostTerminalDriver] = [:]
  /// The driver each host config records it in, whether or not that driver has been made.
  private var keys: [UUID: DriverKey] = [:]
  /// Workroom hosts whose git credentials come through the Mac's relay (#309).
  private var relayed: Set<UUID> = []
  /// The driver keys whose sweep ran this launch, and those whose sweep is running (#284).
  private var swept: Set<DriverKey> = []
  private var sweeping: Set<DriverKey> = []
  /// A call reached the sweep while a delete was in flight and left it for later (#296).
  private var held = false
  /// The connection attempt running for each host, which `ensureConnected` callers share, and
  /// whether it starts a stopped container first.
  private var connecting: [HostID: (task: Task<Void, Error>, starts: Bool)] = [:]
  /// When each host's last attempt failed, which answers for it for `retryAfter`, and whether it
  /// failed for an older layout (#525), which the backoff keeps saying.
  private var failedAt: [HostID: (at: ContinuousClock.Instant, olderLayout: Bool)] = [:]
  /// When boxd last said each host was asleep, which answers for it for `retryAfter` (#356).
  private var asleepAt: [HostID: ContinuousClock.Instant] = [:]
  /// The host of the workroom selected in each window (one `AppStore` per window), which a
  /// background read reconnects whatever its daemon last did.
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
  /// `connect`'s daemon connection, bootstrap included; nil in the app (`DaemonBootstrap.connect`).
  private let connectDaemon:
    (@Sendable (HostID, any HostTerminalDriver) async throws -> DaemonVCSConnection)?
  private let isConnected: (@Sendable (HostID) async -> Bool)?
  /// What boxd says of a boxd host (`BoxdHostDriver.presence`); nil in the app.
  private let presenceSeam: (@Sendable (HostID) async -> BoxdHostDriver.Presence?)?
  private let startHost: (@Sendable (HostID) async throws -> Void)?
  private let now: @Sendable () -> ContinuousClock.Instant
  /// `adopt`'s seams, nil in the app: making a key's driver, and sweeping one.
  private let makeDriver: (@Sendable (DriverKey) throws -> any HostTerminalDriver)?
  private let sweepDriver:
    (@Sendable (ContainerHostDriver, Set<UUID>, Set<String>, Bool) async -> [String])?
  /// Where `adopt` looks for the runtimes with containers pending
  /// (`ContainerHostDriver.pending(in:)`), or nil to look nowhere.
  private let pendingIn: URL?

  init(
    connectHost: (@Sendable (HostID) async throws -> Void)? = nil,
    isConnected: (@Sendable (HostID) async -> Bool)? = nil,
    startHost: (@Sendable (HostID) async throws -> Void)? = nil,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    makeDriver: (@Sendable (DriverKey) throws -> any HostTerminalDriver)? = nil,
    sweepDriver: (
      @Sendable (ContainerHostDriver, Set<UUID>, Set<String>, Bool) async -> [String]
    )? =
      nil,
    relayHost: (@Sendable (HostID) async throws -> Void)? = nil,
    connectDaemon: (
      @Sendable (HostID, any HostTerminalDriver) async throws -> DaemonVCSConnection
    )? =
      nil,
    presence: (@Sendable (HostID) async -> BoxdHostDriver.Presence?)? = nil,
    pendingIn: URL? = RemoteHosts.pendingIn
  ) {
    self.pendingIn = pendingIn
    self.presenceSeam = presence
    self.connectHost = connectHost
    self.relayHost = relayHost
    self.connectDaemon = connectDaemon
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
  /// How long a host's daemon has to answer after a wake or a network change before its links are
  /// replaced (`unansweringProviderHosts`).
  static let answerDeadline: TimeInterval = 2
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
      let hosts = Self.hosts
      let driver: any HostTerminalDriver
      if let makeDriver {
        driver = try makeDriver(key)
      } else if case .boxd(let org, let account) = key {
        let cli = Self.boxdExecutable()
        driver = BoxdHostDriver(
          configuration: Self.boxdConfiguration(
            cli: cli ?? Self.boxdCandidates[0], org: org, account: account),
          directory: hosts)
        // Not kept while the CLI is missing, so installing it later takes without a relaunch.
        guard cli != nil else { return driver }
      } else if case .exeDev(let account) = key {
        driver = ExeDevHostDriver(configuration: .init(account: account), directory: hosts)
      } else if case .ssh(let destination) = key {
        driver = SSHHostDriver(
          configuration: .init(
            destination: destination, home: "", stateDirectoryName: Self.sshStateDirectoryName),
          directory: hosts)
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

  /// Where every container driver writes its hosts' files.
  static var hosts: URL { directory.appendingPathComponent("hosts", isDirectory: true) }

  static var sshStateDirectoryName: String {
    RemoteWorkrooms.sharedHostBuilds.contains(RemoteWorkrooms.provisioner)
      ? "workroom" : "workroom-dev"
  }

  /// `hosts`, except under test (a hosted unit run or a UI-test launch), which must never sweep
  /// the developer's own runtime.
  static var pendingIn: URL? { AppEnvironment.current.isTestProcess ? nil : hosts }

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

  /// The driver that holds host `id`, for a pane, which must not probe Docker: nil when no driver
  /// made so far has it. A remote provider's driver (boxd, #356) is made here if need be: it reaches
  /// the host by name, with nothing to adopt and no runtime to probe.
  func existingDriver(holding id: UUID) -> (any HostTerminalDriver)? {
    let key = lock.withLock { keys[id] }
    if let key, key.isRemoteProvider { return try? driver(key) }
    return lock.withLock {
      made.values.first { ($0 as? ContainerHostDriver)?.record(of: .remote(id)) != nil }
    }
  }

  /// Takes on every host `projects` record, each into the driver for its Docker context, so their
  /// panes and services reach them after a relaunch, then sweeps once per launch what carries this
  /// app's labels and no record names, and the remote provider machines a create left pending
  /// (#373). Does nothing, and never touches Docker, when nothing is recorded, nothing has been
  /// made, and no create left a container or machine pending (#284). `sweep: false`
  /// holds the sweep for a later call: a list with a delete in flight leaves out hosts config
  /// still records (#296).
  func adopt(_ projects: [Project], sweep: Bool = true) {
    let descriptors =
      projects.flatMap { BaseRetirement.bases(of: $0.host) }
      + projects.flatMap { $0.workrooms.compactMap(\.host) }
    // Another build's hosts take another key: adopted here, they would refuse every login. A
    // remote provider's host Release and Nightly share is both's (`ownsHost`).
    let recorded = descriptors.filter {
      DriverKey($0) != nil && RemoteWorkrooms.ownsHost($0)
    }
    for descriptor in recorded where descriptor.kind == .ssh {
      guard let key = DriverKey(descriptor), let home = descriptor.sshHome else { continue }
      do { try (driver(key) as? SSHHostDriver)?.adopt(home: home) } catch {
        Self.logger.error("SSH host record: \(error.localizedDescription, privacy: .public)")
      }
    }
    // An older build's base, until `BaseRetirement` removes it: it never relays.
    let bases = Set(projects.flatMap { BaseRetirement.bases(of: $0.host).compactMap(\.id) })
    let already = lock.withLock {
      for descriptor in recorded {
        if let id = descriptor.id, let key = DriverKey(descriptor) { keys[id] = key }
        // A base never has git ask for credentials; only its workrooms are relayed. A newly relayed
        // host can be connected already (its create opened the connection before it was
        // recorded), so the next connection check installs its relay; one a connect installs it on
        // clears this.
        if let id = descriptor.id, descriptor.isRelayed, !bases.contains(id),
          relayed.insert(id).inserted
        {
          relayPending[id] = relayPending[id] ?? now() - Self.retryAfter
        }
      }
      return Set(made.keys)
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
      do { driver = try containerDriver(key) } catch {
        // That runtime isn't installed; another's may be.
        Self.logger.error("remote hosts: \(error.localizedDescription, privacy: .public)")
        continue
      }
      drivers[key] = driver
      // Every recorded host, not only this key's: two contexts can name one daemon.
      driver.forgetPending(recorded.compactMap(\.id).map(ContainerHostDriver.containerName))
      for descriptor in recorded where !descriptor.isDestroyed && DriverKey(descriptor) == key {
        guard let id = descriptor.id, let record = descriptor.container,
          driver.record(of: .remote(id)) == nil
        else { continue }
        do { try driver.adopt(id, record) } catch {
          Self.logger.error("adopting host \(id, privacy: .public): \(error, privacy: .public)")
        }
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
      guard let cli = Self.boxdExecutable() else { throw RemoteWorkrooms.Failure.boxdNotInstalled }
      let account = try await BoxdHostDriver(
        configuration: Self.boxdConfiguration(cli: cli), directory: Self.directory
      ).signedIn()
      return .boxd(org: account.activeOrg, account: try account.requiredUserID())
    case .exeDev:
      // The account exe.dev knows the user's key as, which a new base is made in. Throws, naming
      // the fix, when the user's ssh can't sign in to exe.dev.
      return .exeDev(
        account: try await ExeDevHostDriver(configuration: .init(), directory: Self.hosts)
          .signedIn())
    }
  }

  /// The driver key a new workroom on `runtime` wants (#309): Apple's runtime has one, and Docker's
  /// is the context the CLI uses now, which the new host is pinned to.
  func key(for runtime: ContainerRuntime) async throws -> DriverKey {
    guard runtime == .docker else { return DriverKey(runtime: runtime) }
    return DriverKey(runtime: .docker, context: try await containerDriver().currentContext())
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
      grantRepository: (driver as? ExeDevHostDriver).map { exeDev in
        { @Sendable (repository: GitHubRepository) async throws in
          try await exeDev.grantGitHub(
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
      if case .ssh = key, let home = host.sshHome,
        let ssh = try driver(key) as? SSHHostDriver
      {
        try ssh.adopt(home: home)
      }
      if environments[key] == nil { environments[key] = try environment(key).1 }
      // Taking a box down needs it on its driver, whatever a reload adopted: one that has not
      // adopted it yet would read the box as unknown. A boxd driver needs nothing adopted.
      guard key.runtime != nil else { continue }
      let driver = try containerDriver(key)
      guard let id = host.id, let record = host.container, driver.record(of: .remote(id)) == nil
      else { continue }
      do { try driver.adopt(id, record) } catch {
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

  /// The app's service connection to `host` (`HostConnectionManager`), with its daemon bootstrapped
  /// first. One already there is kept.
  func connect(_ host: HostID, driver: any HostTerminalDriver) async throws {
    _ = try await HostConnectionManager.shared.connectIfDisconnected(host: host) {
      [connectDaemon] in
      if let connectDaemon { return try await connectDaemon(host, driver) }
      return try await DaemonBootstrap.connect(
        host: host, driver: driver, socket: driver.daemonSocket)
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
            daemonBinary: (held as? any DaemonPlacingDriver)?.daemonPath(on: host)
              ?? DaemonInstall.binary(besideSocket: held.daemonSocket),
            socket: held.daemonSocket)
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
    guard
      lock.withLock({
        relayPending[id] = nil
        return relayed.remove(id)
      }) != nil
    else { return }
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
  /// `wake` for something the user did (a click, a pane attaching, a port forward in use): the user
  /// asked for this host, so a boxd box that is asleep is connected, and woken, rather than refused
  /// as a background read is.
  func ensureConnected(_ host: HostID, wake: Bool = false) async throws {
    guard case .remote = host else { return }
    // Tried whatever came of the last attempt, as an opened host is: waking a box can fail once
    // while it resumes, and a second try must not wait out the window.
    if wake {
      lock.withLock {
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
      now() - failed.at < Self.retryAfter
    {
      if failed.olderLayout { throw RepositoryRoutingError.olderLayout(host) }
      throw RepositoryRoutingError.unavailable(host)
    }
    // A boxd box wakes on an ssh login, so a background read must not connect to one that is
    // asleep: every status sweep would wake every box and keep it billing (#356). Only opening or
    // selecting the workroom, or something the user did (`wake`), wakes it. When boxd can't say,
    // the read leaves it be too. One boxd says is gone is reported as such, not as asleep.
    if !opened, !wake, !selected {
      switch try await boxdPresence(host) {
      case .asleep: throw RepositoryRoutingError.asleep(host)
      case .gone:
        lock.withLock { failedAt[host] = (now(), false) }
        throw RepositoryRoutingError.gone(host)
      case .awake, nil: break  // nil: not a boxd host
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
          // Not awaited: only panes wait for it, and they do so in the container.
          Task { await self.runPostStart(on: host) }
        }
        connecting[host] = (task, start != nil)
        return task
      }
      defer { lock.withLock { if connecting[host]?.task == task { connecting[host] = nil } } }
      try await task.value
      lock.withLock { failedAt[host] = nil }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // The one failure with something the user can do about it, so it keeps its words (D3, #525):
      // a host from before the daemon's rename, or a container from before #308.
      var olderLayout = false
      if case DaemonBootstrap.Error.olderLayout = error { olderLayout = true }
      if case HostDriverError.olderContainer = error { olderLayout = true }
      lock.withLock { failedAt[host] = (now(), olderLayout) }
      Self.logger.error(
        "connecting \(String(describing: host), privacy: .public): \(error, privacy: .public)")
      if olderLayout { throw RepositoryRoutingError.olderLayout(host) }
      throw RepositoryRoutingError.unavailable(host)
    }
  }

  /// A container's postStartCommand, on the first connect after each start of it (#308, eng review
  /// D12); its panes wait for it in the container, and a second connect meanwhile finds it under
  /// way there. How it went is logged, never thrown: the connect itself worked.
  private func runPostStart(on host: HostID) async {
    guard let driver = try? heldDriver(host) as? ContainerHostDriver else { return }
    do {
      guard let (status, said) = try await driver.runPostStartIfNeeded(on: host) else { return }
      Self.logger.notice(
        "postStartCommand on \(String(describing: host), privacy: .public) exited \(status): \(said, privacy: .public)"
      )
    } catch {
      Self.logger.error(
        "postStartCommand on \(String(describing: host), privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
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
    }
  }

  /// The workroom selected in `window` is on `host` (nil for one on this Mac, or a window closing).
  /// A host selected in any window is reconnected by a background read, as an opened one is.
  func select(_ host: HostID?, in window: AnyHashable = "default") {
    lock.withLock { selectedHosts[window] = host }
  }

  /// What boxd says of `host` (awake, asleep, or gone), or nil only when it isn't a boxd host. A
  /// boxd that can't say is taken as asleep, logged, so a background read leaves the box be. boxd
  /// is asked at most once a `retryAfter` about a box it called asleep.
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
    lock.withLock { asleepAt[host] = presence == .asleep || presence == nil ? now() : nil }
    // boxd could not say (no CLI, a timeout, output it did not expect, the read cancelled): a
    // background read leaves the box be rather than wake it, and says why. Opening the workroom,
    // selecting it or a click still connects. Remembered as asleep is, so an outage asks boxd once a
    // `retryAfter` rather than on every read.
    guard let presence else {
      Self.logger.notice(
        "boxd could not say whether host \(id, privacy: .public) is asleep; left it be")
      return .asleep
    }
    return presence
  }

  /// The Mac woke or changed networks (`RemoteLinkMonitor`): the provider hosts whose links may be
  /// dead, all asked at once. Each is one whose service link didn't answer within `answerDeadline`,
  /// now dropped, or one with no link to ask. Its panes attach again, and a pane's attach reconnects
  /// the link (`PersistentSessionService.attachCommand`). A container's link is loopback and is not
  /// asked.
  func unansweringProviderHosts() async -> Set<HostID> {
    let hosts = lock.withLock {
      keys.filter { $0.value.isRemoteProvider }.map { HostID.remote($0.key) }
    }
    return await withTaskGroup(of: (HostID, Bool).self) { group in
      for host in hosts {
        group.addTask {
          let answered = await HostConnectionManager.shared.dropUnlessAnswering(
            host, within: Self.answerDeadline)
          if !answered, case .remote(let id) = host,
            let ssh = self.existingDriver(holding: id) as? SSHHostDriver
          {
            await ssh.invalidateConnection()
          }
          return (host, answered)
        }
      }
      var unanswering: Set<HostID> = []
      for await (host, answered) in group where !answered { unanswering.insert(host) }
      return unanswering
    }
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

  /// Where the boxd CLI is (#356): its installer's (`~/.local/bin`), or Homebrew's. Under a
  /// stand-in home (`boxdHome`), only that home's, so a boxd the developer has installed doesn't
  /// skip the setup's Install step and the one it installs is the one found.
  static var boxdCandidates: [String] {
    let installed = boxdHome.appendingPathComponent(".local/bin/boxd").path
    guard boxdHome == FileManager.default.homeDirectoryForCurrentUser else { return [installed] }
    return [installed, "/opt/homebrew/bin/boxd", "/usr/local/bin/boxd"]
  }

  /// The home the boxd CLI runs with, which holds its sign-in and the ssh files it writes: the
  /// user's own. Debug builds only: `$WR_BOXD_HOME` instead, a stand-in home, so a developer can be a
  /// user boxd has never seen without signing their own boxd out (`Scripts/boxd-fresh-user.sh`).
  static let boxdHome: URL = {
    #if DEBUG
      if let path = ProcessInfo.processInfo.environment["WR_BOXD_HOME"], !path.isEmpty {
        return URL(fileURLWithPath: path, isDirectory: true)
      }
    #endif
    return FileManager.default.homeDirectoryForCurrentUser
  }()

  /// A boxd driver's configuration for this app: the CLI and its home (`boxdHome`).
  static func boxdConfiguration(
    cli: String, org: String? = nil, account: String? = nil
  ) -> BoxdHostDriver.Configuration {
    BoxdHostDriver.Configuration(
      cli: URL(fileURLWithPath: cli), org: org, account: account,
      sshConfig: boxdHome.appendingPathComponent(".ssh/config"),
      knownHosts: boxdHome.appendingPathComponent(".ssh/known_hosts"), home: boxdHome)
  }

  /// The boxd CLI on this Mac, or nil when it isn't installed.
  static func boxdExecutable() -> String? {
    boxdCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  /// `runtime`'s CLI on this Mac, or nil when it isn't installed.
  static func executable(for runtime: ContainerRuntime) -> String? {
    (runtime == .docker ? runtimeCandidates : appleCandidates).first {
      FileManager.default.isExecutableFile(atPath: $0)
    }
  }

  /// What each container workroom on `runtime` gets (#309): the hidden settings, else for Apple's
  /// runtime, whose own default is a 1 GB VM per container, half this Mac's cores and a quarter of
  /// its memory, between 2 and 8 GB. Docker's containers share Docker's VM, which already bounds
  /// them, so they get nothing unless set.
  static func resources(
    for runtime: ContainerRuntime, cpus: Int? = Defaults[.containerCPUs],
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

extension PendingMachines.Entry {
  var key: RemoteHosts.DriverKey? {
    RemoteHosts.DriverKey(HostDescriptor(driver: driver, org: org, account: account))
  }
}

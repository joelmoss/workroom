import DaemonConnection
import Foundation
import HostDrivers
import WorkroomDomain
import WorkroomVCS
import WorkroomWire
import os

/// How the app reaches a remote host (`docs/remote-host-states.md`): its service connection, made
/// once for every caller and backed off after a failure; whether a background read may wake a box
/// that is asleep or start a container that is stopped; the credential relay a relayed workroom's
/// git asks through (#309); and which links to drop after a wake or a network change. The drivers
/// are the registry's.
final class HostReachability: @unchecked Sendable {
  private let lock = NSLock()
  /// Where each host's driver is found.
  private let registry: HostDriverRegistry
  /// Workroom hosts whose git credentials come through the Mac's relay (#309).
  private var relayed: Set<UUID> = []
  /// The connection attempt running for each host, which `ensureConnected` callers share, and
  /// whether it starts a stopped container first.
  private var connecting: [HostID: (task: Task<Void, Error>, starts: Bool)] = [:]
  /// When each host's last attempt failed, which answers for it for `retryAfter`, and whether it
  /// failed for an older layout (#525), which the backoff keeps saying.
  private var failedAt: [HostID: (at: ContinuousClock.Instant, olderLayout: Bool)] = [:]
  /// The hosts their provider last said are gone, which the backoff keeps saying, so the status
  /// shows gone (with Remove Workroom) rather than unreachable (#629).
  private var gone: Set<HostID> = []
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
    (@Sendable (HostID, any HostTerminalDriver) async throws -> DaemonClient)?
  private let isConnected: (@Sendable (HostID) async -> Bool)?
  /// What a host's provider says of it (`HostPresenceReporting`); nil in the app.
  private let presenceSeam: (@Sendable (HostID) async -> HostPresence?)?
  private let startHost: (@Sendable (HostID) async throws -> Void)?
  private let now: @Sendable () -> ContinuousClock.Instant
  /// Hears a host become gone, or be found again (`GoneHosts.record` in the app).
  private let goneChanged: (@Sendable (HostID, Bool) -> Void)?
  /// The version `host`'s daemon greeted the service connection with; nil in the app
  /// (`HostConnectionManager.daemonVersion`).
  private let daemonVersionSeam: (@Sendable (HostID) async -> UInt16?)?
  /// The bootstrap alone, which says what became of the host's daemon; nil in the app
  /// (`DaemonBootstrap.ensure`).
  private let updateDaemonSeam: (@Sendable (HostID) async throws -> DaemonBootstrap.Outcome.Daemon)?
  /// Hosts whose daemon is too old for a pane's attach (`DaemonHandshake.minHostAttachVersion`),
  /// which the bootstrap left as it was: when to try updating it again, how long the wait after
  /// that is, why it was kept, and whether a try is under way.
  private var olderDaemon:
    [HostID: (next: ContinuousClock.Instant, wait: Duration, why: String?, trying: Bool)] = [:]

  init(
    registry: HostDriverRegistry,
    connectHost: (@Sendable (HostID) async throws -> Void)? = nil,
    isConnected: (@Sendable (HostID) async -> Bool)? = nil,
    startHost: (@Sendable (HostID) async throws -> Void)? = nil,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    relayHost: (@Sendable (HostID) async throws -> Void)? = nil,
    connectDaemon: (
      @Sendable (HostID, any HostTerminalDriver) async throws -> DaemonClient
    )? = nil,
    presence: (@Sendable (HostID) async -> HostPresence?)? = nil,
    goneChanged: (@Sendable (HostID, Bool) -> Void)? = nil,
    daemonVersion: (@Sendable (HostID) async -> UInt16?)? = nil,
    updateDaemon: (@Sendable (HostID) async throws -> DaemonBootstrap.Outcome.Daemon)? = nil
  ) {
    self.registry = registry
    self.daemonVersionSeam = daemonVersion
    self.updateDaemonSeam = updateDaemon
    self.goneChanged = goneChanged
    self.connectHost = connectHost
    self.isConnected = isConnected
    self.startHost = startHost
    self.now = now
    self.relayHost = relayHost
    self.connectDaemon = connectDaemon
    self.presenceSeam = presence
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

  /// The app's service connection to `host` (`HostConnectionManager`), with its daemon bootstrapped
  /// first. One already there is kept.
  func connect(_ host: HostID, driver: any HostTerminalDriver) async throws {
    _ = try await HostConnectionManager.shared.connectIfDisconnected(host: host) {
      [connectDaemon] in
      if let connectDaemon { return try await connectDaemon(host, driver) }
      return try await DaemonBootstrap.connect(
        host: host, driver: driver, socket: driver.daemonSocket)
    }
    // A host whose git uses a copy of the Mac's gh token gets the current one (ADR 0072), so a
    // token the user rotated doesn't live on there. A failure leaves the workroom usable except
    // for git's remote commands, so it is logged; the next connect tries again.
    if let carrying = driver as? any GitHubTokenCarrying {
      do {
        try await carrying.refreshGitHubToken(on: host)
      } catch {
        Self.logger.error(
          "gh token for \(String(describing: host), privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    // A relayed workroom's git asks this Mac for credentials (#309): its listener goes with the
    // connection, and its secret with this launch, so it is set up again on every connect. A
    // failure leaves the workroom usable except for git's remote commands, so it is logged.
    guard case .remote(let id) = host, isRelayed(id) else { return }
    // Tried a few times: a listen can lose a race with the last connection's teardown.
    await installRelay(host, attempts: 3, driver: driver)
  }

  /// Drops the app's service connection to `host`, if it has one: a delete lets it go before the
  /// host or its last workroom goes.
  func disconnect(_ host: HostID) async {
    if let lease = await HostConnectionManager.shared.snapshot(for: host).lease {
      await HostConnectionManager.shared.disconnect(lease)
    }
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

  /// Takes on every host `projects` record (`HostDriverRegistry.adopt`), and relays each relayed
  /// workroom's git credentials (#309).
  func adopt(_ projects: [Project], sweep: Bool = true) {
    registry.adopt(projects, sweep: sweep, relayed: recordRelayed)
  }

  /// Host config records workroom host `id` as relayed (`adopt`). A newly
  /// relayed host can be connected already (its create opened the connection before it was
  /// recorded), so the next connection check installs its relay; one a connect installs it on
  /// clears this.
  func recordRelayed(_ id: UUID) {
    lock.withLock {
      if relayed.insert(id).inserted {
        relayPending[id] = relayPending[id] ?? now() - Self.retryAfter
      }
    }
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
      found(host)
      // A connection to a daemon the bootstrap kept, too old for a pane: kept, while the update
      // is tried again in the background, backed off.
      await updateOlderDaemon(host)
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
      if lock.withLock({ gone.contains(host) }) { throw RepositoryRoutingError.gone(host) }
      throw RepositoryRoutingError.unavailable(host)
    }
    // A boxd box wakes on an ssh login, so a background read must not connect to one that is
    // asleep: every status sweep would wake every box and keep it billing (#356). Only opening or
    // selecting the workroom, or something the user did (`wake`), wakes it. When boxd can't say,
    // the read leaves it be too. One boxd says is gone is reported as such, not as asleep.
    // A host that never sleeps (Railway's) is asked about on every read, opened or not: asking
    // wakes nothing, and a sandbox Railway destroyed then reads as gone rather than unreachable.
    let background = !opened && !wake && !selected
    if background || !hostsSleep(host) {
      let presence = await presence(host)
      if presence != .gone { found(host) }
      switch presence {
      case .asleep: throw RepositoryRoutingError.asleep(host)
      case .gone:
        let newly = lock.withLock {
          failedAt[host] = (now(), false)
          return gone.insert(host).inserted
        }
        if newly { goneChanged?(host, true) }
        throw RepositoryRoutingError.gone(host)
      // Its relay key still reaches it, so what the user asked for still connects; a background
      // read says why it couldn't check (#629).
      case .signedOut where background: throw RepositoryRoutingError.signedOut(host)
      case .awake, .signedOut, nil: break  // nil: a host that doesn't sleep (not boxd's)
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
          try await (driver as? any StartableHostDriver)?.startIfStopped($0)
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
      // Whatever a read said before: a host that connects is there.
      found(host)
      await updateOlderDaemon(host)
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

  /// How long after a kept older daemon the update is tried again, doubling to `olderDaemonCeiling`.
  static let olderDaemonRetry: Duration = .seconds(30)
  static let olderDaemonCeiling: Duration = .seconds(600)

  /// When `host`'s service connection reaches a daemon too old for a pane's attach, which the
  /// bootstrap left as it was (busy, refused, or the install failed): a connection that works
  /// skips the bootstrap, so its panes would wait for an update nothing tries. The bootstrap is
  /// tried again, in a task of its own, at most once a backoff (`olderDaemonRetry`, doubling), and
  /// once it updated the daemon the connection is replaced. The pane says why it waits
  /// (`waitingNotice`). A daemon new enough clears it.
  private func updateOlderDaemon(_ host: HostID) async {
    let version: UInt16?
    if let daemonVersionSeam {
      version = await daemonVersionSeam(host)
    } else {
      version = await HostConnectionManager.shared.daemonVersion(on: host)
    }
    guard let version, version < DaemonHandshake.minHostAttachVersion else {
      _ = lock.withLock { olderDaemon.removeValue(forKey: host) }
      return
    }
    let now = now()
    let due = lock.withLock { () -> Bool in
      var entry = olderDaemon[host] ?? (now, Self.olderDaemonRetry, nil, false)
      defer { olderDaemon[host] = entry }
      guard !entry.trying, now >= entry.next else { return false }
      entry.trying = true
      return true
    }
    guard due else { return }
    Task { await self.retryBootstrap(host) }
  }

  private func retryBootstrap(_ host: HostID) async {
    var why: String?
    var updated = false
    do {
      let daemon: DaemonBootstrap.Outcome.Daemon
      if let updateDaemonSeam {
        daemon = try await updateDaemonSeam(host)
      } else {
        let driver = try heldDriver(host)
        daemon = try await DaemonBootstrap.ensure(
          host: host, driver: driver, socket: driver.daemonSocket
        ).daemon
      }
      switch daemon {
      case .current, .installed, .handedOff, .keptNewer: updated = true
      case .keptOlder(let reason): why = reason
      }
    } catch {
      why = error.localizedDescription
    }
    lock.withLock {
      guard var entry = olderDaemon[host] else { return }
      entry.trying = false
      entry.why = why ?? entry.why
      entry.next = now() + entry.wait
      entry.wait = min(entry.wait * 2, Self.olderDaemonCeiling)
      olderDaemon[host] = entry
    }
    Self.logger.notice(
      "older daemon on \(String(describing: host), privacy: .public): \(updated ? "updated" : (why ?? "kept"), privacy: .public)"
    )
    guard updated else { return }
    // The connection still speaks to the old program: the next one reaches the new.
    await disconnect(host)
    lock.withLock { failedAt[host] = nil }
    try? await ensureConnected(host)
  }

  /// What a pane on `host` says while it waits to attach, when its host's daemon is too old for
  /// it and couldn't be updated yet (ADR 0074): nil otherwise, for the pane's usual notice.
  func waitingNotice(for host: HostID) -> String? {
    guard let entry = lock.withLock({ olderDaemon[host] }) else { return nil }
    let why = entry.why.map { " (\($0))" } ?? ""
    return "This terminal's host runs an older Workroom daemon, which Workroom couldn't update yet"
      + "\(why). Workroom will keep trying, and your session will be restored once it's updated."
  }

  /// `host` is there (it connected, or its provider no longer says it is gone): no longer gone,
  /// which the views hear once.
  private func found(_ host: HostID) {
    if lock.withLock({ gone.remove(host) }) != nil { goneChanged?(host, false) }
  }

  /// A container's postStartCommand, on the first connect after each start of it (#308, eng review
  /// D12); its panes wait for it in the container, and a second connect meanwhile finds it under
  /// way there. How it went is logged, never thrown: the connect itself worked.
  private func runPostStart(on host: HostID) async {
    guard let driver = try? heldDriver(host) as? any StartableHostDriver else { return }
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

  /// What `host`'s provider says of it (awake, asleep, or gone), or nil only when its driver
  /// doesn't report presence (`HostPresenceReporting`: boxd). A provider that can't say is taken as
  /// asleep, logged, so a background read leaves the box be. It is asked at most once a
  /// `retryAfter` about a box it called asleep.
  // ponytail: one `machine get` per host per window; one `machine list` per sweep is the upgrade
  // if many boxd workrooms make it slow.
  /// Whether `host`'s driver says its hosts sleep; true for one that reports no presence.
  private func hostsSleep(_ host: HostID) -> Bool {
    guard case .remote(let id) = host,
      let reporting = registry.existingDriver(holding: id) as? any HostPresenceReporting
    else { return true }
    return reporting.hostsSleep
  }

  private func presence(_ host: HostID) async -> HostPresence? {
    guard case .remote(let id) = host,
      let reporting = registry.existingDriver(holding: id) as? any HostPresenceReporting
    else { return nil }
    if let slept = lock.withLock({ asleepAt[host] }), now() - slept < Self.retryAfter {
      return .asleep
    }
    let presence: HostPresence?
    if let presenceSeam {
      presence = await presenceSeam(host)
    } else {
      presence = await reporting.presence(host)
    }
    let sleeps = reporting.hostsSleep
    lock.withLock {
      asleepAt[host] = presence == .asleep || (presence == nil && sleeps) ? now() : nil
    }
    // boxd could not say (no CLI, a timeout, output it did not expect, the read cancelled): a
    // background read leaves the box be rather than wake it, and says why. Opening the workroom,
    // selecting it or a click still connects. Remembered as asleep is, so an outage asks boxd once a
    // `retryAfter` rather than on every read. A host that never sleeps is simply connected to.
    guard let presence else {
      guard sleeps else { return nil }
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
    let hosts = registry.providerHosts
    return await withTaskGroup(of: (HostID, Bool).self) { group in
      for host in hosts {
        group.addTask {
          let answered = await HostConnectionManager.shared.dropUnlessAnswering(
            host, within: Self.answerDeadline)
          if !answered, case .remote(let id) = host,
            let reconnecting = self.registry.existingDriver(holding: id)
              as? any ReconnectingHostDriver
          {
            await reconnecting.invalidateConnection()
          }
          return (host, answered)
        }
      }
      var unanswering: Set<HostID> = []
      for await (host, answered) in group where !answered { unanswering.insert(host) }
      return unanswering
    }
  }

  /// The driver holding `host`, which a reload adopted it into (`HostDriverRegistry.adopt`) or
  /// which made it.
  private func heldDriver(_ host: HostID) throws -> any HostTerminalDriver {
    guard case .remote(let id) = host, let driver = registry.existingDriver(holding: id) else {
      throw HostDriverError.unknownHost(host)
    }
    return driver
  }
}

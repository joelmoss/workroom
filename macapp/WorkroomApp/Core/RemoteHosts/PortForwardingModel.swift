import DaemonConnection
import Darwin
import DevContainer
import Foundation
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS

/// The forwards on one remote workroom's host: the ones its dev container declares
/// (`forwardDeclared`) and the ones the user adds, and the listeners serving them.
///
/// One model per HOST (`model(for:)`); a container workroom and a Railway workroom are each their
/// own host (#254, #632), so each has its own list, and a workroom on an SSH host has one of its
/// own (`Place`). boxd and exe.dev workrooms have none: those providers publish a machine's ports
/// themselves (`boxd machine proxy`, `ssh exe.dev share port`), and a workroom on this Mac reaches
/// its ports directly.
@MainActor
final class PortForwardingModel: ObservableObject {
  /// Each host's model, made on first use and kept for the launch: its listeners must outlive the
  /// Details pane showing another workroom and coming back, and a host's connection
  /// (`Transport.reconnect`, #380).
  static var models: [HostID: PortForwardingModel] = [:]
  struct WorkroomKey: Hashable {
    let host: HostID
    let workroom: UUID
  }
  static var workroomModels: [WorkroomKey: PortForwardingModel] = [:]

  static func forgetWorkroom(_ workroom: UUID, on host: HostID) {
    guard let model = workroomModels.removeValue(forKey: .init(host: host, workroom: workroom))
    else { return }
    for entry in model.forwards { model.remove(entry.id) }
  }

  /// A deleted host's forwards go with it: their listeners stop, and nothing reconnects a host that
  /// is gone. Its connection no longer drops them, since a remote host's forwards outlive it (#380).
  static func forgetHost(_ host: HostID) {
    for key in workroomModels.keys.filter({ $0.host == host }) {
      forgetWorkroom(key.workroom, on: host)
    }
    guard let model = models.removeValue(forKey: host) else { return }
    for entry in model.forwards { model.remove(entry.id) }
  }

  /// Which Ports list a remote workroom shows: its host's, or for a workroom on an SSH host its
  /// own (`HostKind.portForwards`). nil for one with no list: a boxd or exe.dev workroom, whose
  /// provider publishes its ports itself, or one whose host this app can't reach. Every forward
  /// rides the host's daemon connection, so a Railway sandbox's go through Railway's relay as an
  /// SSH host's go through ssh (#632).
  struct Place: Hashable {
    let host: HostID
    let workroom: UUID?

    init(host: HostID, workroom: UUID?) {
      self.host = host
      self.workroom = workroom
    }

    init?(kind: HostKind?, host: UUID?, workroom: UUID?) {
      guard let forwards = kind?.portForwards, let host else { return nil }
      switch forwards {
      case .perHost: self.init(host: .remote(host), workroom: nil)
      case .perWorkroom:
        guard let workroom else { return nil }
        self.init(host: .remote(host), workroom: workroom)
      }
    }
  }

  static func model(for place: Place) -> PortForwardingModel {
    model(for: place.host, workroom: place.workroom)
  }

  static func model(for host: HostID, workroom: UUID? = nil) -> PortForwardingModel {
    if let workroom {
      let key = WorkroomKey(host: host, workroom: workroom)
      if let model = workroomModels[key] { return model }
      let model = PortForwardingModel(host: host, transport: .live(host))
      workroomModels[key] = model
      return model
    }
    if let model = models[host] { return model }
    let model = PortForwardingModel(host: host, transport: .live(host))
    models[host] = model
    return model
  }

  /// How the model reaches the daemon, so a test can hand it a scripted daemon and a connection
  /// stream it controls.
  struct Transport {
    /// The service and the lease of the connection it runs on. Never connects a host (`on`).
    var forwarding: @Sendable () async throws -> (HostConnectionManager.Lease, DaemonForwardService)
    var updates: @Sendable () async -> AsyncStream<HostConnectionManager.Snapshot>
    /// The connected lease right now, or nil. What `add()` reconciles against: the watch's last
    /// snapshot can lag a reconnect that `forwarding` has already seen.
    var current: @Sendable () async -> HostConnectionManager.Lease?
    /// A new connection for a forward to carry on once the old one has ended, or nil for a host
    /// whose forwards go with their connection (#380).
    var reconnect: PortForward.Reconnect?

    static func live(_ host: HostID) -> Transport {
      var transport = on(host, manager: .shared)
      transport.reconnect = reconnecting(host, manager: .shared)
      return transport
    }

    /// The reconnect a forward runs when it is used after the host's connection ended (#380): the
    /// user is at the forward, as a click is the user at a workroom. It never starts a stopped
    /// container: `ensureConnected` starts only a host whose workroom was opened, so the reconnect
    /// fails and the row says why.
    static func reconnecting(_ host: HostID, manager: HostConnectionManager)
      -> PortForward.Reconnect
    {
      {
        try? await RemoteHosts.shared.reachability.ensureConnected(host, wake: true)
        return try? await manager.forwarding(host: host).1.connection
      }
    }

    /// `host`'s connection in `manager`. A host's connection is made by selecting its workroom
    /// (`HostReachability.ensureConnected`, through the inspector's reads), so a forward asks for the
    /// one there is and never makes one: connecting could start a container the user stopped.
    static func on(_ host: HostID, manager: HostConnectionManager) -> Transport {
      Transport(
        forwarding: { try await manager.forwarding(host: host) },
        updates: { await manager.updates(for: host) },
        current: {
          let snapshot = await manager.snapshot(for: host)
          return snapshot.status == .connected ? snapshot.lease : nil
        })
    }
  }

  struct Entry: Identifiable, Equatable {
    let id: UUID
    let remotePort: UInt16
    let localPort: UInt16
    /// The dev container's `portsAttributes` label for the port, if it gives one.
    var label: String? = nil
    /// The connection this forward's streams run on. The daemon closes every socket a departing
    /// connection opened, so a forward outlives its lease as a listener that accepts connections it
    /// can never carry — which is why a lease that is no longer the connected one drops the row,
    /// unless the forward reconnects on use (`reconnects`).
    let lease: HostConnectionManager.Lease
    /// The forward reconnects its host when it is used after its connection ended (#380), so it
    /// keeps its row and its local port across a lost connection.
    let reconnects: Bool
    /// Order of creation, so a reconcile judges only the rows that existed when its read began.
    let sequence: Int
    /// The last refusal any connection through this forward hit — `connection refused` and friends.
    /// Kept on the row rather than raised as a toast because it is a property of the forward, and it
    /// arrives when someone connects, not when the forward is added. Cleared by the next connection
    /// that opens.
    var failure: String?
  }

  @Published private(set) var forwards: [Entry] = []
  /// What went wrong adding one, or why the last forwards went away. Cleared by the next attempt.
  @Published private(set) var message: String?
  /// Whether the host's daemon connection is up, for the row's caption: the controls are useless
  /// without one, and a caption says so before the user finds out from `+`.
  @Published private(set) var connected = false
  @Published var draft = ""

  let host: HostID
  private let transport: Transport
  /// Whether a forward tries its port's own number on this Mac first (`PortForward.init`). Off in
  /// tests, which would otherwise hold real port numbers on the Mac running them.
  private let sameLocalPort: Bool
  private var listeners: [UUID: PortForward] = [:]
  private var watching = false
  private var adding = false
  /// `forwardDeclared` is running, or has forwarded what the dev container declares.
  private var declaring = false
  private(set) var declared = false
  /// A `forwardDeclared` pass the host's connection cut short, run again when it connects.
  private var pendingDeclaredRead: DeclaredRead?
  /// The `Entry.sequence` the next row gets.
  private var nextSequence = 0
  /// How many snapshots the watch has consumed, for the tests.
  private(set) var snapshotsSeen = 0

  init(host: HostID = .local, transport: Transport, sameLocalPort: Bool = true) {
    self.host = host
    self.transport = transport
    self.sameLocalPort = sameLocalPort
  }

  /// Add a forward for `draft`. The listener binds before the entry appears, so a row is only ever
  /// shown for a port that really is reachable at the address it names.
  func add() async {
    // Two clicks in quick succession (or a click and a Return) read the same draft; the second one
    // must not make a second listener for the same port.
    guard !adding else { return }
    adding = true
    defer { adding = false }
    message = nil
    guard let remote = UInt16(draft.trimmingCharacters(in: .whitespaces)), remote > 0 else {
      message = "Enter a port between 1 and 65535."
      return
    }
    do {
      try await forward(.init(port: remote))
      draft = ""
    } catch {
      message = Self.describe(error)
    }
  }

  /// Forward the ports the workroom's dev container declares (`DevContainerConfig`), once a launch:
  /// `read` gives its `devcontainer.json`, or nil when it has none. A port already forwarded is
  /// left as it is. A pass the host's connection cuts short (the container not started yet, Docker
  /// not running) runs again once the host connects (`watch`), as well as on the next call; one
  /// that finishes is not repeated, so a declared forward the user removes stays removed. A file
  /// the host refuses or that is too large says so, and is not tried again.
  func forwardDeclared(read: @escaping DeclaredRead) async {
    guard !declaring, !declared else { return }
    declaring = true
    defer { declaring = false }
    let file: (path: String, data: Data)?
    do {
      file = try await read()
    } catch let failure as FileServiceError {
      declared = true
      message = "Couldn't read the dev container file: \(failure.localizedDescription)"
      return
    } catch {
      retryWhenConnected(read)
      return
    }
    guard let file else {
      declared = true
      return
    }
    let ports: [DevContainerConfig.Port]
    do {
      ports = try DevContainerConfig.parse(file.data).ports
    } catch {
      declared = true
      message = "Couldn't read \(file.path): \(error.localizedDescription)"
      return
    }
    var failures: [String] = []
    // Each forward holds a descriptor for the launch, so a file listing hundreds of ports must not
    // take the app's (terminals, ssh and daemon connections share the same limit).
    if ports.count > DevContainerConfig.maxForwards {
      failures.append(
        "\(file.path) declares \(ports.count) ports; only the first "
          + "\(DevContainerConfig.maxForwards) are forwarded.")
    }
    for port in ports.prefix(DevContainerConfig.maxForwards)
    where !forwards.contains(where: { $0.remotePort == port.port }) {
      do {
        try await forward(port)
      } catch let taken as PortForward.LocalPortTaken {
        failures.append(taken.errorDescription ?? "")
      } catch {
        // The host went away mid-way: what is left is forwarded once it is back.
        message = Self.describe(error)
        retryWhenConnected(read)
        return
      }
    }
    declared = true
    message = failures.isEmpty ? nil : failures.joined(separator: "\n")
  }

  /// What `forwardDeclared` reads the dev container file with.
  typealias DeclaredRead = @MainActor () async throws -> (path: String, data: Data)?

  /// Keeps an unfinished `forwardDeclared` pass for the watch to run again when the host connects:
  /// nothing else asks while the workroom stays selected.
  private func retryWhenConnected(_ read: @escaping DeclaredRead) {
    pendingDeclaredRead = read
    watch()
  }

  private func forward(_ port: DevContainerConfig.Port) async throws {
    let (lease, service) = try await transport.forwarding()
    let reconnect = transport.reconnect
    let id = UUID()
    let forward = try service.listen(
      remotePort: port.port, localPort: sameLocalPort ? port.port : 0,
      requireLocalPort: port.requireLocalPort, reconnect: reconnect
    ) { [weak self] event in
      Task { @MainActor in self?.record(event, for: id) }
    }
    listeners[id] = forward
    forwards.append(
      Entry(
        id: id, remotePort: port.port, localPort: forward.localPort, label: port.label,
        lease: lease, reconnects: reconnect != nil, sequence: nextSequence))
    nextSequence += 1
    watch()
    // `forward` suspended while the service was acquired, and a watch that consumed a disconnect in
    // that window had nothing to drop then and may see no further snapshot to drop it by. So ask
    // the manager, not the watch's last snapshot: that one can still name the disconnect when
    // `forwarding` has already answered on the reconnected lease, and would drop a valid row.
    let current = await transport.current()
    drop { !$0.reconnects && $0.lease != current }
  }

  /// The expected refusals in the words of this row, and never a raw enum case for the rest:
  /// `VCSError` is not `LocalizedError`, so interpolating it prints its Swift case.
  static func describe(_ error: Error) -> String {
    switch error {
    case RepositoryRoutingError.unavailable:
      return "This workroom's host is not connected."
    case VCSError.backendVersion(let detail):
      return detail
    default:
      return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
  }

  func remove(_ id: UUID) {
    listeners.removeValue(forKey: id)?.stop()
    forwards.removeAll { $0.id == id }
  }

  private func record(_ event: PortForward.Event, for id: UUID) {
    guard let index = forwards.firstIndex(where: { $0.id == id }) else { return }
    switch event {
    case .opened: forwards[index].failure = nil
    case .failed(let detail): forwards[index].failure = detail
    case .stopped(let detail):
      remove(id)
      message = detail
    }
  }

  /// Follow the host connection: the caption, and the forwards a connection takes with it when it
  /// goes. Each entry carries the lease it was made under, so a snapshot drops exactly the entries
  /// whose connection is not the connected one — a drop, a new generation under a coalesced
  /// `connected` snapshot (the stream buffers newest-only), or a forward that was added against a
  /// connection some other caller had already replaced. Idempotent; the row starts it on appear
  /// and `add()` starts it in case the row never appeared.
  func watch() {
    guard !watching else { return }
    watching = true
    Task { [weak self, transport] in
      // Each snapshot is a prompt to look, not the answer: `add()` and this loop resume in either
      // order, so a disconnect delivered late would otherwise drop a forward `add()` already made
      // on the reconnected lease. Both reconcile against the manager's current lease instead.
      //
      // Only rows that existed when the read began: `add()` can append a row on a lease this read
      // predates while it is in flight, and that row is judged by `add()`'s own read, which starts
      // after its append.
      for await _ in await transport.updates() {
        guard let self else { return }
        let horizon = nextSequence
        let live = await transport.current()
        snapshotsSeen += 1
        connected = live != nil
        drop { $0.sequence < horizon && !$0.reconnects && $0.lease != live }
        if connected, let read = pendingDeclaredRead {
          pendingDeclaredRead = nil
          Task { await self.forwardDeclared(read: read) }
        }
      }
    }
  }

  private func drop(where lost: (Entry) -> Bool) {
    let gone = forwards.filter(lost)
    guard !gone.isEmpty else { return }
    for entry in gone { listeners.removeValue(forKey: entry.id)?.stop() }
    forwards.removeAll(where: lost)
    message = "The daemon connection ended; forwards were closed."
  }
}

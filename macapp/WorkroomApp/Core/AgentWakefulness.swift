import Foundation

/// `Service::Status` (`0x04`) on a wr-agent connection: whether the box is busy (issue #208).
/// Everything here is the wire contract of `vcs/crates/wr-agent/src/wakefulness.rs`.
///
/// **The box decides its own wakefulness (#380).** The agent keeps a busy box awake with its
/// heartbeat, pushes each change of verdict to every connection that has asked for `status`, and
/// closes the app's idle service connection itself so the provider's own timer can sleep the box.
/// The app holds no opinion: it asks once per connection and shows what it is told.
struct AgentWakefulnessService: Sendable {
  let connection: AgentVCSConnection

  /// Asking is also what makes this connection one the agent pushes changes to.
  func status() async throws -> AgentWakefulness {
    try AgentStatusReply<AgentWakefulness>.decode(
      await connection.statusRequest(AgentStatusRequest(method: "status")))
  }

  /// The verdict changes the agent pushes, in arrival order. Finishes when the connection does.
  var changes: AsyncStream<AgentWakefulness> { connection.statusChanges }
}

/// One `{"method": "status"}` reply, or one pushed change, which carries the same.
///
/// `monotonic` is the AGENT's clock (`sample::monotonic()`), not this Mac's and not wall time: it
/// orders two readings of one agent, and means nothing against `Date()`.
///
/// The fields the app acts on are required. The rest of the contract is decoded as optionals: they
/// are diagnostics today, and an agent that renames one must not blank the badge for a number nothing
/// displays. `AgentWakefulnessTests` pins the whole shape against the shipped binary.
struct AgentWakefulness: Decodable, Sendable, Equatable {
  /// Whether the classifier thread is running at all. False on a macOS agent: the service is Linux
  /// only, so a local agent answers `status` truthfully with `running: false` rather than not at all.
  let running: Bool
  let busy: Bool
  let monotonic: Double
  /// What keeps a BUSY box awake (#257): the agent's heartbeat. Nil from an agent that predates it.
  let keepAwake: KeepAwake?
  /// The agent's service has gone several ticks without finishing one, so this reply is its last
  /// tick's and the heartbeat has stopped with it (#257). Nil from an agent that predates the
  /// field.
  let stalled: Bool?
  /// `"BUSY"` or `"IDLE"`, which `busy` already says.
  let verdict: String?
  let cpuFraction: Double?

  /// The agent's keep-awake heartbeat, as `status` reports it.
  struct KeepAwake: Decodable, Sendable, Equatable {
    /// On the agent's monotonic clock, like `monotonic`.
    let lastSent: Double?
    /// Why the last heartbeat could not be sent. Non-nil while BUSY means nothing is keeping the
    /// box awake.
    let error: String?
  }

  /// Work is running and nothing is keeping the box awake: the agent's service has stalled, the
  /// heartbeat is failing, or the agent predates the heartbeat (#257). The one state the badge must
  /// not soften. That last one is real, not hypothetical: a busy box can refuse the hand-off to a
  /// newer agent and keep the old one (`AgentBootstrap`'s `keptOlder`), which keeps nothing awake.
  var unprotected: Bool {
    (busy && stalled == true) || (busy && keepAwake?.error != nil)
      || (running && busy && keepAwake == nil)
  }

  /// What the badge shows. Only these, because only these are actionable: the CPU cost is a
  /// diagnostic. `unknown` is a stalled service whose last reading was IDLE, on a host that sleeps
  /// (#356): that reading may be stale while work runs, and nothing is keeping the box awake either
  /// way.
  enum Display: Equatable { case idle, busy, busyUnprotected, unknown }

  /// What the badge shows for a host that `sleeps` when idle or not. One that never sleeps (a
  /// container) cannot be slept under a job, so nothing there is "not kept awake": an old agent,
  /// a stalled one or a failing heartbeat would only be a false alarm, and its advice (restart the
  /// agent) would end the user's sessions.
  func display(hostSleeps sleeps: Bool) -> Display {
    if sleeps { return display }
    return busy ? .busy : .idle
  }

  var display: Display {
    if unprotected { return .busyUnprotected }
    if stalled == true { return .unknown }
    return busy ? .busy : .idle
  }
}

/// An unsolicited frame on the Status service, stream 0: a change of verdict, carrying what
/// `status` returns. An event kind this build does not know is dropped rather than failing the
/// decode, and so is a version it does not speak, as a reply's would be.
struct AgentStatusEvent: Decodable {
  let version: Int
  let event: String
  var status: AgentWakefulness?
}

struct AgentStatusRequest: Encodable, Sendable {
  var version = 1
  let method: String
}

/// A remote box's verdict, as its agent reports it (#380). One instance per remote host
/// (`model(forHost:)`, #254), because the verdict is per box. This Mac has none: its agent runs no
/// wakefulness service (the service is Linux only).
///
/// It asks `status` once per connection, which also subscribes the connection to the changes the
/// agent pushes, and applies each change as it comes. Nothing polls: a poll's own bytes on the box's
/// network voted the box BUSY, so an open app held an idle box awake.
@MainActor
final class WakefulnessModel: ObservableObject {
  /// The two calls the model makes, so its rules — subscribe, then ask; never run a reading
  /// backwards — are testable without an agent. `live` is the only production implementation.
  struct Transport {
    var status: @Sendable () async throws -> AgentWakefulness
    /// The current connection's pushed changes, or throws when there is no connection.
    var changes: @Sendable () async throws -> AsyncStream<AgentWakefulness>

    /// A remote host's service in `manager` (#254). Never connects the host: a badge is not a
    /// reason to reach it.
    static func on(_ host: HostID, manager: HostConnectionManager) -> Transport {
      Transport(
        status: { try await manager.wakefulness(host: host).status() },
        changes: { try await manager.wakefulness(host: host).changes })
    }
  }

  private let transport: Transport
  let host: UUID
  /// Whether this model's host is put to sleep when idle (`HostDriverTraits.sleepsWhenIdle`), set
  /// from its driver on connect. Assumed until then; nothing shows before a connection anyway.
  var hostSleeps = true

  init(transport: Transport, host: UUID) {
    self.transport = transport
    self.host = host
  }

  /// Each remote host's model, made on first use and kept until its host is deleted, as
  /// `PortForwardingModel`'s are.
  private(set) static var models: [UUID: WakefulnessModel] = [:]

  /// A remote host's model, watching from the moment it is made. The watch never connects the
  /// host; it waits for a connection to be there.
  static func model(forHost id: UUID) -> WakefulnessModel {
    if let model = models[id] { return model }
    let model = WakefulnessModel(transport: .on(.remote(id), manager: .shared), host: id)
    models[id] = model
    model.startWatching()
    return model
  }

  /// The host is gone (deleted): its model and its watch with it.
  static func forgetHost(_ id: UUID) {
    models.removeValue(forKey: id)?.stopWatching()
  }

  /// Nil while there is no reading: no agent yet, an agent that predates the service, or a
  /// connection that ended on a box that was busy, whose reading may no longer hold. A connection
  /// that ended on an IDLE box keeps its reading: the agent let go of it (#380), and the box is
  /// idle, or asleep, until something wakes it.
  @Published private(set) var status: AgentWakefulness?

  /// How long the watch waits before looking for a connection again. A local lookup, nothing sent.
  var retryInterval: Duration = .seconds(10)

  private var watchTask: Task<Void, Never>?

  /// Starts the single watch. Idempotent, and deliberately NOT bound to any view's task:
  /// `AsyncStream` supports exactly ONE iterator, and Workroom has N windows sharing this one
  /// model.
  func startWatching() {
    guard watchTask == nil else { return }
    watchTask = Task { [weak self] in await self?.runWatch() }
  }

  var isWatching: Bool { watchTask != nil }

  func stopWatching() {
    watchTask?.cancel()
    watchTask = nil
  }

  /// One connection at a time: subscribe, ask, then follow what is pushed until the connection
  /// ends. Retries, because there may be no connection yet, and the stream ends with the
  /// connection that carried it.
  private func runWatch() async {
    while !Task.isCancelled {
      // The stream first, then the reply: a change pushed between the two is buffered by the
      // stream, and `apply` keeps the newer of it and the reply, whichever arrives first. The
      // reply is what makes this connection one the agent pushes to at all, so no reply, no
      // stream: try again.
      guard let changes = try? await transport.changes(),
        let first = try? await transport.status()
      else {
        try? await Task.sleep(for: retryInterval)
        continue
      }
      // Each connection's readings are ordered among themselves only: a box that rebooted
      // restarts the agent's clock.
      newest = nil
      apply(first)
      let recheck = Task { [weak self] in await self?.recheckWhileBusy() }
      for await change in changes { apply(change) }
      recheck.cancel()
      guard !Task.isCancelled else { return }
      connectionEnded()
      // A stream that ended at once (handed out already finished, the connection replaced between
      // the two acquisitions) must not spin this loop.
      try? await Task.sleep(for: retryInterval)
    }
  }

  /// How often a BUSY box is asked again. Its agent pushes only when its verdict changes, which is
  /// exactly what a stalled or crashed wakefulness service never does: the heartbeat has stopped,
  /// the box may sleep under the job, and the badge would keep showing it kept awake. Asking again
  /// is what surfaces `stalled` or `running: false` (#380 review). Only while BUSY, so an idle box
  /// is never held awake by the app's own traffic, and at 60 s, which a measured poll at that rate
  /// did not vote BUSY on a box.
  var busyRecheckInterval: Duration = .seconds(60)

  /// Asks the agent again every `busyRecheckInterval` while the last reading is BUSY, until
  /// cancelled with its connection.
  private func recheckWhileBusy() async {
    while !Task.isCancelled {
      try? await Task.sleep(for: busyRecheckInterval)
      guard !Task.isCancelled, status?.busy == true,
        let reading = try? await transport.status(), !Task.isCancelled
      else { continue }
      apply(reading)
    }
  }

  /// The agent's clock on the newest reading this connection has given.
  private var newest: Double?

  /// Takes a reading unless it is older, on the agent's own clock, than the newest this connection
  /// has given: the reply and a change pushed meanwhile can arrive in either order.
  func apply(_ next: AgentWakefulness) {
    if let newest, next.monotonic < newest { return }
    newest = next.monotonic
    if next != status { status = next }
  }

  /// The connection that carried the readings is gone. One that ended on a busy box says nothing
  /// more about it. One that ended on an idle box of a host that sleeps is the agent letting go
  /// (#380), or the box sleeping: either way the host stays idle until something wakes it, so a
  /// background read must not reconnect it (`RemoteHosts.released`).
  func connectionEnded() {
    guard let last = status, last.running, !last.busy else {
      status = nil
      return
    }
    guard hostSleeps else { return }
    RemoteHosts.shared.released(.remote(host))
  }
}

/// The Status service versions this build reads. 2 (#380) dropped the awake ceiling's fields and
/// pushes changes; the fields this build reads are in both.
let agentStatusVersions = 1...2

/// The reply envelope. Shaped like `AgentFileReply`, with the Status service's error kind:
/// `{"unsupported": "message"}`.
struct AgentStatusReply<T: Decodable>: Decodable {
  let result: T
  enum CodingKeys: CodingKey { case version, result, error }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard agentStatusVersions.contains(try values.decode(Int.self, forKey: .version)) else {
      throw HostConnectionError.serviceUnavailable("Unsupported status response version.")
    }
    if values.contains(.error) {
      let failure = try values.decode([String: String].self, forKey: .error)
      guard failure.count == 1, let (kind, message) = failure.first else {
        throw HostConnectionError.serviceUnavailable("Malformed agent failure.")
      }
      throw HostConnectionError.serviceUnavailable("\(kind): \(message)")
    }
    result = try values.decode(T.self, forKey: .result)
  }

  static func decode(_ data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    do {
      return try decoder.decode(Self.self, from: data).result
    } catch let error as DecodingError {
      throw HostConnectionError.serviceUnavailable("Invalid status response: \(error)")
    }
  }
}

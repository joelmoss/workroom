#if DEBUG
  import Defaults
  import Foundation
  import os

  /// Debug builds only: how a remote workroom's agent reaches this Mac's development Codaset.
  ///
  /// A Debug build talks only to a Codaset on this Mac (`BrokerEndpoint`), and the Mac's own URL,
  /// `https://codaset.localhost`, names the REMOTE host when the agent there resolves it. So the
  /// agent is given `http://127.0.0.1:<port>` instead, a listener on its own box (`ReverseForward`)
  /// that carries every connection back to the development Codaset's Puma on this Mac. Release and
  /// Nightly builds have none of this: their agents reach codaset.dev themselves.
  ///
  /// **The listener lives only as long as the connection to the host** (every forward does), so this
  /// reopens it on each new connection, on the same port: the URL the agent saved at enrolment
  /// (`broker.json`) must keep working after a reattach. And a Dev remote workroom can mint only
  /// while this Mac is attached; the token the agent already holds covers up to an hour.
  @MainActor
  final class BrokerReverseForwards {
    static let shared = BrokerReverseForwards()

    /// How the registry reaches a host's connection, so a test can hand it a real agent without
    /// `HostConnectionManager`: the shape `PortForwardingModel.Transport` set.
    struct Transport {
      var forwarding:
        @Sendable (HostID) async throws -> (HostConnectionManager.Lease, AgentForwardService)
      var updates: @Sendable (HostID) async -> AsyncStream<HostConnectionManager.Snapshot>

      static let live = Transport(
        forwarding: { try await HostConnectionManager.shared.forwarding(host: $0) },
        updates: { await HostConnectionManager.shared.updates(for: $0) })
    }

    /// How long the agent may take to answer a `listen`.
    static let listenTimeout: Duration = .seconds(5)
    /// A bind that lost the race with the old connection's teardown is retried this often, this
    /// many times: the agent notices a departed connection within its 200 ms accept poll.
    static let bindRetries = 10
    static let bindRetryDelay: Duration = .milliseconds(200)

    private let transport: Transport
    /// The Puma port on this Mac each connection is carried to.
    private let target: @Sendable () -> UInt16
    private let log = Logger(subsystem: "com.developwithstyle.workroom", category: "broker")

    private struct Entry {
      let host: HostID
      /// The connection the listener is open on, once it is.
      var lease: HostConnectionManager.Lease?
      var forward: ReverseForward?
      var watch: Task<Void, Never>?
      /// An open in flight, which a second caller waits on rather than opening a second listener.
      var opening: Task<Void, Error>?
    }
    private var entries: [UUID: Entry] = [:]

    init(
      transport: Transport = .live,
      target: @escaping @Sendable () -> UInt16 = { UInt16(clamping: Defaults[.brokerAgentTarget]) }
    ) {
      self.transport = transport
      self.target = target
    }

    /// The agent's port for `workroom`: the same on every connection and every launch, so the URL in
    /// its `broker.json` stays right. Derived from the id rather than stored, since nothing in the
    /// app writes a host descriptor yet (#249). 40000–49999 sits below every ephemeral range, and a
    /// host serves one workroom.
    nonisolated static func port(for workroom: UUID) -> UInt16 {
      let bytes = workroom.uuid
      return 40_000 + (UInt16(bytes.0) << 8 | UInt16(bytes.1)) % 10_000
    }

    /// What the agent is given: plain http to its own loopback, which both it (`acceptable_broker`)
    /// and `BrokerEndpoint` accept. Codaset in development checks the agent's proofs against the
    /// request's own host, which is this one, because the bytes reach Puma unchanged.
    nonisolated static func agentURL(for workroom: UUID) -> URL {
      URL(string: "http://127.0.0.1:\(port(for: workroom))")!
    }

    /// Open the listener for `workroom` on `host`, keep it open on every later connection, and return
    /// the URL to give the agent. Throws when the agent does not listen now.
    func open(workroom: UUID, host: HostID) async throws -> URL {
      if entries[workroom] == nil {
        entries[workroom] = Entry(host: host)
        watch(workroom)
      }
      try await listen(workroom)
      return Self.agentURL(for: workroom)
    }

    /// Stop carrying `workroom`'s connections: its enrolment failed, or the workroom is gone.
    func close(workroom: UUID) {
      guard let entry = entries.removeValue(forKey: workroom) else { return }
      entry.watch?.cancel()
      entry.opening?.cancel()
      entry.forward?.stop()
    }

    /// Whether `workroom`'s listener is open on `lease`, for the tests.
    func isOpen(_ workroom: UUID, on lease: HostConnectionManager.Lease) -> Bool {
      entries[workroom]?.lease == lease && entries[workroom]?.forward != nil
    }

    private func listen(_ workroom: UUID) async throws {
      if let opening = entries[workroom]?.opening {
        try await opening.value
        return
      }
      let opening = Task { try await self.reopen(workroom) }
      entries[workroom]?.opening = opening
      defer { entries[workroom]?.opening = nil }
      try await opening.value
    }

    /// A listener on the host's current connection, unless one is already open there.
    private func reopen(_ workroom: UUID) async throws {
      guard let host = entries[workroom]?.host else { return }
      let (lease, service) = try await transport.forwarding(host)
      guard var entry = entries[workroom] else { return }
      if entry.lease == lease, entry.forward != nil { return }
      entry.forward?.stop()
      entry.forward = nil
      entries[workroom] = entry

      // A bind can lose a race on a reconnect: the agent releases the old connection's port only
      // once it notices that connection ended, which can be just after the new one asks. The
      // port is this workroom's alone, so a bind failure is retried for a moment, not reported.
      var attempt = 0
      var outcome = await listen(service, port: Self.port(for: workroom), workroom, lease)
      while case .failure(let refusal) = outcome, refusal.detail.hasPrefix("bind:"),
        attempt < Self.bindRetries
      {
        attempt += 1
        try await Task.sleep(for: Self.bindRetryDelay)
        outcome = await listen(service, port: Self.port(for: workroom), workroom, lease)
      }
      let forward: ReverseForward
      switch outcome {
      case .success(let listening): forward = listening
      case .failure(let refusal):
        throw BrokerError.agent(
          "The remote agent could not reach this Mac's Codaset: \(refusal.detail)")
      }
      // Closed meanwhile, or another connection took over: this listener is nobody's.
      guard entries[workroom] != nil else {
        forward.stop()
        throw CancellationError()
      }
      entries[workroom]?.lease = lease
      entries[workroom]?.forward = forward
    }

    /// One `listen`, answered or timed out. A refused listener is stopped before it is returned.
    private func listen(
      _ service: AgentForwardService, port: UInt16, _ workroom: UUID,
      _ lease: HostConnectionManager.Lease
    ) async -> Result<ReverseForward, ReverseForward.Refusal> {
      let ready = ListenOutcome()
      let forward = service.reverse(remotePort: port, target: target()) {
        [weak self, log] event in
        switch event {
        case .listening:
          ready.resolve(nil)
        case .failed(let detail):
          log.info("broker reverse forward: \(detail, privacy: .public)")
        case .stopped(let detail):
          ready.resolve(detail)
          Task { @MainActor in self?.lost(workroom, on: lease) }
        }
      }
      forward.start()
      if let refusal = await ready.wait(Self.listenTimeout) {
        forward.stop()
        return .failure(.init(refusal))
      }
      return .success(forward)
    }

    /// The listener ended with its connection. The next connection opens a new one.
    private func lost(_ workroom: UUID, on lease: HostConnectionManager.Lease) {
      guard entries[workroom]?.lease == lease else { return }
      entries[workroom]?.lease = nil
      entries[workroom]?.forward = nil
    }

    /// Reopen on every new connection to the host.
    private func watch(_ workroom: UUID) {
      guard let host = entries[workroom]?.host else { return }
      entries[workroom]?.watch = Task { [weak self, transport] in
        for await snapshot in await transport.updates(host) {
          guard let self, !Task.isCancelled else { return }
          guard snapshot.status == .connected, let lease = snapshot.lease,
            self.entries[workroom]?.lease != lease
          else { continue }
          do {
            try await self.listen(workroom)
          } catch {
            self.log.error(
              "broker reverse forward did not reopen: \(error.localizedDescription, privacy: .public)"
            )
          }
        }
      }
    }
  }

  /// The first answer to a `listen`, waited on with a deadline: nil once the agent listens, the
  /// reason when it will not.
  private final class ListenOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: String??
    private var waiter: CheckedContinuation<String?, Never>?

    func resolve(_ refusal: String?) {
      let waiter: CheckedContinuation<String?, Never>? = lock.withLock {
        guard outcome == nil else { return nil }
        outcome = .some(refusal)
        defer { self.waiter = nil }
        return self.waiter
      }
      waiter?.resume(returning: refusal)
    }

    func wait(_ timeout: Duration) async -> String? {
      let timer = Task { [weak self] in
        try? await Task.sleep(for: timeout)
        self?.resolve("the agent did not answer the listen request")
      }
      defer { timer.cancel() }
      return await withCheckedContinuation { continuation in
        let settled: String?? = lock.withLock {
          if let outcome { return outcome }
          waiter = continuation
          return nil
        }
        if let settled { continuation.resume(returning: settled) }
      }
    }
  }
#endif

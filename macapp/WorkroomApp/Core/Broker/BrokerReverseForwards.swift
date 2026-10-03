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
  ///
  /// **Accepted exposure (owner's decision, 2026-10-01).** Every process on the remote host can
  /// connect to the listener, and what it reaches is the development Codaset's Puma, which sees the
  /// connection as coming from 127.0.0.1. Development Rails trusts loopback: full error pages, and
  /// web-console's REPL (it permits `127.0.0.0/8`), so a process on the remote host can run Ruby on
  /// this Mac while the host is attached. Debug builds only; Release and Nightly contain none of
  /// this. If remote hosts ever run untrusted code, filter the relay to `POST /broker/…` and give
  /// Rails a non-loopback `X-Forwarded-For` before using it there.
  @MainActor
  final class BrokerReverseForwards {
    static let shared = BrokerReverseForwards()

    typealias Transport = ReverseForwardRegistry.Transport
    private let registry: ReverseForwardRegistry

    init(
      transport: Transport = .live,
      target: @escaping @Sendable () async -> UInt16 = { await DevelopmentCodaset.port() },
      reopenRetry: Duration = .seconds(5)
    ) {
      registry = ReverseForwardRegistry(
        transport: transport, port: Self.port(for:), target: target,
        failure: {
          BrokerError.agent("The remote agent could not reach this Mac's Codaset: \($0)")
        },
        reopenRetry: reopenRetry)
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
      try await registry.open(workroom: workroom, host: host)
      return Self.agentURL(for: workroom)
    }

    /// Stop carrying `workroom`'s connections: its enrolment failed, or the workroom is gone.
    func close(workroom: UUID) { registry.close(workroom: workroom) }

    /// Whether `workroom`'s listener is open on `lease`, for the tests.
    func isOpen(_ workroom: UUID, on lease: HostConnectionManager.Lease) -> Bool {
      registry.isOpen(workroom, on: lease)
    }
  }

  /// Where the development Codaset's Puma listens on this Mac (#253). `bin/dev` serves it through
  /// Caddy (`rails_caddy_dev`), which gives Puma a free port each start and routes the broker's host
  /// (`codaset.localhost`) to it, so the port is read from Caddy's admin API each time a listener
  /// opens. `Defaults[.brokerAgentTarget]` set to a port wins; with Caddy unreachable or not routing
  /// the host, the port is 3000, Puma's own default.
  enum DevelopmentCodaset {
    static let caddyConfig = URL(string: "http://127.0.0.1:2019/config/apps/http/servers")!

    static func port() async -> UInt16 {
      let configured = Defaults[.brokerAgentTarget]
      if configured > 0 { return UInt16(clamping: configured) }
      let host = BrokerEndpoint.resolve(Defaults[.brokerURL], debug: true).host() ?? ""
      var request = URLRequest(url: caddyConfig, timeoutInterval: 2)
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      guard let (data, _) = try? await URLSession.shared.data(for: request) else { return 3000 }
      return upstreamPort(for: host, inServers: data) ?? 3000
    }

    /// The port of the first upstream of the route matching `host` exactly, in Caddy's
    /// `apps.http.servers` config: `{"srv0": {"routes": [{"match": [{"host": [...]}], "handle":
    /// [... {"upstreams": [{"dial": "localhost:61938"}]} ...]}]}}`.
    static func upstreamPort(for host: String, inServers data: Data) -> UInt16? {
      guard let servers = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return nil
      }
      for case let server as [String: Any] in servers.values {
        for case let route as [String: Any] in server["routes"] as? [Any] ?? [] {
          let hosts = (route["match"] as? [[String: Any]] ?? []).flatMap {
            $0["host"] as? [String] ?? []
          }
          guard hosts.contains(host), let dial = firstDial(in: route) else { continue }
          return dial.split(separator: ":").last.flatMap { UInt16($0) }
        }
      }
      return nil
    }

    private static func firstDial(in node: Any) -> String? {
      if let object = node as? [String: Any] {
        if let upstreams = object["upstreams"] as? [[String: Any]],
          let dial = upstreams.first?["dial"] as? String
        {
          return dial
        }
        for value in object.values { if let dial = firstDial(in: value) { return dial } }
      } else if let array = node as? [Any] {
        for value in array { if let dial = firstDial(in: value) { return dial } }
      }
      return nil
    }
  }
#endif

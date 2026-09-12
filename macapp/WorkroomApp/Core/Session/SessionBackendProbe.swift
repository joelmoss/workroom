import Foundation

/// Asks a backend's helper whether it actually works, rather than whether its file exists.
///
/// `PersistentSessionService.isAvailable` is `socketPath != nil && binaryPath != nil` — a static
/// check. It tells you the binary is on disk; it cannot tell you the binary runs, which is the
/// failure a rollback exists for. A helper that is present but broken (wrong architecture, a
/// missing dylib, a bad codesign after a partial update, a build that simply predates a protocol
/// change) passes `isAvailable` and then fails at the worst moment — with a terminal on screen.
///
/// So the probe executes the helper's cheapest self-describing subcommand and requires a parseable
/// answer. `wr-agent protocol` prints the protocol version it speaks, which is both a liveness
/// check and the compatibility check the versioned handshake needs.
///
/// **This is deliberately not the socket handshake — yet.** Once `wr-agent serve` owns ptys, the
/// stronger probe is to connect, exchange `Hello`, and negotiate, because that also exercises the
/// socket path and permissions. Until `serve` exists there is nothing to connect to, and running
/// the binary is the honest check available today. The result type does not change when it is
/// upgraded.
enum SessionBackendProbe {
  /// Short enough that a hung helper cannot stall app launch or the Settings pane.
  static let timeout: TimeInterval = 2

  static func probe(
    _ backend: SessionBackend,
    binaryURL: URL? = nil,
    run: (URL) throws -> (status: Int32, output: String) = SessionBackendProbe.runProtocolCommand
  ) -> SessionBackendAvailability {
    let resolved = binaryURL ?? PersistentSessionPaths.binaryURL(for: backend)
    guard let resolved else { return .notBundled }

    // The Swift daemon predates any self-describing subcommand, and adding one to a binary being
    // retired is not worth a release. Its presence is the same check the shipped code already
    // trusts, so report it ready and keep the meaningful probe for the thing being introduced.
    guard backend == .rustAgent else { return .ready(version: "bundled") }

    do {
      let (status, output) = try run(resolved)
      guard status == 0 else {
        return .unhealthy(reason: "exited \(status)")
      }
      guard let version = parseProtocolVersion(output) else {
        return .unhealthy(reason: "unrecognised reply")
      }
      return .ready(version: "protocol \(version)")
    } catch {
      return .unhealthy(reason: error.localizedDescription)
    }
  }

  /// Reads the version out of `wr-agent protocol`'s first line ("protocol 1 (minimum supported 1)").
  /// Tolerant of trailing detail by design — the contract is the leading token, so the binary can
  /// add to that line without the app needing a matching release.
  static func parseProtocolVersion(_ output: String) -> Int? {
    for line in output.split(separator: "\n") {
      let parts = line.split(separator: " ")
      guard parts.count >= 2, parts[0] == "protocol", let version = Int(parts[1]) else { continue }
      return version
    }
    return nil
  }

  private static func runProtocolCommand(_ url: URL) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = url
    process.arguments = ["protocol"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()

    // Read before waiting: a helper that fills the pipe buffer would otherwise block forever on
    // write while we block on exit. The output here is two short lines, but the ordering is the
    // kind of thing that only bites once the output grows.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
      usleep(20_000)
    }
    if process.isRunning {
      process.terminate()
      throw ProbeError.timedOut
    }
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  enum ProbeError: LocalizedError, Equatable {
    case timedOut
    var errorDescription: String? {
      switch self {
      case .timedOut: return "no reply within \(Int(SessionBackendProbe.timeout))s"
      }
    }
  }
}

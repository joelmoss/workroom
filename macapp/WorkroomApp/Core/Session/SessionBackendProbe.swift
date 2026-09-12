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

  /// `locate` is injected rather than defaulted-to-nil because `nil` cannot mean both "use the
  /// normal lookup" and "there is no binary". It did, and once `wr-agent` was actually bundled the
  /// two readings diverged: a test asking for the not-bundled case silently got the real binary
  /// and executed it.
  static func probe(
    _ backend: SessionBackend,
    locate: (SessionBackend) -> URL? = { PersistentSessionPaths.binaryURL(for: $0) },
    run: (URL) throws -> (status: Int32, output: String) = SessionBackendProbe.runProtocolCommand
  ) -> SessionBackendAvailability {
    guard let resolved = locate(backend) else { return .notBundled }

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

    // The deadline has to be armed BEFORE the read, not after it. `readDataToEndOfFile` returns
    // only at EOF — when every writer has closed stdout — so a helper that starts and then hangs
    // with the pipe open blocks here forever and the timeout below is never reached. This runs
    // synchronously on the main actor during terminal creation, so that is a frozen app rather
    // than a fall back to the Swift daemon.
    //
    // A watchdog rather than a read with a timeout: killing the process closes its end of the
    // pipe, which is what makes the blocking read return. Same shape as `ShellEnvironment`'s probe
    // deadline, for the same reason — the work item lives outside the blocking call it bounds.
    let timedOut = Atomic(false)
    let watchdog = DispatchWorkItem {
      guard process.isRunning else { return }
      timedOut.value = true
      process.terminate()
    }
    DispatchQueue.global(qos: .userInitiated).asyncAfter(
      deadline: .now() + timeout, execute: watchdog)

    // Read before waiting: a helper that fills the pipe buffer would otherwise block forever on
    // write while we block on exit. The output here is two short lines, but the ordering is the
    // kind of thing that only bites once the output grows.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()

    if timedOut.value { throw ProbeError.timedOut }
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

/// One value, guarded by a lock. The watchdog sets it from a background queue and the probe reads
/// it back on the calling thread, which is a data race without one.
private final class Atomic<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

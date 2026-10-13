import AgentConnection
import Darwin
import Foundation
import WorkroomSystem
import WorkroomVCS

/// One provider. Three methods, and the only one that is not provisioning is `openStream`
/// (design doc, Phase 3). `create` makes each workroom's host: there is no base to derive from
/// (a derive measured slower than a fresh machine on boxd, 2026-10-10).
///
/// **Every driver must authenticate its peer as strongly as a shell login.** The agent's exec
/// service runs `git` with arbitrary arguments, which is arbitrary code execution, so a stream
/// that reaches an agent is a shell whatever it is called. ssh meets that bar; an SDK exec or a
/// WebSocket driver must show it does before it counts as a driver.
public protocol HostDriver: Sendable {
  /// The supervised agent's socket on this driver's hosts: what the bootstrap installs the agent
  /// beside, and the relay and the attach connect to. A remote provider's is on the host's home
  /// disk, so its binary and screens survive a stop (#259).
  var agentSocket: String { get }
  /// Provisions a workroom's host.
  func create() async throws -> HostID
  /// Takes down a host.
  func destroy(_ host: HostID) async throws
  /// A byte stream to the agent on `host`, for
  /// `AgentVCSConnection.connect(host:stream:)`. Not the first thing to open on a host:
  /// `AgentBootstrap.connect` runs the bootstrap first (#231), which is what puts an agent there.
  /// Spawned as a `.connection`, which `connect` takes over (`HostStream.handOff`).
  func openStream(to host: HostID) async throws -> HostStream
  /// Runs `command`, a line for the host's shell, as a one-off exchange (`HostStream.communicate`)
  /// rather than a connection, for what the agent bootstrap runs before there is an agent to talk
  /// to (#231). For ssh it is the remote command; an SDK driver runs it through the provider's exec
  /// call. The stream must be spawned as an `.exchange`, which `communicate` requires: its stdout
  /// is the stream, its stdin a socket of its own that `communicate` closes for EOF (#305).
  /// `openStream` runs the same carrier with the relay as the command, as a `.connection`.
  func exec(_ command: String, on host: HostID) async throws -> HostStream
}

extension HostDriver {
  /// Runs `check`, a line for `host`'s shell, until it exits 0: up to `tries` times, 400 ms apart,
  /// for a wait on a machine coming up (its name, its identity, its agent). A machine mid-reboot
  /// refuses or holds the connection; neither is the answer, but the last one is what the failure
  /// says. A cancel ends the wait at once (#259: shared by every provider driver).
  public func poll(
    _ host: HostID, _ check: String, tries: Int, failure: (String) -> String
  ) async throws {
    var last = ""
    for _ in 0..<tries {
      do {
        let (status, output) = try await exec(check, on: host).communicate(nil, timeout: 20)
        if status == 0 { return }
        last = output
      } catch is CancellationError {
        throw CancellationError()
      } catch { last = error.localizedDescription }
      try await Task.sleep(for: .milliseconds(400))
    }
    throw HostDriverError.provisioning(failure(last))
  }

  /// Until the identity unit has run on host `id`, a machine named `name`: its marker and its
  /// hostname both name it. A provider's own readiness signal is not one (boxd's Phase 0, item 6),
  /// so the wait asks the machine itself.
  public func awaitIdentity(of id: UUID, named name: String) async throws {
    let quoted = PosixShell.quoted(name)
    try await poll(
      .remote(id),
      "test \"$(cat /etc/workroom-identity 2>/dev/null)\" = \(quoted)"
        + " && test \"$(hostname)\" = \(quoted)",
      tries: 150
    ) { "\(name) never minted its identity: \($0)" }
  }

  /// The container image's socket (`vcs/scripts/ssh-fixture/entrypoint.sh`), for a driver that
  /// doesn't say otherwise.
  public var agentSocket: String { AgentInstall.defaultSocket }
}

/// What a provider driver runs on a new host to set it up.
public enum HostSetup {
  /// `Resources/host-setup/systemd.sh`: the identity unit and the agent's supervisor, for a machine
  /// that runs systemd (boxd, exe.dev).
  public static func systemdScript() throws -> String { try script("systemd") }

  /// `Resources/host-setup/exedev-github.sh`: points an exe.dev VM's git and gh at exe.dev's
  /// GitHub integration.
  public static func exeDevGitHubScript() throws -> String { try script("exedev-github") }

  public static func script(_ name: String) throws -> String {
    guard
      let url = Bundle.main.url(forResource: name, withExtension: "sh", subdirectory: "host-setup")
    else { throw HostDriverError.invalidConfiguration("this build has no host-setup/\(name).sh") }
    return try String(contentsOf: url, encoding: .utf8)
  }
}

/// A driver whose hosts a terminal pane can attach to.
///
/// Not a fifth `HostDriver` method, and not `openStream`: a pane is a process libghostty spawns and
/// wires to its own pty, and a socketpair made in this process cannot become one. So the driver
/// hands over a command instead. For ssh that is `ssh -t <host> wr-agent attach …`, the far side's
/// attach client running in the pty ssh allocates there. An SDK-exec driver has no such command,
/// and would need a local bridge process: a Phase 4 question (design doc, Phase 3).
public protocol HostTerminalDriver: HostDriver {
  /// The command a pane runs to attach to `session` on `host`, starting in `workingDirectory` if
  /// the session is new. `restored` for a pane reattaching after a relaunch or a lost link: the
  /// session must already exist there, and if it has ended the pane gets a shell that says so
  /// rather than a fresh one that looks like it (`wr-agent attach --no-create`).
  ///
  /// `metadata` is what the app says about the session (`SessionMetadataKey`): its workroom and
  /// title travel to the host's agent with the attach, so any Mac can find the session (#255).
  func attachCommand(
    to host: HostID, session: UUID, workingDirectory: String, restored: Bool,
    metadata: [(key: String, value: String)]
  ) throws -> String
  /// Whether the last attach of `session` was refused by `host` in a way that does not heal, for
  /// a pane deciding whether to keep trying: a host that is rebooting comes back, one that
  /// answers with another host key does not (#241).
  func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool
  /// Whether the last attach of `session` ended with ssh's own failure (255), read from what the
  /// attach wrapper recorded: the pane's exit status is `login`'s, always 0 (#392).
  func lastAttachLostLink(of session: UUID, on host: HostID) -> Bool
}

extension HostTerminalDriver {
  /// An attach that says nothing about its session.
  public func attachCommand(
    to host: HostID, session: UUID, workingDirectory: String, restored: Bool
  )
    throws -> String
  {
    try attachCommand(
      to: host, session: session, workingDirectory: workingDirectory, restored: restored,
      metadata: [])
  }
}

public enum HostDriverError: Error, Equatable, Sendable, LocalizedError {
  case unknownHost(HostID)
  /// From a driver that cannot provision, such as a `ContainerHostDriver` given no
  /// `Provisioning`, for `create` and `destroy`; and from `destroy` for a host the driver was
  /// handed rather than made.
  case notImplemented(String)
  case invalidConfiguration(String)
  /// Making or removing a host failed. A failed `create` has removed what it made (or says
  /// otherwise with `leftBehind`); a failed `destroy` leaves the host as it was, still known to
  /// the driver, so it can be tried again.
  case provisioning(String)
  /// A failed `create` could not remove what it had made: each of `leftover`
  /// is still there, named by what the driver called it. `host`, when the driver can name it, is
  /// the host it made, so the caller can record it for a later delete to take down (#356).
  case leftBehind(cause: String, leftover: [String], host: HostID? = nil)

  public var errorDescription: String? {
    switch self {
    case .unknownHost: return "This driver has no such host."
    case .notImplemented(let what): return "\(what) is not implemented yet."
    case .invalidConfiguration(let detail): return "Invalid host configuration: \(detail)"
    case .provisioning(let detail): return "Couldn't provision the host: \(detail)"
    case .leftBehind(let cause, let leftover, _):
      return
        "Couldn't provision the host: \(cause) Still there: \(leftover.joined(separator: "; "))"
    }
  }
}

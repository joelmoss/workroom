import Foundation

/// The first `HostDriver`: a Linux container running sshd and a supervised `wr-agent`
/// (`vcs/scripts/ssh-fixture`, #228), reached over plain ssh-stdio. It is the test fixture for
/// the remote path, and its `openStream` is the ssh transport a real ssh-reachable driver (boxd)
/// will share.
///
/// Provisioning is Phase 4, so `create`, `deriveFromBase` and `destroy` say so rather than pretend.
/// Which hosts exist is whatever the caller hands in; nothing here persists.
struct ContainerHostDriver: HostTerminalDriver {
  struct Host: Sendable {
    let address: String
    let port: Int
    let user: String
    /// The private key ssh authenticates with. The only credential used: `IdentitiesOnly` and
    /// `IdentityAgent none` keep the Mac's ssh agent and default keys out of it.
    let identityFile: String
    /// The host's public key, `<type> <base64>`, delivered out of band. It is the only key ssh
    /// accepts, and a mismatch fails closed: `BatchMode` cannot prompt to accept a new one.
    let hostKey: String
    /// The supervised agent's socket on the host.
    let agentSocket: String

    /// The agent's binary, beside its socket: what the app installs there (`AgentBootstrap`,
    /// #231), the supervisor starts, and the relay and the attach run. One directory per host,
    /// the socket's 0700 one, so the file has the socket's protection (design doc, the hand-off
    /// trust model: the socket is the boundary).
    var agentBinary: String { AgentBootstrap.binary(besideSocket: agentSocket) }
  }

  let traits = HostDriverTraits(
    transport: .sshStdio, deriveSpeed: nil, deriveCarriesLiveProcesses: false,
    durableDisk: false, maxLifetime: nil)

  let hosts: [UUID: Host]
  /// Where each host's `ssh_config` and `known_hosts` are written.
  let directory: URL

  func create() async throws -> HostID { throw HostDriverError.notImplemented("Creating a base") }

  func deriveFromBase(_ base: HostID) async throws -> HostID {
    throw HostDriverError.notImplemented("Deriving a workroom instance")
  }

  func destroy(_ host: HostID) async throws {
    throw HostDriverError.notImplemented("Destroying a host")
  }

  func openStream(to host: HostID) async throws -> HostStream {
    guard case .remote(let id) = host, let target = hosts[id] else {
      throw HostDriverError.unknownHost(host)
    }
    return try await exec(
      Self.relayCommand(binary: target.agentBinary, socket: target.agentSocket), on: host)
  }

  func exec(_ command: String, on host: HostID) async throws -> HostStream {
    guard case .remote(let id) = host, let target = hosts[id] else {
      throw HostDriverError.unknownHost(host)
    }
    let config = try Self.writeConfiguration(
      for: target, in: directory.appendingPathComponent(id.uuidString))
    return try HostStream.spawn(
      URL(fileURLWithPath: "/usr/bin/ssh"),
      ["-F", config.path, Self.alias, command],
      // Nothing from the app's own environment: ssh needs none of it with this configuration, and
      // `SSH_AUTH_SOCK` in particular is a Mac credential. `-F` also keeps `/etc/ssh/ssh_config`
      // out, whose `SendEnv LANG LC_*` would send the Mac's locale across.
      environment: [:],
      // ssh connects and authenticates before the agent can greet. `ConnectTimeout` bounds the
      // connect; this leaves room for the rest.
      handshakeTimeout: 20)
  }

  func attachCommand(
    to host: HostID, session: UUID, workingDirectory: String, restored: Bool
  ) throws -> String {
    guard case .remote(let id) = host, let target = hosts[id] else {
      throw HostDriverError.unknownHost(host)
    }
    let hostDirectory = directory.appendingPathComponent(id.uuidString)
    let config = try Self.writeConfiguration(for: target, in: hostDirectory)
    // `-t`: the attach client on the far side wants a terminal, for raw mode and the pane's size,
    // and ssh forwards the pane's resizes to it. It outranks the config's `RequestTTY no`, which
    // is right for the service stream.
    let log = Self.attachLog(session, in: hostDirectory).path
    let ssh = [
      "/usr/bin/ssh", "-F", config.path, "-E", log, "-o", "PermitLocalCommand=yes", "-o",
      "LocalCommand=printf '\\0338\\033[J'", "-t", Self.alias,
      Self.remoteAttachCommand(
        binary: target.agentBinary, session: session, socket: target.agentSocket,
        workingDirectory: workingDirectory, restored: restored),
    ]
    return (["/bin/sh", "-c", Self.attachWrapper, "workroom-attach", log] + ssh)
      .map(Self.shellQuoted).joined(separator: " ")
  }

  /// What a pane runs around its ssh (#241), as `sh -c <this> workroom-attach <log> <ssh argv>`.
  ///
  /// ssh's own messages go to the session's log (`-E`), so the app can read why the last attach
  /// failed (`hostRefusedLastAttach`) rather than guess from the status, which is 255 for all of
  /// them. A failure's message is then copied onto the screen, where ssh would have printed it.
  /// Until ssh is in, the pane says what it is waiting for; `LocalCommand`, which ssh runs once it
  /// has authenticated and before the session starts, restores the cursor saved ahead of that line
  /// and erases from there (DECSC, DECRC, ED), so an attach that goes through shows only the
  /// session, however many rows the line wrapped onto. `SHELL` is what ssh runs `LocalCommand`
  /// with, so it is a POSIX one.
  static let attachWrapper = """
    log=$1; shift; printf '\\0337%s' "workroom: waiting for this terminal's host..."; \
    : > "$log"; \
    SHELL=/bin/sh "$@"; status=$?; \
    if [ -s "$log" ]; then printf '\\r\\n'; cat "$log" >&2; fi; exit "$status"
    """

  /// Where a pane's ssh writes its messages (`-E`): one file per session, emptied by each attach.
  static func attachLog(_ session: UUID, in hostDirectory: URL) -> URL {
    hostDirectory.appendingPathComponent("attach-\(session.uuidString).log")
  }

  /// Whether the last attach of `session` was refused by `host` in a way that does not heal: a
  /// changed host key, a key it will not take, nothing to agree a cipher on (#241). Everything
  /// else is worth trying again: a host that is booting refuses, times out, or accepts and closes
  /// before its banner, and some of those leave ssh nothing to say at `LogLevel ERROR`.
  func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool {
    guard case .remote(let id) = host else { return false }
    let log = Self.attachLog(session, in: directory.appendingPathComponent(id.uuidString))
    return Self.isRefusal((try? String(contentsOf: log, encoding: .utf8)) ?? "")
  }

  /// ssh's messages for a host that answered and will keep saying no. Listed rather than the
  /// failures that heal, because those are open-ended: a gateway in front of a rebooting VM, or a
  /// socket-activated sshd, can fail in words no list has seen. An authentication denial is
  /// `Permission denied (<methods>)`; a bare `Permission denied` is a connect a firewall refused,
  /// which can heal.
  static func isRefusal(_ log: String) -> Bool {
    let log = log.lowercased()
    return [
      "host key verification failed", "remote host identification has changed",
      "permission denied (", "too many authentication failures", "unable to negotiate",
      "load key", "bad owner or permissions",
    ].contains { log.contains($0) }
  }

  /// What runs on the host, in the pty ssh allocates there.
  ///
  /// The session contract is the environment `wr-agent attach` reads, set with `env` because ssh
  /// carries none of the pane's own. Deliberately absent: the shell (the host's own login shell
  /// applies), Ghostty's resources directory (a path in this Mac's app bundle), and the wakefulness
  /// settings (they configure an agent the attach starts, and `--no-spawn` never starts one).
  /// `TERM` is `xterm-256color`, not the pane's `xterm-ghostty`, which a host rarely has terminfo
  /// for; pushing that terminfo, and the shell integration, is a follow-up to the bootstrap
  /// (#231, which pushes only the agent; #239).
  ///
  /// A host with no agent installed yet (rebooted from tmpfs, or never bootstrapped) has no
  /// binary to run, and the shell's 127 for that would read as the session's own exit. It exits
  /// 255 instead, ssh's own status for a lost link, which the app answers by attaching again with
  /// backoff: by then the bootstrap, which nothing orders panes after, has installed it.
  static func remoteAttachCommand(
    binary: String, session: UUID, socket: String, workingDirectory: String, restored: Bool
  ) -> String {
    let variables = [
      "TERM=xterm-256color",
      "WORKROOM_SESSION_ID=\(session.uuidString)",
      "WORKROOM_SESSION_SOCKET=\(socket)",
      "WORKROOM_SESSION_CWD=\(workingDirectory)",
    ]
    return "test -x \(shellQuoted(binary)) || { echo "
      + shellQuoted("workroom: no agent is installed at \(binary) yet") + " >&2; exit 255; }; "
      + (["env"] + variables + [binary, "attach", "--no-spawn"]
      + (restored ? ["--no-create"] : []))
      .map(shellQuoted).joined(separator: " ")
  }

  static let alias = "workroom-host"

  /// The command ssh runs on the host, quoted for the remote shell. The installed binary by its
  /// path: a host has no `wr-agent` on its PATH, only what the bootstrap put beside the socket.
  static func relayCommand(binary: String, socket: String) -> String {
    shellQuoted(binary) + " relay --socket " + shellQuoted(socket)
  }

  /// Writes the host's `ssh_config` and `known_hosts`, and returns the config's path.
  ///
  /// The whole policy is here, so nothing in `~/.ssh/config` can change it:
  /// - **It cannot prompt.** `BatchMode` turns a password, passphrase or unknown-host prompt into a
  ///   failure, and `StrictHostKeyChecking` with only the pinned key known makes any other key one
  ///   of those failures. `HostKeyAlgorithms` is deliberately not pinned to the key's type: it
  ///   names signature algorithms, so for an RSA key it would pin SHA-1 `ssh-rsa`, which OpenSSH
  ///   8.8+ servers no longer offer.
  /// - **No Mac credential crosses.** No agent forwarding, no X11, no port forwards, and the Mac's
  ///   ssh agent is not consulted for keys.
  /// - **What a pane types is only ever the user's.** A pane's ssh has a terminal, and ssh reads
  ///   `~.` and friends from one as its own commands (`~.` disconnects, `~^Z` suspends ssh and
  ///   freezes the pane), so `EscapeChar none`.
  /// - **A dead link is noticed.** `ServerAliveInterval` ends ssh after about 45s of silence from a
  ///   host that stopped answering, which ends the stream and so the connection. It is what bounds
  ///   a link that dies with nothing to send (#228).
  static func writeConfiguration(for host: Host, in directory: URL) throws -> URL {
    for (name, value) in [
      ("address", host.address), ("user", host.user), ("identity file", host.identityFile),
      ("host key", host.hostKey), ("agent socket", host.agentSocket),
    ] {
      guard !value.isEmpty, !value.contains(where: { $0.isNewline || $0 == "\"" || $0 == "\0" })
      else {
        throw HostDriverError.invalidConfiguration("\(name) is empty or has a quote or newline")
      }
    }
    guard (1...65535).contains(host.port) else {
      throw HostDriverError.invalidConfiguration("port \(host.port) is out of range")
    }
    // The agent's binary is derived from it (`agentBinary`), and run by path from any cwd.
    guard host.agentSocket.hasPrefix("/") else {
      throw HostDriverError.invalidConfiguration("agent socket must be an absolute path")
    }
    let key = host.hostKey.split(separator: " ")
    guard key.count >= 2 else {
      throw HostDriverError.invalidConfiguration("host key must be `<type> <base64>`")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let knownHosts = directory.appendingPathComponent("known_hosts")
    let name = host.port == 22 ? host.address : "[\(host.address)]:\(host.port)"
    try "\(name) \(key[0]) \(key[1])\n".write(to: knownHosts, atomically: true, encoding: .utf8)
    let config = directory.appendingPathComponent("ssh_config")
    try """
    Host \(alias)
      HostName "\(host.address)"
      Port \(host.port)
      User "\(host.user)"
      IdentityFile "\(host.identityFile)"
      IdentitiesOnly yes
      IdentityAgent none
      BatchMode yes
      StrictHostKeyChecking yes
      UserKnownHostsFile "\(knownHosts.path)"
      GlobalKnownHostsFile /dev/null
      UpdateHostKeys no
      ForwardAgent no
      ForwardX11 no
      ClearAllForwardings yes
      ControlMaster no
      ControlPath none
      EscapeChar none
      RequestTTY no
      ServerAliveInterval 15
      ServerAliveCountMax 3
      ConnectTimeout 10
      LogLevel ERROR

    """.write(to: config, atomically: true, encoding: .utf8)
    return config
  }

  /// One POSIX shell word, whatever `text` holds.
  static func shellQuoted(_ text: String) -> String { PosixShell.quoted(text) }
}

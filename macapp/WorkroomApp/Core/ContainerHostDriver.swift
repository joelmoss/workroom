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
    let config = try Self.writeConfiguration(for: target, in: directory.appendingPathComponent(id.uuidString))
    return try HostStream.spawn(
      URL(fileURLWithPath: "/usr/bin/ssh"),
      ["-F", config.path, Self.alias, Self.relayCommand(socket: target.agentSocket)],
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
    let config = try Self.writeConfiguration(
      for: target, in: directory.appendingPathComponent(id.uuidString))
    // `-t`: the attach client on the far side wants a terminal, for raw mode and the pane's size,
    // and ssh forwards the pane's resizes to it. It outranks the config's `RequestTTY no`, which
    // is right for the service stream.
    return ["/usr/bin/ssh", "-F", config.path, "-t", Self.alias]
      .map(Self.shellQuoted).joined(separator: " ")
      + " "
      + Self.shellQuoted(
        Self.remoteAttachCommand(
          session: session, socket: target.agentSocket, workingDirectory: workingDirectory,
          restored: restored))
  }

  /// What runs on the host, in the pty ssh allocates there.
  ///
  /// The session contract is the environment `wr-agent attach` reads, set with `env` because ssh
  /// carries none of the pane's own. Deliberately absent: the shell (the host's own login shell
  /// applies), Ghostty's resources directory (a path in this Mac's app bundle), and the wakefulness
  /// settings (they configure an agent the attach starts, and `--no-spawn` never starts one).
  /// `TERM` is `xterm-256color`, not the pane's `xterm-ghostty`, which a host rarely has terminfo
  /// for; shipping that terminfo belongs to the agent bootstrap (#231).
  static func remoteAttachCommand(
    session: UUID, socket: String, workingDirectory: String, restored: Bool
  ) -> String {
    let variables = [
      "TERM=xterm-256color",
      "WORKROOM_SESSION_ID=\(session.uuidString)",
      "WORKROOM_SESSION_SOCKET=\(socket)",
      "WORKROOM_SESSION_CWD=\(workingDirectory)",
    ]
    return (["env"] + variables + ["wr-agent", "attach", "--no-spawn"]
      + (restored ? ["--no-create"] : []))
      .map(shellQuoted).joined(separator: " ")
  }

  static let alias = "workroom-host"

  /// The command ssh runs on the host, quoted for the remote shell.
  static func relayCommand(socket: String) -> String {
    "wr-agent relay --socket " + shellQuoted(socket)
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
  static func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

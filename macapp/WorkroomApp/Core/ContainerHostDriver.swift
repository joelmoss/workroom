import Foundation

/// The first `HostDriver`: a Linux container running sshd and a supervised `wr-agent`
/// (`vcs/scripts/ssh-fixture`, #228), reached over plain ssh-stdio. It is the test fixture for
/// the remote path, and its `openStream` is the ssh transport a real ssh-reachable driver (boxd)
/// will share.
///
/// Its hosts are the ones the caller hands in, plus, given `Provisioning`, the containers it makes
/// itself (#252): `create` runs a base from the fixture's image, `deriveFromBase` snapshots a base
/// (`commit`) and runs a container from that, and `destroy` removes either. Nothing here persists.
final class ContainerHostDriver: HostTerminalDriver, @unchecked Sendable {
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
    /// Ghostty's terminfo and shell integration, which the bootstrap puts beside the agent (#239).
    var resources: String { AgentBootstrap.resources(besideSocket: agentSocket) }
  }

  /// How the driver makes containers of its own: a container runtime's CLI (`docker`), the
  /// fixture's image, and the client key every container authorises. Containers are reached on a
  /// loopback port the runtime publishes, as `vcs/scripts/ssh-fixture/run.sh` reaches its own.
  struct Provisioning: Sendable {
    let runtime: URL
    let image: String
    let user: String
    let identityFile: String
    /// The public half of `identityFile`, which the entrypoint writes to `authorized_keys`.
    let publicKey: String
    let agentSocket: String
    /// `key=value` labels on every container and image made, so whoever started the fixture can
    /// sweep up what a crashed test left (run.sh does).
    let labels: [String]
  }

  /// A host this driver made: its container, and for a derived one the image it was run from,
  /// which only it uses.
  private struct Provisioned {
    let container: String
    let image: String?
  }

  /// A derive is a snapshot of the disk only: a commit keeps no process, and the container run
  /// from it boots afresh.
  var traits: HostDriverTraits {
    HostDriverTraits(
      transport: .sshStdio, deriveSpeed: provisioning == nil ? nil : .seconds(5),
      deriveCarriesLiveProcesses: false, durableDisk: false, maxLifetime: nil)
  }

  /// Where each host's `ssh_config` and `known_hosts` are written.
  let directory: URL
  let provisioning: Provisioning?
  private let lock = NSLock()
  private var hosts: [UUID: Host]
  private var provisioned: [UUID: Provisioned] = [:]
  /// Hosts this driver has destroyed, so destroying one again succeeds: a caller retrying after a
  /// later step of its own failed (forgetting its record) gets past the destroy it already did.
  private var destroyed: Set<UUID> = []

  init(hosts: [UUID: Host], directory: URL, provisioning: Provisioning? = nil) {
    self.hosts = hosts
    self.directory = directory
    self.provisioning = provisioning
  }

  private func target(_ host: HostID) throws -> (UUID, Host) {
    guard case .remote(let id) = host, let target = lock.withLock({ hosts[id] }) else {
      throw HostDriverError.unknownHost(host)
    }
    return (id, target)
  }

  func create() async throws -> HostID {
    guard let provisioning else { throw HostDriverError.notImplemented("Creating a base") }
    return try await run(provisioning.image, image: nil)
  }

  /// A snapshot of `base`'s disk, run as a container of its own. The base keeps running: `commit`
  /// pauses it only while it copies. The new container mints its own identity at its first boot
  /// (`entrypoint.sh`), before sshd or the agent starts, so it serves nothing as its base; its
  /// host key is read once that is done and pinned here.
  func deriveFromBase(_ base: HostID) async throws -> HostID {
    guard let provisioning else {
      throw HostDriverError.notImplemented("Deriving a workroom instance")
    }
    guard case .remote(let id) = base, let source = lock.withLock({ provisioned[id] }) else {
      throw HostDriverError.unknownHost(base)
    }
    // An instance has enrolled, and its key and credential helper are on its disk: a copy of it
    // would start with them.
    guard source.image == nil else {
      throw HostDriverError.invalidConfiguration("a workroom instance cannot be derived from")
    }
    // Labelled with an ID chosen here, because the runtime's own is known only from its output:
    // a commit that outlives its CLI (killed by the silence bound, or a cancelled derive) leaves
    // an image nothing would otherwise find.
    let commit = "workroom.commit=\(UUID().uuidString.lowercased())"
    do {
      let image = try await runtime(
        ["commit"] + (provisioning.labels + [commit]).flatMap { ["--change", "LABEL \($0)"] }
          + [source.container],
        // `commit` prints nothing until it is done, and copying a base's disk takes a while.
        timeout: 900)
      return try await run(image, image: image)
    } catch {
      let removals = await Task { () -> [String] in
        do {
          var failed: [String] = []
          for image in try await self.runtime(
            ["images", "-aq", "--filter", "label=\(commit)"], allLines: true
          ).split(separator: "\n") {
            do { _ = try await self.runtime(["rmi", "--force", String(image)]) } catch {
              failed.append("image \(image): \(error.localizedDescription)")
            }
          }
          return failed
        } catch { return ["images labelled \(commit): \(error.localizedDescription)"] }
      }.value
      // A run that could not remove its container says so; its image goes on that list too.
      var (cause, leftover) = (error.localizedDescription, removals)
      if case HostDriverError.leftBehind(let inner, let left) = error {
        (cause, leftover) = (inner, left + removals)
      }
      guard !leftover.isEmpty else { throw error }
      throw HostDriverError.leftBehind(cause: cause, leftover: leftover)
    }
  }

  /// Removes the container and the image it alone was run from. A host handed in rather than
  /// made here is not this driver's to remove.
  func destroy(_ host: HostID) async throws {
    if case .remote(let id) = host, lock.withLock({ destroyed.contains(id) }) { return }
    guard case .remote(let id) = host, let made = lock.withLock({ provisioned[id] }) else {
      if case .remote(let id) = host, lock.withLock({ hosts[id] }) != nil {
        throw HostDriverError.notImplemented("Destroying a host this driver did not make")
      }
      throw HostDriverError.unknownHost(host)
    }
    _ = try await runtime(["rm", "--force", "--volumes", made.container])
    if let image = made.image { _ = try await runtime(["rmi", "--force", image]) }
    lock.withLock {
      hosts[id] = nil
      provisioned[id] = nil
      destroyed.insert(id)
    }
    try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString))
  }

  /// Runs a container from `source` and waits until it can be reached: its identity minted, its
  /// host key pinned, and an ssh login through this driver's own configuration answering. A
  /// container that gets no further is removed.
  private func run(_ source: String, image: String?) async throws -> HostID {
    guard let provisioning else { throw HostDriverError.notImplemented("Provisioning") }
    // A port of its own rather than an ephemeral one (`127.0.0.1::22`): a restart keeps it, so the
    // host's address outlives a reboot, as a provider's box keeps its address.
    // ponytail: the port is free when chosen, not when the runtime binds it; a run that loses
    // that race fails and is rolled back like any other.
    guard let (probe, port) = LoopbackSocket.listen(backlog: 1) else {
      throw HostDriverError.provisioning("no free loopback port: errno \(errno)")
    }
    Darwin.close(probe)
    let id = UUID()
    // Named here, not by the runtime's own ID, which is known only from its output: a run that
    // outlives its CLI still leaves a container this name removes.
    let container = "workroom-\(id.uuidString.lowercased())"
    do {
      _ = try await runtime(
        ["run", "--detach", "--init", "--name", container, "--publish", "127.0.0.1:\(port):22"]
          + provisioning.labels.flatMap { ["--label", $0] }
          + ["--env", "AUTHORIZED_KEY=\(provisioning.publicKey)", source])
      let hostKey = try await identity(of: container)
      lock.withLock {
        hosts[id] = Host(
          address: "127.0.0.1", port: Int(port), user: provisioning.user,
          identityFile: provisioning.identityFile, hostKey: hostKey,
          agentSocket: provisioning.agentSocket)
        provisioned[id] = Provisioned(container: container, image: image)
      }
      try await awaitLogin(.remote(id))
      return .remote(id)
    } catch {
      lock.withLock {
        hosts[id] = nil
        provisioned[id] = nil
      }
      let removal = await Task { () -> String? in
        do {
          _ = try await self.runtime(["rm", "--force", "--volumes", container])
          return nil
        } catch { return "container \(container): \(error.localizedDescription)" }
      }.value
      // The login wait wrote the host's ssh_config and pinned key here.
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString))
      guard let removal else { throw error }
      throw HostDriverError.leftBehind(cause: error.localizedDescription, leftover: [removal])
    }
  }

  /// The container's ssh host key, read through the runtime once its entrypoint has minted it
  /// (the image's `identity.sh`, which run.sh reads it through too): delivered out of band, as
  /// every driver's must be (design doc, host-key policy).
  private func identity(of container: String) async throws -> String {
    for _ in 0..<100 {
      if let key = try? await runtime(["exec", container, "identity.sh"]),
        key.split(separator: " ").count == 2
      {
        return key
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    throw HostDriverError.provisioning("\(container) never minted its identity")
  }

  /// sshd starts a moment after the identity is minted, so the first login can be refused.
  private func awaitLogin(_ host: HostID) async throws {
    var last = ""
    for _ in 0..<50 {
      let (status, output) = try await exec("true", on: host).communicate(nil, timeout: 20)
      if status == 0 { return }
      last = output
      try await Task.sleep(for: .milliseconds(200))
    }
    throw HostDriverError.provisioning("ssh never let us in: \(last)")
  }

  /// One runtime command; its first line of output, which is all most of these print on success,
  /// or with `allLines` all of it. Its environment is the few variables that say which daemon to
  /// talk to, never the app's whole one.
  private func runtime(
    _ arguments: [String], timeout: TimeInterval = 120, allLines: Bool = false
  ) async throws -> String {
    guard let provisioning else { throw HostDriverError.notImplemented("Provisioning") }
    let environment = ProcessInfo.processInfo.environment.filter {
      ["HOME", "PATH", "DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG"].contains($0.key)
    }
    let (status, output) = try await HostStream.spawn(
      provisioning.runtime, arguments, environment: environment, handshakeTimeout: 20
    ).communicate(nil, timeout: timeout)
    let said = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard status == 0 else {
      throw HostDriverError.provisioning(
        "\(provisioning.runtime.lastPathComponent) \(arguments[0]) exited \(status): \(said)")
    }
    return allLines ? said : said.split(separator: "\n").first.map(String.init) ?? ""
  }

  func openStream(to host: HostID) async throws -> HostStream {
    let (_, target) = try target(host)
    return try await exec(
      Self.relayCommand(binary: target.agentBinary, socket: target.agentSocket), on: host)
  }

  func exec(_ command: String, on host: HostID) async throws -> HostStream {
    let (id, target) = try target(host)
    return try Self.exec(command, on: target, in: directory.appendingPathComponent(id.uuidString))
  }

  func attachCommand(
    to host: HostID, session: UUID, workingDirectory: String, restored: Bool
  ) throws -> String {
    let (id, target) = try target(host)
    return try Self.attachCommand(
      to: target, in: directory.appendingPathComponent(id.uuidString), session: session,
      workingDirectory: workingDirectory, restored: restored)
  }

  /// Whether the last attach of `session` was refused by `host` in a way that does not heal: a
  /// changed host key, a key it will not take, nothing to agree a cipher on (#241). Everything
  /// else is worth trying again: a host that is booting refuses, times out, or accepts and closes
  /// before its banner, and some of those leave ssh nothing to say at `LogLevel ERROR`.
  func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool {
    guard case .remote(let id) = host else { return false }
    return Self.refusedLastAttach(of: session, in: directory.appendingPathComponent(id.uuidString))
  }

  // MARK: The ssh transport, which any ssh-reachable driver shares (boxd's, #256)

  /// Runs `command` on `host` over ssh, with the host's `ssh_config` and `known_hosts` written to
  /// `hostDirectory` first.
  static func exec(_ command: String, on host: Host, in hostDirectory: URL) throws -> HostStream {
    let config = try writeConfiguration(for: host, in: hostDirectory)
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

  /// The command a pane runs to attach to `session` on `host` over ssh, with the host's
  /// configuration written to `hostDirectory`.
  static func attachCommand(
    to host: Host, in hostDirectory: URL, session: UUID, workingDirectory: String, restored: Bool
  ) throws -> String {
    let config = try writeConfiguration(for: host, in: hostDirectory)
    // `-t`: the attach client on the far side wants a terminal, for raw mode and the pane's size,
    // and ssh forwards the pane's resizes to it. It outranks the config's `RequestTTY no`, which
    // is right for the service stream.
    let log = attachLog(session, in: hostDirectory).path
    let ssh = [
      "/usr/bin/ssh", "-F", config.path, "-E", log, "-o", "PermitLocalCommand=yes", "-o",
      "LocalCommand=printf '\\0338\\033[J'", "-t", alias,
      remoteAttachCommand(
        binary: host.agentBinary, session: session, socket: host.agentSocket,
        resources: host.resources, workingDirectory: workingDirectory, restored: restored),
    ]
    return (["/bin/sh", "-c", attachWrapper, "workroom-attach", log] + ssh)
      .map(shellQuoted).joined(separator: " ")
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

  /// Whether the last attach of `session`, whose log is in `hostDirectory`, was refused.
  static func refusedLastAttach(of session: UUID, in hostDirectory: URL) -> Bool {
    isRefusal(
      (try? String(contentsOf: attachLog(session, in: hostDirectory), encoding: .utf8)) ?? "")
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
  /// applies) and the wakefulness settings (they configure an agent the attach starts, and
  /// `--no-spawn` never starts one).
  ///
  /// The terminal is the pane's own `xterm-ghostty`, with Ghostty's shell integration, when the
  /// bootstrap has put its terminfo and integration at `resources` (#239), and `xterm-256color`
  /// without the integration when it has not: a host rarely has `xterm-ghostty` terminfo of its
  /// own, and a `TERM` the host cannot look up is worse than a plainer one. The fallback also
  /// drops any integration variables the host's own login environment set, and keeps its
  /// `TERMINFO`, which is the user's. Decided on the host as
  /// the attach starts, since the set may be gone (a reboot empties a tmpfs `/run`) or not there
  /// yet. The integration's features are Ghostty's defaults less `path`, which needs the `ghostty`
  /// binary on the host, plus `sudo`: `sudo` keeps `TERM` and drops `TERMINFO`, so without the
  /// integration's wrapper (`sudo --preserve-env=TERMINFO`) a `sudo vim` on the host could not
  /// look up `xterm-ghostty`. It covers `sudo` to root; `sudo -u` another user cannot read the
  /// set in the ssh user's 0700 directory, and `su -` is not wrapped. The title then follows the
  /// shell; the pane's working directory does not, because libghostty takes an OSC 7 report only
  /// from its own host.
  ///
  /// A host with no agent installed yet (rebooted from tmpfs, or never bootstrapped) has no
  /// binary to run, and the shell's 127 for that would read as the session's own exit. It exits
  /// 255 instead, ssh's own status for a lost link, which the app answers by attaching again with
  /// backoff: by then the bootstrap, which nothing orders panes after, has installed it.
  static func remoteAttachCommand(
    binary: String, session: UUID, socket: String, resources: String, workingDirectory: String,
    restored: Bool
  ) -> String {
    let integrated = [
      "TERM=xterm-ghostty", "TERMINFO=\(resources)/terminfo",
      "WORKROOM_SESSION_RESOURCES=\(resources)", "GHOSTTY_SHELL_FEATURES=cursor,sudo,title",
    ]
    let variables = [
      "WORKROOM_SESSION_ID=\(session.uuidString)",
      "WORKROOM_SESSION_SOCKET=\(socket)",
      "WORKROOM_SESSION_CWD=\(workingDirectory)",
    ]
    return "test -x \(shellQuoted(binary)) || { echo "
      + shellQuoted("workroom: no agent is installed at \(binary) yet") + " >&2; exit 255; }; "
      + "if test -r \(shellQuoted(resources + "/terminfo/x/xterm-ghostty")); then set -- "
      + integrated.map(shellQuoted).joined(separator: " ")
      + "; else unset WORKROOM_SESSION_RESOURCES GHOSTTY_SHELL_FEATURES; "
      + "set -- 'TERM=xterm-256color'; fi; 'env' \"$@\" "
      + (variables + [binary, "attach", "--no-spawn"] + (restored ? ["--no-create"] : []))
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

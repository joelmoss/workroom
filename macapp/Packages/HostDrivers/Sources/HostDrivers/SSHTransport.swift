import DaemonConnection
import Foundation
import WorkroomSystem
import WorkroomWire

/// The ssh transport any ssh-reachable host driver shares (`ContainerHostDriver`'s containers,
/// boxd's machines #256, exe.dev's VMs): where a host is, how `/usr/bin/ssh` reaches it, the
/// attach and relay commands, and the per-host `ssh_config` and `known_hosts`. Moved out of
/// `ContainerHostDriver` as is: none of it is container-shaped, and a driver for any ssh host
/// needs it and nothing else of that driver's.
public enum SSHTransport {
  public struct Host: Sendable {
    public let address: String
    public let port: Int
    public let user: String
    /// The private key ssh authenticates with. The only credential used: `IdentitiesOnly` and
    /// `IdentityAgent none` keep the Mac's ssh agent and default keys out of it.
    public let identityFile: String
    /// The host's public key, `<type> <base64>`, delivered out of band. It is the only key ssh
    /// accepts, and a mismatch fails closed: `BatchMode` cannot prompt to accept a new one.
    public let hostKey: String
    /// The supervised daemon's socket on the host.
    public let daemonSocket: String

    /// The daemon's binary, beside its socket: what the app installs there (`DaemonBootstrap`,
    /// #231), the supervisor starts, and the relay and the attach run. One directory per host,
    /// the socket's 0700 one, so the file has the socket's protection (design doc, the hand-off
    /// trust model: the socket is the boundary).
    public init(
      address: String, port: Int, user: String, identityFile: String, hostKey: String,
      daemonSocket: String
    ) {
      self.address = address
      self.port = port
      self.user = user
      self.identityFile = identityFile
      self.hostKey = hostKey
      self.daemonSocket = daemonSocket
    }

    public var daemonBinary: String { DaemonInstall.binary(besideSocket: daemonSocket) }
    /// Ghostty's terminfo and shell integration, which the bootstrap puts beside the daemon (#239).
    public var resources: String { DaemonInstall.resources(besideSocket: daemonSocket) }
  }

  /// Runs `command` on `host` over ssh, with the host's `ssh_config` and `known_hosts` written to
  /// `hostDirectory` first.
  public static func exec(
    _ command: String, on host: Host, in hostDirectory: URL, purpose: HostStream.Purpose
  ) throws -> HostStream {
    try exec(command, via: route(to: host, in: hostDirectory), purpose: purpose)
  }

  /// How `/usr/bin/ssh` reaches a host: the options ahead of the destination, the destination,
  /// and the environment ssh runs with.
  public struct Route: Sendable {
    public let options: [String]
    public let destination: String
    public var environment: [String: String] = [:]
  }

  /// `host` through its own `ssh_config`, written to `hostDirectory`, and nothing from the app's
  /// environment: ssh needs none of it with this configuration, and `SSH_AUTH_SOCK` in particular
  /// is a Mac credential. `-F` also keeps `/etc/ssh/ssh_config` out, whose `SendEnv LANG LC_*`
  /// would send the Mac's locale across.
  public static func route(to host: Host, in hostDirectory: URL) throws -> Route {
    Route(
      options: ["-F", try writeConfiguration(for: host, in: hostDirectory).path],
      destination: alias)
  }

  /// Runs `command` over `route`.
  public static func exec(_ command: String, via route: Route, purpose: HostStream.Purpose) throws
    -> HostStream
  {
    try HostStream.spawn(
      URL(fileURLWithPath: "/usr/bin/ssh"), route.options + [route.destination, command],
      environment: route.environment,
      // ssh connects and authenticates before the agent can greet. `ConnectTimeout` bounds the
      // connect; this leaves room for the rest.
      handshakeTimeout: 20, purpose: purpose)
  }

  /// The command a pane runs to attach to `session` on `host` over ssh, with the host's
  /// configuration written to `hostDirectory`.
  public static func attachCommand(
    to host: Host, in hostDirectory: URL, session: UUID, workingDirectory: String, restored: Bool,
    metadata: [(key: String, value: String)] = []
  ) throws -> String {
    attachCommand(
      via: try route(to: host, in: hostDirectory), in: hostDirectory,
      daemonSocket: host.daemonSocket, session: session, workingDirectory: workingDirectory,
      restored: restored, metadata: metadata)
  }

  /// The command a pane runs to attach to `session` over `route`, keeping ssh's log in
  /// `hostDirectory`.
  public static func attachCommand(
    via route: Route, in hostDirectory: URL, daemonSocket: String, session: UUID,
    workingDirectory: String, restored: Bool, metadata: [(key: String, value: String)] = []
  ) -> String {
    // `-t`: the attach client on the far side wants a terminal, for raw mode and the pane's size,
    // and ssh forwards the pane's resizes to it. It outranks the config's `RequestTTY no`, which
    // is right for the service stream.
    let log = attachLog(session, in: hostDirectory).path
    let environment = route.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    let ssh =
      (environment.isEmpty ? [] : ["/usr/bin/env"] + environment) + ["/usr/bin/ssh"]
      + route.options + [
        "-E", log, "-o", "PermitLocalCommand=yes", "-o", "LocalCommand=printf '\\0338\\033[J'",
        "-t", route.destination,
        remoteAttachCommand(
          binary: DaemonInstall.binary(besideSocket: daemonSocket), session: session,
          socket: daemonSocket, resources: DaemonInstall.resources(besideSocket: daemonSocket),
          workingDirectory: workingDirectory, restored: restored, metadata: metadata),
      ]
    return (["/bin/sh", "-c", attachWrapper, "workroom-attach", log] + ssh)
      .map(shellQuoted).joined(separator: " ")
  }

  /// What a pane runs around its ssh (#241), as `sh -c <this> workroom-attach <log> <ssh argv>`.
  ///
  /// ssh's own messages go to the session's log (`-E`), so the app can read why the last attach
  /// failed (`hostRefusedLastAttach`) rather than guess from the status, which is 255 for all of
  /// them. A refusal's message is then copied onto the screen, where ssh would have printed it:
  /// the pane stops retrying one, and its reason (a changed host key, a refused key) is what the
  /// user has to act on. Any other lost link says, in plain words, that the pane keeps trying
  /// (`retryNotice`); ssh's own reason stays in the log.
  /// Until ssh is in, the pane says what it is waiting for; `LocalCommand`, which ssh runs once it
  /// has authenticated and before the session starts, restores the cursor saved ahead of that line
  /// and erases from there (DECSC, DECRC, ED), so an attach that goes through shows only the
  /// session, however many rows the line wrapped onto. `SHELL` is what ssh runs `LocalCommand`
  /// with, so it is a POSIX one.
  ///
  /// ssh's status goes beside the log (`attachStatus`), because the pane's own exit status never
  /// carries it: on macOS libghostty starts every command under `/usr/bin/login`, which exits 0
  /// whatever ran under it (#392). The status is removed before ssh starts, so a wrapper killed
  /// before it writes one leaves none rather than the last attach's.
  public static let attachWrapper = """
    log=$1; shift; printf '\\0337%s' "workroom: waiting for this terminal's host..."; \
    : > "$log"; rm -f "${log%.log}.status"; \
    SHELL=/bin/sh "$@"; status=$?; echo "$status" > "${log%.log}.status"; \
    if [ "$status" = 255 ] && ! grep -qiF \(refusalPatterns) "$log"; then \
    printf '\\r\\n%s\\r\\n' \(shellQuoted(retryNotice)) >&2; \
    elif [ -s "$log" ]; then printf '\\r\\n'; cat "$log" >&2; fi; exit "$status"
    """

  /// `refusals` as `grep -e` arguments.
  private static let refusalPatterns = refusals.map { "-e " + shellQuoted($0) }.joined(
    separator: " ")

  /// What a pane whose link dropped says while it keeps trying (#392).
  public static let retryNotice =
    "Can't reach this terminal's host right now. Workroom will keep trying, and your session "
    + "will be restored when it connects."

  /// Where a pane's ssh writes its messages (`-E`): one file per session, emptied by each attach.
  public static func attachLog(_ session: UUID, in hostDirectory: URL) -> URL {
    hostDirectory.appendingPathComponent("attach-\(session.uuidString).log")
  }

  /// Where the attach wrapper writes ssh's exit status, beside `attachLog`.
  public static func attachStatus(_ session: UUID, in hostDirectory: URL) -> URL {
    hostDirectory.appendingPathComponent("attach-\(session.uuidString).status")
  }

  /// How the last attach of `session` ended, from the status the attach wrapper recorded.
  public static func lastAttach(of session: UUID, in hostDirectory: URL) -> LastAttach {
    guard
      let status = try? String(
        contentsOf: attachStatus(session, in: hostDirectory), encoding: .utf8)
    else { return .unrecorded }
    return status.trimmingCharacters(in: .whitespacesAndNewlines) == "255" ? .lostLink : .finished
  }

  /// Whether the last attach of `session`, whose log is in `hostDirectory`, was refused.
  public static func refusedLastAttach(of session: UUID, in hostDirectory: URL) -> Bool {
    isRefusal(
      (try? String(contentsOf: attachLog(session, in: hostDirectory), encoding: .utf8)) ?? "")
  }

  /// ssh's messages for a host that answered and will keep saying no. Listed rather than the
  /// failures that heal, because those are open-ended: a gateway in front of a rebooting VM, or a
  /// socket-activated sshd, can fail in words no list has seen. An authentication denial is
  /// `Permission denied (<methods>)`; a bare `Permission denied` is a connect a firewall refused,
  /// which can heal.
  public static func isRefusal(_ log: String) -> Bool {
    let log = log.lowercased()
    return refusals.contains { log.contains($0) }
  }

  /// `isRefusal`'s messages, lowercase. The attach wrapper matches the same ones, ignoring case.
  public static let refusals = [
    "host key verification failed", "remote host identification has changed",
    "permission denied (", "too many authentication failures", "unable to negotiate",
    "load key", "bad owner or permissions",
  ]

  /// What runs on the host, in the pty ssh allocates there.
  ///
  /// The session contract is the environment `workroomd attach` reads, set with `env` because ssh
  /// carries none of the pane's own. Deliberately absent: the shell (the host's own login shell
  /// applies).
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
  /// A host with no daemon installed yet (rebooted from tmpfs, or never bootstrapped) has no
  /// binary to run, and the shell's 127 for that would read as the session's own exit. It exits
  /// 255 instead, ssh's own status for a lost link, which the app answers by attaching again with
  /// backoff: by then the bootstrap, which nothing orders panes after, has installed it.
  /// `metadata`'s workroom and title go in under the same variables a local pane's attach gets
  /// (`SessionMetadataKey.environmentVariables`), which the host's daemon keeps (#255). Nothing
  /// else does: the project is this Mac's path, which the host neither keeps nor needs, and an ssh
  /// command line is visible to everything on the host.
  public static func remoteAttachCommand(
    binary: String, session: UUID, socket: String, resources: String, workingDirectory: String,
    restored: Bool, metadata: [(key: String, value: String)] = []
  ) -> String {
    let integrated = [
      "TERM=xterm-ghostty", "TERMINFO=\(resources)/terminfo",
      "WORKROOM_SESSION_RESOURCES=\(resources)", "GHOSTTY_SHELL_FEATURES=cursor,sudo,title",
    ]
    let names = Dictionary(uniqueKeysWithValues: SessionMetadataKey.environmentVariables)
      .filter { [SessionMetadataKey.workroom, SessionMetadataKey.title].contains($0.key) }
    let variables =
      [
        "WORKROOM_SESSION_ID=\(session.uuidString)",
        "WORKROOM_SESSION_SOCKET=\(socket)",
        "WORKROOM_SESSION_CWD=\(workingDirectory)",
      ]
      + metadata.compactMap { entry in
        names[entry.key].flatMap { entry.value.isEmpty ? nil : "\($0)=\(entry.value)" }
      }
    // A host an older Nightly made before the rename (#525) has only `wr-agent`, and its supervisor
    // starts only that, so attaching again could never succeed: it says so and ends (D3).
    let former = DaemonInstall.formerBinary(besideSocket: socket)
    return "if ! test -e \(shellQuoted(binary)) && test -x \(shellQuoted(former)); then echo "
      + shellQuoted("workroom: " + DaemonInstall.formerLayoutMessage) + " >&2; exit 1; fi; "
      + "test -x \(shellQuoted(binary)) || { echo "
      + shellQuoted("workroom: no daemon is installed at \(binary) yet") + " >&2; exit 255; }; "
      + "if test -r \(shellQuoted(resources + "/terminfo/x/xterm-ghostty")); then set -- "
      + integrated.map(shellQuoted).joined(separator: " ")
      + "; else unset WORKROOM_SESSION_RESOURCES GHOSTTY_SHELL_FEATURES; "
      + "set -- 'TERM=xterm-256color'; fi; 'env' \"$@\" "
      + (variables + [binary, "attach", "--no-spawn"] + (restored ? ["--no-create"] : []))
      .map(shellQuoted).joined(separator: " ")
  }

  public static let alias = "workroom-host"

  /// The command ssh runs on the host, quoted for the remote shell. The installed binary by its
  /// path: a host has no `workroomd` on its PATH, only what the bootstrap put beside the socket.
  public static func relayCommand(binary: String, socket: String) -> String {
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
  /// - **A dead link is noticed.** `ServerAliveInterval` ends ssh after 45 to 60 s of silence from
  ///   a host that stopped answering (57 s measured on the ssh fixture), which ends the stream and
  ///   so the connection. It is what bounds a link that dies with nothing to send (#228). On a wake
  ///   or a network change the app doesn't wait for it: `RemoteLinkMonitor` asks each host, and
  ///   replaces the links of those that don't answer.
  public static func writeConfiguration(for host: Host, in directory: URL) throws -> URL {
    for (name, value) in [
      ("address", host.address), ("user", host.user), ("identity file", host.identityFile),
      ("host key", host.hostKey), ("daemon socket", host.daemonSocket),
    ] {
      guard !value.isEmpty, !value.contains(where: { $0.isNewline || $0 == "\"" || $0 == "\0" })
      else {
        throw HostDriverError.invalidConfiguration("\(name) is empty or has a quote or newline")
      }
    }
    guard (1...65535).contains(host.port) else {
      throw HostDriverError.invalidConfiguration("port \(host.port) is out of range")
    }
    // The daemon's binary is derived from it (`daemonBinary`), and run by path from any cwd.
    guard host.daemonSocket.hasPrefix("/") else {
      throw HostDriverError.invalidConfiguration("daemon socket must be an absolute path")
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
  public static func shellQuoted(_ text: String) -> String { PosixShell.quoted(text) }
}

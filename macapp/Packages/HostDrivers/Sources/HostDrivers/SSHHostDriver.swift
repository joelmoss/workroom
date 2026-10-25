import CryptoKit
import DaemonConnection
import Foundation
import Synchronization
import WorkroomSystem
import WorkroomVCS

/// A server the user already owns. This driver can reach it and manage marked workroom folders;
/// it cannot create, stop or destroy a host (ADR 0056).
public final class SSHHostDriver: HostTerminalDriver, Sendable {
  public struct Configuration: Sendable {
    public var destination: String
    public var home: String
    public var stateDirectoryName: String
    public var sshAgent: String?
    /// A fixture's ssh configuration. Production leaves this empty and uses the user's ssh.
    public var sshOptions: [String]

    public init(
      destination: String, home: String = "", stateDirectoryName: String = "workroom",
      sshAgent: String? = SSHTransport.userSSHAgent(), sshOptions: [String] = []
    ) {
      self.destination = destination
      self.home = home
      self.stateDirectoryName = stateDirectoryName
      self.sshAgent = sshAgent
      self.sshOptions = sshOptions
    }
  }

  public struct HostInfo: Sendable, Equatable {
    public let home: String
    public let architecture: String
  }

  public struct HostKey: Sendable {
    public let destination: String
    public let fingerprint: String
    public let lines: String
    public let knownHostsFile: URL
  }

  public enum FolderState: Sendable, Equatable { case present, gone }

  public enum Failure: Error, LocalizedError, Equatable {
    case unknownHostKey
    case changedHostKey(String)
    case authentication(String)
    case unreachable(String)
    case unsupportedHost(String)
    case folderExists(String)
    case markerMismatch(String)

    public var errorDescription: String? {
      switch self {
      case .unknownHostKey:
        return "This host's SSH key hasn't been trusted yet."
      case .changedHostKey(let host):
        return "The SSH host key for \(host) changed. Check it in Terminal before connecting again."
      case .authentication(let host):
        return
          "SSH couldn't sign in to \(host) without prompting. Add your key to ssh-agent or the Keychain, then try again."
      case .unreachable(let detail): return "Couldn't reach the SSH host: \(detail)"
      case .unsupportedHost(let detail): return detail
      case .folderExists(let path):
        return "\(path) already exists on the host. Choose another folder."
      case .markerMismatch(let path):
        return "Workroom couldn't verify the marker for \(path), so it kept the folder."
      }
    }
  }

  public static let driverName = "ssh"
  public let configuration: Configuration
  public let directory: URL
  private let runner: any StatusCommandRunning
  private let adoptedHome: Mutex<String>

  public init(
    configuration: Configuration, directory: URL,
    runner: any StatusCommandRunning = StatusCommandRunner()
  ) {
    self.configuration = configuration
    self.directory = directory
    self.runner = runner
    adoptedHome = Mutex(configuration.home)
  }

  public var destination: String { configuration.destination }
  public var home: String { adoptedHome.withLock { $0 } }
  public var hostID: HostID { .remote(Self.id(for: destination)) }
  public var stateDirectory: String { "\(home)/.local/state/\(configuration.stateDirectoryName)" }
  public var daemonSocket: String { "\(stateDirectory)/daemon/workroomd.sock" }
  /// SSH hosts have no supervisor; every connect starts a daemon if nothing is listening.
  public var startsDaemon: Bool { true }

  /// UUIDv5 in a fixed namespace. Destination spelling is the identity, shared by Release and
  /// Nightly and by concurrent creates, even before a host has a descriptor in config.
  public static func id(for destination: String) -> UUID {
    let namespace = UUID(uuidString: "9B051DED-C090-5E0F-8EF4-A153CAEA07DC")!
    var bytes = withUnsafeBytes(of: namespace.uuid) { Data($0) }
    bytes.append(contentsOf: destination.utf8)
    var hash = Array(Insecure.SHA1.hash(data: bytes).prefix(16))
    hash[6] = (hash[6] & 0x0F) | 0x50
    hash[8] = (hash[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
        hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]
      ))
  }

  public static func validateDestination(_ destination: String) throws {
    guard !destination.isEmpty, !destination.hasPrefix("-"),
      !destination.contains(where: { $0.isWhitespace || $0 == "\0" })
    else {
      throw HostDriverError.invalidConfiguration(
        "enter an SSH alias or [user@]host, without spaces or a leading hyphen")
    }
  }

  public func adopt(home: String) throws {
    try Self.validateDestination(destination)
    guard home.hasPrefix("/"), home != "/", !home.contains("\0"),
      !home.contains(where: { $0.isNewline }), Self.normalizedPath(home) == home,
      !configuration.stateDirectoryName.isEmpty,
      !configuration.stateDirectoryName.contains("/"),
      !configuration.stateDirectoryName.contains(where: { $0.isWhitespace || $0 == "\0" }),
      configuration.stateDirectoryName != ".", configuration.stateDirectoryName != ".."
    else { throw HostDriverError.invalidConfiguration("the host's home is not an absolute folder") }
    let socket = "\(home)/.local/state/\(configuration.stateDirectoryName)/daemon/workroomd.sock"
    guard socket.utf8.count < 108 else {
      throw Failure.unsupportedHost(
        "The home folder on \(destination) makes the daemon's socket path 108 bytes or longer. Linux requires a shorter path."
      )
    }
    adoptedHome.withLock { $0 = home }
  }

  /// Read-only checks run before reserving a workroom or making anything on the server.
  public func checkHost() async throws -> HostInfo {
    let result = try await command(Self.hostCheck, timeout: 30)
    guard result.ok, !result.stdoutTruncated else {
      if result.exitCode == 41 {
        throw Failure.unsupportedHost("\(destination) must run Linux on aarch64 or x86_64.")
      }
      if result.exitCode == 42 {
        throw Failure.unsupportedHost("Install git on \(destination), then try again.")
      }
      throw Failure.unsupportedHost("Couldn't read the home folder and platform on \(destination).")
    }
    let lines = result.stdout.split(separator: "\n")
    guard let home = lines.first(where: { $0.hasPrefix("WRSSH home ") }),
      let architecture = lines.first(where: { $0.hasPrefix("WRSSH arch ") })
    else {
      throw Failure.unsupportedHost("\(destination) didn't report its home folder and platform.")
    }
    let info = HostInfo(
      home: String(home.dropFirst("WRSSH home ".count)),
      architecture: String(architecture.dropFirst("WRSSH arch ".count)))
    try adopt(home: info.home)
    return info
  }

  static let hostCheck = """
    sh -c 'os=$(uname -s) || exit 41; arch=$(uname -m) || exit 41
    test "$os" = Linux || exit 41
    case "$arch" in aarch64|x86_64) ;; *) exit 41 ;; esac
    if ! PATH=/usr/local/bin:/usr/bin:/bin command -v git >/dev/null 2>&1; then
      shell=${SHELL:-/bin/sh}
      "$shell" -lic "command -v git >/dev/null" </dev/null >/dev/null 2>&1 &
      probe=$!
      (sleep 10; kill -KILL "$probe" 2>/dev/null) </dev/null >/dev/null 2>&1 &
      watchdog=$!
      status=0
      wait "$probe" || status=$?
      kill "$watchdog" 2>/dev/null || true
      wait "$watchdog" 2>/dev/null || true
      test "$status" = 0 || exit 42
    fi
    printf "WRSSH home %s\\nWRSSH arch %s\\n" "$HOME" "$arch"'
    """

  public func resolveParent(_ parent: String) throws -> String {
    try adopt(home: home)
    let expanded: String
    if parent == "~" {
      expanded = home
    } else if parent.hasPrefix("~/") {
      expanded = home + String(parent.dropFirst())
    } else {
      expanded = parent
    }
    let path = Self.normalizedPath(expanded)
    guard path == home || path.hasPrefix(home + "/"), !path.contains("\0"),
      !path.contains(where: { $0.isNewline })
    else {
      throw HostDriverError.invalidConfiguration("choose a parent folder inside \(home)")
    }
    return path
  }

  /// The normal, strict check must have failed with an unknown key first. This separate ssh
  /// follows the user's proxy/config and records its exact host name, port and hashing choice,
  /// without offering a credential or writing the user's known_hosts before they press Trust.
  public func captureHostKey() async throws -> HostKey {
    try Self.validateDestination(destination)
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: scratch) }
    let file = scratch.appendingPathComponent("known_hosts")
    let options =
      configuration.sshOptions + [
        "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=\(file.path)",
        "-o", "GlobalKnownHostsFile=/dev/null", "-o", "PreferredAuthentications=none",
      ] + SSHTransport.userOwnedOptions()
    _ = await runner.run(
      "/usr/bin/ssh", options + [destination, "true"], in: NSHomeDirectory(), timeout: 20,
      environment: routeEnvironment(spawned: true))
    guard let lines = try? String(contentsOf: file, encoding: .utf8), !lines.isEmpty else {
      throw Failure.unreachable(
        "couldn't read \(destination)'s host key. If you use a jump host, run `ssh \(destination)` in Terminal once."
      )
    }
    let fingerprint = await runner.run(
      "/usr/bin/ssh-keygen", ["-lf", file.path], in: NSHomeDirectory(), timeout: 10)
    guard fingerprint.ok, !fingerprint.stdoutTruncated else {
      throw Failure.unreachable("couldn't read the fingerprint of \(destination)'s host key")
    }
    let resolved = await runner.run(
      "/usr/bin/ssh", configuration.sshOptions + ["-G", destination], in: NSHomeDirectory(),
      timeout: 10)
    guard resolved.ok, let path = SSHTransport.knownHostsFile(in: resolved.stdout) else {
      throw Failure.unreachable("ssh named no known_hosts file for \(destination)")
    }
    return HostKey(
      destination: destination,
      fingerprint: fingerprint.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
      lines: lines.trimmingCharacters(in: .newlines), knownHostsFile: URL(fileURLWithPath: path))
  }

  public func trustHostKey(_ key: HostKey) throws {
    guard key.destination == destination else {
      throw HostDriverError.invalidConfiguration("the SSH key belongs to another destination")
    }
    try SSHTransport.appendKnownHost(key.lines, to: key.knownHostsFile)
  }

  public func route(spawned: Bool) throws -> SSHTransport.Route {
    try Self.validateDestination(destination)
    return SSHTransport.Route(
      options: configuration.sshOptions + SSHTransport.userOwnedOptions()
        + ["-o", "StrictHostKeyChecking=yes"],
      destination: destination, environment: routeEnvironment(spawned: spawned))
  }

  private func routeEnvironment(spawned: Bool) -> [String: String] {
    var environment = configuration.sshAgent.map { ["SSH_AUTH_SOCK": $0] } ?? [:]
    if spawned { environment["PATH"] = ShellEnvironment.path() }
    return environment
  }

  private func check(_ host: HostID) throws {
    guard host == hostID else { throw HostDriverError.unknownHost(host) }
    try adopt(home: home)
  }

  private var hostDirectory: URL {
    directory.appendingPathComponent(Self.id(for: destination).uuidString)
  }

  public func openStream(to host: HostID) async throws -> HostStream {
    try check(host)
    return try SSHTransport.exec(
      SSHTransport.relayCommand(
        binary: DaemonInstall.binary(besideSocket: daemonSocket), socket: daemonSocket),
      via: route(spawned: true), purpose: .connection)
  }

  public func exec(_ command: String, on host: HostID) async throws -> HostStream {
    try check(host)
    return try SSHTransport.exec(command, via: route(spawned: true), purpose: .exchange)
  }

  public func attachCommand(
    to host: HostID, session: UUID, workingDirectory: String, restored: Bool,
    metadata: [(key: String, value: String)], runCommand: String?
  ) throws -> String {
    try check(host)
    try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
    return SSHTransport.attachCommand(
      via: try route(spawned: false), in: hostDirectory, daemonSocket: daemonSocket,
      session: session, workingDirectory: workingDirectory, restored: restored,
      metadata: metadata, runCommand: runCommand)
  }

  public func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool {
    guard host == hostID else { return false }
    return SSHTransport.refusedLastAttach(of: session, in: hostDirectory)
  }

  public func lastAttach(of session: UUID, on host: HostID) -> LastAttach {
    guard host == hostID else { return .finished }
    return SSHTransport.lastAttach(of: session, in: hostDirectory)
  }

  /// Creates one leaf atomically, then writes its ownership marker. An existing leaf fails before
  /// either the parent or state directory is changed. There is no pending-machine journal.
  public func prepareFolder(path: String, workroom: UUID) async throws {
    let (path, marker) = try folderArguments(path: path, workroom: workroom)
    let parent = (path as NSString).deletingLastPathComponent
    let script = """
      umask 077
      path=\(PosixShell.quoted(path)); parent=\(PosixShell.quoted(parent))
      marker=\(PosixShell.quoted(marker)); home=\(PosixShell.quoted(home))
      if test -e "$path" || test -L "$path"; then exit 43; fi
      homePhysical=$(cd -P -- "$home" && pwd) || exit 44
      for target in "$parent" "$(dirname "$marker")"; do
        ancestor=$target
        while ! test -d "$ancestor"; do
          test ! -e "$ancestor" && test ! -L "$ancestor" || exit 44
          ancestor=$(dirname "$ancestor")
        done
        physical=$(cd -P -- "$ancestor" && pwd) || exit 44
        case "$physical/" in "$homePhysical/"*) ;; *) exit 44 ;; esac
      done
      mkdir -p -- "$parent" || exit 44
      physical=$(cd -P -- "$parent" && pwd) || exit 44
      case "$physical/" in "$homePhysical/"*) ;; *) exit 44 ;; esac
      mkdir -- "$path" || exit 43
      if ! mkdir -p -- "$(dirname "$marker")" || ! printf '%s\\n' "$path" > "$marker"; then
        rmdir -- "$path"; rm -f -- "$marker"; exit 44
      fi
      """
    let result = try await command("sh -c " + PosixShell.quoted(script), timeout: 30)
    if result.exitCode == 43 { throw Failure.folderExists(path) }
    guard result.ok else { throw Failure.unreachable("couldn't make \(path) on \(destination)") }
  }

  /// Checked before teardown as well as before removal, so a vanished or unverified folder never
  /// runs a script that could create it again or act on a different checkout.
  public func folderState(path: String, workroom: UUID) async throws -> FolderState {
    let (path, marker) = try folderArguments(path: path, workroom: workroom)
    let script = Self.folderGuard(path: path, marker: marker, home: home)
    let result = try await command("sh -c " + PosixShell.quoted(script), timeout: 20)
    if result.exitCode == 45 { return .gone }
    if result.exitCode == 46 { throw Failure.markerMismatch(path) }
    guard result.ok else { throw Failure.unreachable("couldn't check \(path) on \(destination)") }
    return .present
  }

  public func removeFolder(path: String, workroom: UUID) async throws {
    let (path, marker) = try folderArguments(path: path, workroom: workroom)
    let script =
      Self.folderGuard(path: path, marker: marker, home: home) + """

        rm -rf -- \(PosixShell.quoted(path)) || exit 44
        rm -f -- \(PosixShell.quoted(marker))
        """
    let result = try await command("sh -c " + PosixShell.quoted(script), timeout: 600)
    if result.exitCode == 45 { return }
    if result.exitCode == 46 { throw Failure.markerMismatch(path) }
    guard result.ok else { throw Failure.unreachable("couldn't remove \(path) on \(destination)") }
  }

  private func folderArguments(path: String, workroom: UUID) throws -> (String, String) {
    try adopt(home: home)
    let normalized = Self.normalizedPath(path)
    guard normalized == path, path.hasPrefix(home + "/"), !path.contains("\0"),
      !path.contains(where: { $0.isNewline }), path != stateDirectory,
      !stateDirectory.hasPrefix(path + "/"), !path.hasPrefix(stateDirectory + "/")
    else {
      throw HostDriverError.invalidConfiguration("the workroom's folder must be inside \(home)")
    }
    return (path, "\(stateDirectory)/workrooms/\(workroom.uuidString.lowercased())")
  }

  static func folderGuard(path: String, marker: String, home: String) -> String {
    """
    path=\(PosixShell.quoted(path)); marker=\(PosixShell.quoted(marker))
    homePhysical=$(cd -P -- \(PosixShell.quoted(home)) && pwd) || exit 46
    if test -d "$(dirname "$marker")"; then
      markerPhysical=$(cd -P -- "$(dirname "$marker")" && pwd) || exit 46
      case "$markerPhysical/" in "$homePhysical/"*) ;; *) exit 46 ;; esac
    fi
    if ! test -e "$path" && ! test -L "$path"; then rm -f -- "$marker"; exit 45; fi
    test ! -L "$path" && test -f "$marker" && test ! -L "$marker" || exit 46
    test "$(cat -- "$marker")" = "$path" || exit 46
    physical=$(cd -P -- "$path" && pwd) || exit 46
    case "$physical/" in "$homePhysical/"*) ;; *) exit 46 ;; esac
    """
  }

  /// Remote Linux paths must not pass through NSString.standardizingPath: that consults this
  /// Mac's filesystem and rewrites paths such as /private/tmp to /tmp.
  private static func normalizedPath(_ path: String) -> String {
    guard path.hasPrefix("/") else { return "" }
    var parts: [Substring] = []
    for part in path.split(separator: "/") {
      if part == "." { continue }
      if part == ".." {
        if !parts.isEmpty { parts.removeLast() }
      } else {
        parts.append(part)
      }
    }
    return "/" + parts.joined(separator: "/")
  }

  private func command(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
    let route = try route(spawned: true)
    ProvisioningProgress.record("$ ssh \(destination) \(command)")
    let result = await runner.run(
      "/usr/bin/ssh", route.options + [route.destination, command], in: NSHomeDirectory(),
      timeout: timeout, environment: route.environment)
    ProvisioningProgress.record(result.stdout + result.stderr)
    try Task.checkCancellation()
    if result.exitCode == 255 || result.timedOut || result.signaled {
      let said = (result.stderr + "\n" + result.stdout).trimmingCharacters(
        in: .whitespacesAndNewlines)
      if said.contains("REMOTE HOST IDENTIFICATION HAS CHANGED")
        || said.contains("Host key for ") && said.contains("has changed")
      {
        throw Failure.changedHostKey(destination)
      }
      if said.contains("No ") && said.contains("host key is known for") {
        throw Failure.unknownHostKey
      }
      if said.contains("Permission denied") || said.contains("sign_and_send_pubkey")
        || said.contains("incorrect passphrase")
      {
        throw Failure.authentication(destination)
      }
      throw Failure.unreachable(
        said.isEmpty ? "\(destination) didn't answer" : "\(destination): \(said)")
    }
    return result
  }
}

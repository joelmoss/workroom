import Foundation
import os

/// The second real provider driver (#259): exe.dev VMs, driven through exe.dev's ssh API
/// (`ssh exe.dev <command> --json`) and reached over ssh. Each workroom is a fresh VM of its own.
///
/// - **The user's own ssh.** exe.dev knows the user by their ssh key, and the driver's ssh is the
///   one `ssh exe.dev` in Terminal is: the user's `~/.ssh/config`, keys, agent and Keychain pick
///   the key, so a second account is a `Host exe.dev *.exe.xyz` block there (VMs are reached as
///   `exedev@<vm>.exe.xyz`, exe.dev's own name for them, which `Host exe.dev` alone doesn't match),
///   as for any ssh. Workroom sets
///   only what a background link needs (`sshOptions`). Nothing is registered on the account: the
///   generic ssh driver (#378) can't register keys on a server it didn't make, so both take this
///   path (eng review, D2 reopened).
/// - **One gateway.** exe.dev ends ssh at its gateway, which presents one host key for `exe.dev`
///   and every `<vm>.exe.xyz` (spike, 2026-10-08). A VM's key is checked against the user's own
///   `known_hosts` entry for `exe.dev` (`HostKeyAlias`), so a key exe.dev rotates is accepted
///   again with one `ssh exe.dev`, not an app update.
/// - **A host** is `new`, then `Resources/host-setup/systemd.sh` run as root. exe.dev gives every
///   VM its own machine-id (measured, 2026-10-10), so the identity unit has little to mint here.
/// - **Names.** A host is the VM `<prefix>-<host id>`. A failed step removes by name.
///
/// exe.dev has no stop, start or idle timer, and its VMs were never put to sleep while idle
/// (spike), so nothing here reads presence or keeps a box awake.
final class ExeDevHostDriver: HostTerminalDriver, @unchecked Sendable {
  struct Configuration: Sendable {
    /// What every VM this driver makes is named after.
    var prefix = "workroom"
    /// The exe.dev account this driver's VMs belong to, `whoami`'s email, or nil to accept any.
    /// Checked before every create, destroy and rollback: another account's VM reads as
    /// "not found", which `destroy` would take for gone. Whoever records a host records this.
    var account: String?
    /// The agent's socket on every host, on the home disk: the agent keeps its broker enrolment
    /// beside it, and `/run` is a tmpfs (spike).
    var agentSocket = "\(ExeDevHostDriver.stateDirectory)/agent/agent.sock"
    /// Where the supervisor has the agent keep each session's last screen (#232).
    var screens = "\(ExeDevHostDriver.stateDirectory)/screens"
    /// The user's ssh-agent socket, or nil for none. Their `IdentityAgent`, if set, wins.
    var sshAgent: String? = ExeDevHostDriver.userSSHAgent()
  }

  /// The user every exe.dev VM logs in as (exeuntu's `exe.dev/login-user`).
  static let user = "exedev"
  static let stateDirectory = "/home/\(user)/.local/state/workroom"
  static let lobby = "exe.dev"
  /// The gateway's key's fingerprint as exe.dev publishes it (`ssh exe.dev doc faq/host-key`), for
  /// an error that asks the user to sign in once.
  static let gatewayFingerprint = "SHA256:JJOP/lwiBGOMilfONPWZCXUrfK154cnJFXcqlsi6lPo"

  var traits: HostDriverTraits {
    HostDriverTraits(transport: .sshStdio, durableDisk: true, maxLifetime: nil)
  }

  let configuration: Configuration
  var agentSocket: String { configuration.agentSocket }
  /// Where each host's attach logs are kept.
  let directory: URL
  private let runner: any StatusCommandRunning

  init(
    configuration: Configuration, directory: URL,
    runner: any StatusCommandRunning = StatusCommandRunner()
  ) {
    self.configuration = configuration
    self.directory = directory
    self.runner = runner
  }

  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "ExeDevHostDriver")

  func name(of id: UUID) -> String { "\(configuration.prefix)-\(id.uuidString.lowercased())" }

  private func id(of host: HostID) throws -> UUID {
    guard case .remote(let id) = host else { throw HostDriverError.unknownHost(host) }
    return id
  }

  private func hostDirectory(_ id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString)
  }

  // MARK: Provisioning

  /// A fresh VM, set up as a workroom's host: the identity unit has minted its identity and the
  /// supervisor is waiting for an agent. A VM that gets no further is removed.
  func create() async throws -> HostID {
    try await checkAccount()
    let id = UUID()
    let name = name(of: id)
    try markPending(id)
    do {
      RemoteProvisioning.reportStep?(.machine)
      _ = try await cli(["new", "--name", name, "--no-email"])
      try await awaitBoot(of: id)
      RemoteProvisioning.reportStep?(.setup)
      let (status, output) = try await exec(
        "sudo sh -s -- "
          + [Self.user, configuration.agentSocket, configuration.screens]
          .map(PosixShell.quoted).joined(separator: " "),
        on: .remote(id)
      ).communicate(Data(try HostSetup.systemdScript().utf8), timeout: 120)
      guard status == 0 else {
        throw HostDriverError.provisioning("setting up \(name) failed: \(output)")
      }
      try await awaitIdentity(of: id)
      return .remote(id)
    } catch {
      try await undo(error, id: id)
    }
  }

  /// Removes the VM. One already gone counts as removed, so a caller retrying after a later step
  /// of its own failed gets past the destroy it already did.
  func destroy(_ host: HostID) async throws {
    let id = try id(of: host)
    try await checkAccount()
    if let failure = await remove(name(of: id)) {
      try Task.checkCancellation()
      throw HostDriverError.provisioning(failure)
    }
    PendingMachines.forget([id], in: directory)
    try? FileManager.default.removeItem(at: hostDirectory(id))
  }

  /// Names VM `id` as pending before the call that makes it, so a crash before config records its
  /// host still leaves it for the sweep (#373).
  private func markPending(_ id: UUID) throws {
    try PendingMachines.add(
      .init(id: id, driver: RemoteWorkrooms.exeDevDriver, account: configuration.account),
      in: directory)
  }

  /// Removes what a failed `create` made, then rethrows `error`, or says what is still there. In a
  /// task of its own, so a cancelled caller still cleans up.
  private func undo(_ error: any Error, id: UUID) async throws -> Never {
    let name = name(of: id)
    let failure = await Task { () -> String? in
      // In another account, the VM would read as not found and count as removed.
      do { try await self.checkAccount() } catch {
        return "\(name) not removed: \(error.localizedDescription)"
      }
      return await self.remove(name)
    }.value
    try? FileManager.default.removeItem(at: hostDirectory(id))
    let error =
      (error as? CLIFailure).map { HostDriverError.provisioning($0.localizedDescription) } ?? error
    guard let failure else {
      PendingMachines.forget([id], in: directory)
      throw error
    }
    throw HostDriverError.leftBehind(
      cause: error.localizedDescription, leftover: [failure], host: .remote(id))
  }

  /// Nil once the VM is gone, whether this removed it or it was never there. `rm` exits 0 either
  /// way, so its answer is read from what it printed, never its status (spike).
  private func remove(_ name: String) async -> String? {
    let result = await run(["rm", name, "--json"], timeout: 120)
    if Task.isCancelled { return "VM \(name): cancelled" }
    let objects = Self.jsonObjects(result.stdout)
    if let removal = objects.compactMap({ try? JSONDecoder().decode(Removal.self, from: $0) }).last
    {
      if removal.deleted.contains(name) { return nil }
      if removal.failed.contains(name), let said = Self.errorLine(result), Self.isNotFound(said) {
        return nil
      }
    }
    return "VM \(name): \(Self.errorLine(result) ?? "rm exited \(result.exitCode)")"
  }

  /// Until systemd has finished booting a new VM: `new` returns, and ssh answers, while it still
  /// boots, and the setup's `systemctl` then fails with "Failed to connect to bus" (measured,
  /// 2026-10-08: four of seven fresh VMs). `degraded` is booted, with a unit that failed.
  private func awaitBoot(of id: UUID) async throws {
    try await poll(
      .remote(id),
      "s=$(systemctl is-system-running --wait 2>/dev/null); test \"$s\" = running || test \"$s\" = degraded",
      tries: 150
    ) { "\(self.name(of: id)) never finished booting: \($0)" }
  }

  /// Until the identity unit has run on this VM: its marker and hostname both name it.
  private func awaitIdentity(of id: UUID) async throws {
    let name = PosixShell.quoted(name(of: id))
    try await poll(
      .remote(id),
      "test \"$(cat /etc/workroom-identity 2>/dev/null)\" = \(name) && test \"$(hostname)\" = \(name)",
      tries: 150
    ) { "\(self.name(of: id)) never minted its identity: \($0)" }
  }

  /// Refuses to act while exe.dev answers as another account than this driver's.
  private func checkAccount() async throws {
    let email = try await signedIn()
    if let expected = configuration.account, email != expected {
      throw HostDriverError.invalidConfiguration(
        "exe.dev knows your ssh key as \(email), but this workroom's VMs are in \(expected)'s"
          + " account; use that account's key")
    }
  }

  /// The account exe.dev knows the user's key as, `whoami`'s email. Throws, naming the fix, when
  /// the user's ssh can't sign in to exe.dev.
  func signedIn() async throws -> String {
    do {
      return try await decode(Whoami.self, cli(["whoami"]), "the signed-in account").email
    } catch let failure as CLIFailure {
      throw HostDriverError.provisioning(failure.localizedDescription)
    }
  }

  // MARK: The ssh API

  /// A command exe.dev answered with an error. Never thrown out of the driver: `undo` and the
  /// callers turn it into a `HostDriverError`.
  private struct CLIFailure: Error, LocalizedError {
    let command: String
    let said: String
    var errorDescription: String? { "exe.dev \(command): \(said)" }
  }

  struct Whoami: Decodable { let email: String }

  struct Removal: Decodable {
    let deleted: [String]
    let failed: [String]
  }

  private func decode<T: Decodable>(_ type: T.Type, _ output: String, _ name: String) throws -> T {
    guard
      let value = Self.jsonObjects(output).compactMap({
        try? JSONDecoder().decode(T.self, from: $0)
      })
      .last
    else {
      throw HostDriverError.provisioning(
        "exe.dev said something unreadable about \(name): \(output)")
    }
    return value
  }

  /// One lobby command with `--json`, and its stdout. A failure says exe.dev's own error.
  private func cli(_ arguments: [String], timeout: TimeInterval = 120) async throws -> String {
    let result = await run(arguments + ["--json"], timeout: timeout)
    // The runner kills ssh when the task is cancelled, and that reads as a failure.
    try Task.checkCancellation()
    guard result.ok else {
      throw CLIFailure(
        command: arguments.first ?? "",
        said: Self.errorLine(result)
          ?? (result.timedOut ? "timed out after \(Int(timeout))s" : "exited \(result.exitCode)"))
    }
    return result.stdout
  }

  /// `ssh exe.dev <arguments>`, as the user's own ssh signs in: with the login shell's ssh agent
  /// when the app has none, as a VM's ssh gets it (`sshAgent`), for an app launched from Finder.
  private func run(_ arguments: [String], timeout: TimeInterval) async -> CommandResult {
    await runner.runNetwork(
      "/usr/bin/ssh", Self.sshOptions + [Self.lobby] + arguments,
      in: NSHomeDirectory(), timeout: timeout)
  }

  /// exe.dev's error from a command's output: `{"error": "..."}`, printed on stdout and stderr
  /// alike (spike), or ssh's own message when it never got in.
  static func errorLine(_ result: CommandResult) -> String? {
    // 255 is ssh's own failure: it never got in, so the fix is the user's ssh, not exe.dev.
    if result.exitCode == 255, !result.stderr.contains("{") {
      let said = result.stderr.split(separator: "\n").last.map(String.init) ?? "ssh failed"
      return "\(said.trimmingCharacters(in: .whitespaces)) Run `ssh exe.dev` in Terminal: it must"
        + " sign in without asking, and know exe.dev's host key (\(gatewayFingerprint))."
    }
    for output in [result.stdout, result.stderr] {
      for object in jsonObjects(output) {
        if let error = (try? JSONSerialization.jsonObject(with: object) as? [String: Any])?[
          "error"] as? String
        {
          return error
        }
      }
    }
    let said = result.stderr.split(separator: "\n").map {
      $0.trimmingCharacters(in: .whitespaces)
    }.first { !$0.isEmpty && !$0.hasPrefix("{") }
    return said.map { $0.hasPrefix("error: ") ? String($0.dropFirst(7)) : $0 }
  }

  /// Each line of `output` that is a JSON object, in order: `rm` prints two (spike).
  static func jsonObjects(_ output: String) -> [Data] {
    output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.hasPrefix("{") }.map { Data($0.utf8) }
  }

  /// exe.dev's answer for a VM that doesn't exist: `VM "<name>" not found`, or `vm "<name>" not
  /// found` from `cp` (spike). Matched whole, so a transport failure that happens to say "not
  /// found" is never taken for a removal.
  static func isNotFound(_ said: String) -> Bool {
    (said.hasPrefix("VM \"") || said.hasPrefix("vm \"")) && said.hasSuffix("\" not found")
      && !said.dropFirst(4).dropLast(11).contains("\"")
  }

  // MARK: ssh

  /// What Workroom sets over the user's own ssh configuration, which supplies the rest (keys,
  /// agent, Keychain, proxies), as for `ssh exe.dev` in Terminal. A background link can't prompt,
  /// takes a VM's key to be the gateway's, forwards nothing to a VM an agent works on, and notices
  /// a dead link (#228); a pane's ssh reads no escapes from what is typed in it. A pane's `-t`
  /// outranks `RequestTTY`.
  static let sshOptions = [
    "BatchMode=yes", "HostKeyAlias=\(lobby)", "ForwardAgent=no", "ForwardX11=no",
    "ClearAllForwardings=yes", "ControlMaster=no", "ControlPath=none", "RemoteCommand=none",
    "EscapeChar=none", "RequestTTY=no", "ServerAliveInterval=15", "ServerAliveCountMax=3",
    "ConnectTimeout=10",
    "LogLevel=ERROR",
  ].flatMap { ["-o", $0] }

  /// The user's ssh-agent socket: the app's own environment's, else the login shell's, where an
  /// agent such as 1Password's is set (`StatusCommandRunner.forwardedAuthKeys`).
  static func userSSHAgent(
    inherited: [String: String] = ProcessInfo.processInfo.environment,
    probed: @autoclosure () -> [String: String] = ShellEnvironment.environment()
  ) -> String? {
    for value in [inherited["SSH_AUTH_SOCK"], probed()["SSH_AUTH_SOCK"]] {
      if let value, !value.isEmpty { return value }
    }
    return nil
  }

  /// The VM as the user's ssh reaches it, with only the agent's socket from the app's environment.
  /// An ssh the app spawns gets no other environment (`HostStream.spawn`), so it also gets the
  /// login shell's PATH, where a `ProxyCommand`'s helper is found, as in Terminal; a pane's ssh
  /// has the pane's own.
  func route(_ id: UUID, spawned: Bool) -> ContainerHostDriver.Route {
    var environment = configuration.sshAgent.map { ["SSH_AUTH_SOCK": $0] } ?? [:]
    if spawned { environment["PATH"] = ShellEnvironment.path() }
    return ContainerHostDriver.Route(
      options: Self.sshOptions, destination: "\(Self.user)@\(name(of: id)).exe.xyz",
      environment: environment)
  }

  func openStream(to host: HostID) async throws -> HostStream {
    let id = try id(of: host)
    return try ContainerHostDriver.exec(
      ContainerHostDriver.relayCommand(
        binary: AgentBootstrap.binary(besideSocket: agentSocket), socket: agentSocket),
      via: route(id, spawned: true), purpose: .connection)
  }

  func exec(_ command: String, on host: HostID) async throws -> HostStream {
    try ContainerHostDriver.exec(
      command, via: route(try id(of: host), spawned: true), purpose: .exchange)
  }

  func attachCommand(
    to host: HostID, session: UUID, workingDirectory: String, restored: Bool,
    metadata: [(key: String, value: String)]
  ) throws -> String {
    let id = try id(of: host)
    try FileManager.default.createDirectory(
      at: hostDirectory(id), withIntermediateDirectories: true)
    return ContainerHostDriver.attachCommand(
      via: route(id, spawned: false), in: hostDirectory(id), agentSocket: agentSocket,
      session: session,
      workingDirectory: workingDirectory, restored: restored, metadata: metadata)
  }

  func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool {
    guard case .remote(let id) = host else { return false }
    return ContainerHostDriver.refusedLastAttach(of: session, in: hostDirectory(id))
  }

  func lastAttachLostLink(of session: UUID, on host: HostID) -> Bool {
    guard case .remote(let id) = host else { return false }
    return ContainerHostDriver.lostLinkLastAttach(of: session, in: hostDirectory(id))
  }
}

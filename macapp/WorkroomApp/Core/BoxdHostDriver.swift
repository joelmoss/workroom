import Foundation

/// The first real provider driver (#256): boxd.sh machines, driven through the `boxd` CLI and
/// reached over ssh, with the **portable** derivation (design doc, Phase 4: "the slowest correct
/// derivation first"). boxd's live fork is #258's accelerator, behind the same `deriveFromBase`.
///
/// - **The CLI, not an SDK.** Every call is `boxd … --json`, its JSON read here into the driver's
///   own result. The CLI also writes each machine's ssh stanza into `~/.ssh/config` and its host
///   key into `~/.ssh/known_hosts`, inside blocks it manages; the driver reads the machine's
///   address, port, user, key and host key from those blocks only (`SSHDetails`), and writes its
///   own locked-down configuration from them (`ContainerHostDriver.writeConfiguration`), so
///   nothing else in the user's ssh config applies. The host key is boxd's gateway's, the same
///   for every machine, which is why a derived machine's own regenerated keys never trip it
///   (Phase 0, item 6). The VM's sshd is not what answers: boxd terminates ssh at the gateway.
/// - **A base** is a fresh machine with `Resources/host-setup/boxd.sh` run on it: the identity
///   unit and the agent's supervisor, both systemd units (see the script).
/// - **A derive** snapshots the base, makes a machine from the snapshot, and cold-reboots it. A
///   snapshot restores memory as well as disk, so without the reboot the instance would run the
///   base's processes with the base's machine-id and boot_id (measured); after it, the instance
///   has only the base's disk, a kernel of its own, and the identity its identity unit mints at
///   boot. The snapshot is removed once the machine exists (a machine outlives its snapshot,
///   measured).
/// - **Names.** A host is the machine `<prefix>-<host id>`, and a derive's snapshot is named the
///   same. A failed step removes by name, since the CLI's own output may never have arrived, and
///   a driver made after a relaunch reaches a recorded host by its ID alone.
///
/// Everything the agent keeps is on the machine's home disk (`agentSocket`), so a machine that is
/// stopped and started keeps its enrolment and its screens.
final class BoxdHostDriver: HostTerminalDriver, @unchecked Sendable {
  struct Configuration: Sendable {
    /// The `boxd` CLI, signed in.
    var cli: URL
    /// What every machine and snapshot this driver makes is named after.
    var prefix = "workroom"
    /// The boxd org this driver's machines belong to, as `boxd auth --json` reports the active
    /// one: nil for the account's own. The CLI acts in whichever org is active, and its own org
    /// cannot be named with `--org` (measured: "you are not a member of org …"), so the driver
    /// checks the active org instead of choosing it, and refuses to act in another: there, its
    /// machines read as "not found", which `destroy` would take for gone and leave running.
    /// Whoever records a host records this beside it.
    var org: String?
    /// The boxd account this driver's machines belong to, `boxd auth --json`'s `user_id`, or nil
    /// to accept any (#356). Every personal account's org is nil, so after a switch to another
    /// account the org check alone passes, and a machine of the first account reads as "not
    /// found", which `destroy` would take for gone. Whoever records a host records this beside it.
    var account: String?
    /// The agent's socket on every host. On the home disk, never the tmpfs `/run`: the agent keeps
    /// its broker enrolment beside it (`broker.rs`), and a stopped machine would lose it.
    var agentSocket = Configuration.defaultAgentSocket
    static let defaultAgentSocket = "/home/boxd/.local/state/workroom/agent/agent.sock"

    /// Where the supervisor has the agent keep each session's last screen (#232).
    var screens = "/home/boxd/.local/state/workroom/screens"
    /// The files the CLI writes each machine's ssh stanza and host key into.
    var sshConfig = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".ssh/config")
    var knownHosts = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".ssh/known_hosts")
  }

  /// The user every boxd machine logs in as, whose home holds the agent's state and the clone.
  static let user = "boxd"

  /// Estimated from its measured parts, not timed end to end: the snapshot is most of it (9-11 s
  /// for a stock machine's disk), the restore half a second, and the reboot a few seconds more.
  /// A derive keeps no process: the reboot ends every one.
  var traits: HostDriverTraits {
    HostDriverTraits(
      transport: .sshStdio, deriveSpeed: .seconds(20), deriveCarriesLiveProcesses: false,
      durableDisk: true, maxLifetime: nil, keepAwakeHoldsCredential: false,
      sleepsWhenIdle: true)
  }

  let configuration: Configuration
  /// Where each host's `ssh_config` and `known_hosts` are written.
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

  func name(of id: UUID) -> String { "\(configuration.prefix)-\(id.uuidString.lowercased())" }

  private func id(of host: HostID) throws -> UUID {
    guard case .remote(let id) = host else { throw HostDriverError.unknownHost(host) }
    return id
  }

  private func hostDirectory(_ id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString)
  }

  // MARK: Provisioning

  /// A fresh machine, set up as a base: the identity unit has minted its identity and the
  /// supervisor is waiting for an agent. A machine that gets no further is removed.
  func create() async throws -> HostID {
    try await checkOrg()
    let id = UUID()
    let name = name(of: id)
    do {
      _ = try await cli(["machine", "new", name])
      let script = try Self.setupScript()
      let user = try ssh(id).user
      let (status, output) = try await exec(
        "sudo sh -s -- "
          + [user, configuration.agentSocket, configuration.screens]
          .map(PosixShell.quoted).joined(separator: " "),
        on: .remote(id)
      ).communicate(Data(script.utf8), timeout: 120)
      guard status == 0 else {
        throw HostDriverError.provisioning("setting up \(name) failed: \(output)")
      }
      try await awaitIdentity(of: id)
      return .remote(id)
    } catch {
      try await undo(error, id: id, snapshot: nil)
    }
  }

  /// A snapshot of `base`, made into a machine of its own and rebooted, so it keeps the base's
  /// disk and nothing else. The base keeps running. Callers serialise this against anything that
  /// writes the base's repository (`BaseLocks`).
  func deriveFromBase(_ base: HostID) async throws -> HostID {
    let baseName = name(of: try id(of: base))
    try await checkOrg()
    // An instance's disk holds its enrolment key and credential helper: a copy would start with
    // both. Every base is a fresh machine, and every instance is made from a snapshot.
    let machine: Machine
    do {
      machine = try decode(Machine.self, await cli(["machine", "get", baseName]), baseName)
    } catch let failure as CLIFailure {
      if failure.notFound { throw HostDriverError.unknownHost(base) }
      throw HostDriverError.provisioning(failure.localizedDescription)
    }
    guard machine.source == "standalone" else {
      throw HostDriverError.invalidConfiguration("a workroom instance cannot be derived from")
    }
    let id = UUID()
    let name = name(of: id)
    do {
      // Load-bearing twice over. A snapshot holds memory as well as disk, and the reboot below is
      // a power cut to it: whatever the base's last clone or fetch left in its page cache would
      // never reach the instance's disk. And a hibernated base refuses a snapshot, while an ssh
      // login wakes it (measured: "vm is 'suspended' — must be running to snapshot").
      let (status, output) = try await exec("sync", on: base).communicate(nil, timeout: 60)
      guard status == 0 else {
        throw HostDriverError.provisioning("syncing \(baseName) failed: \(output)")
      }
      // `snapshots save` prints nothing until it is done, and copying a base's disk takes a while.
      _ = try await cli(["snapshots", "save", baseName, name], timeout: 900)
      // From here until the reboot the instance runs the base's processes (a restore resumes
      // them), so nothing waits in between that does not have to.
      _ = try await cli(["machine", "new", name, "--from-snapshot", name])
      // boxd names the machine on restore; minting before it had would key the identity on the
      // base's hostname. Measured to be there at once.
      try await awaitHostname(of: id)
      // Minted before the reboot, so nothing in the boot can start with the base's: systemd
      // documents that a process caches the machine-id it first reads, and the unit runs after
      // early boot. Defensive: not reproduced on boxd, where PID 1 reported the new one either way
      // (measured over D-Bus, 2026-10-02). The unit then finds its marker current.
      // Flushed after: the reboot is a power cut, and an identity still in the page cache would
      // boot as the base's.
      let (minted, said) = try await exec(
        "sudo /usr/local/libexec/workroom-identity && sync", on: .remote(id)
      ).communicate(nil, timeout: 60)
      guard minted == 0 else {
        throw HostDriverError.provisioning("minting \(name)'s identity failed: \(said)")
      }
      let boot = try await bootID(of: id)
      _ = try await cli(["machine", "reboot", name])
      _ = try await cli(["snapshots", "remove", name, "-y"])
      try await awaitIdentity(of: id, rebootedFrom: boot)
      // The identity unit is done before the supervisor starts the agent, so a connection made
      // the moment the marker is right can find nothing listening yet.
      try await awaitAgent(of: id)
      return .remote(id)
    } catch {
      try await undo(error, id: id, snapshot: name)
    }
  }

  /// Removes the machine. One already gone counts as removed, so a caller retrying after a later
  /// step of its own failed gets past the destroy it already did.
  func destroy(_ host: HostID) async throws {
    let id = try id(of: host)
    try await checkOrg()
    if let failure = await remove(machine: name(of: id)) {
      try Task.checkCancellation()
      throw HostDriverError.provisioning(failure)
    }
    try? FileManager.default.removeItem(at: hostDirectory(id))
  }

  /// Removes what a failed `create` or `deriveFromBase` made, then rethrows `error`, or says what
  /// is still there. In a task of its own, so a cancelled caller still cleans up.
  private func undo(_ error: any Error, id: UUID, snapshot: String?) async throws -> Never {
    let name = name(of: id)
    let leftover = await Task { () -> [String] in
      // In another org, both would read as not found and count as removed.
      do { try await self.checkOrg() } catch {
        return ([name] + (snapshot.map { [$0] } ?? [])).map {
          "\($0) not removed: \(error.localizedDescription)"
        }
      }
      var left: [String] = []
      if let failure = await self.remove(machine: name) { left.append(failure) }
      if let snapshot, let failure = await self.remove(snapshot: snapshot) { left.append(failure) }
      return left
    }.value
    try? FileManager.default.removeItem(at: hostDirectory(id))
    let error =
      (error as? CLIFailure).map { HostDriverError.provisioning($0.localizedDescription) }
      ?? error
    guard !leftover.isEmpty else { throw error }
    throw HostDriverError.leftBehind(cause: error.localizedDescription, leftover: leftover)
  }

  /// Nil once the machine is gone, whether this removed it or it was never there.
  private func remove(machine name: String) async -> String? {
    do {
      _ = try await cli(["machine", "remove", name, "-y"])
      return nil
    } catch let failure as CLIFailure where failure.notFound {
      return await goneUnlessOrgChanged(name)
    } catch { return "machine \(name): \(error.localizedDescription)" }
  }

  private func remove(snapshot name: String) async -> String? {
    do {
      _ = try await cli(["snapshots", "remove", name, "-y"])
      return nil
    } catch let failure as CLIFailure where failure.notFound {
      return await goneUnlessOrgChanged(name)
    } catch { return "snapshot \(name): \(error.localizedDescription)" }
  }

  /// "Not found" means gone only in this driver's org: one switched to since the last check would
  /// say the same of a machine still running there.
  private func goneUnlessOrgChanged(_ name: String) async -> String? {
    do {
      try await checkOrg()
      return nil
    } catch { return "\(name) not removed: \(error.localizedDescription)" }
  }

  /// boxd's own readiness signal is not one: a restore can report `"boot": "timeout"` for a
  /// machine that works (Phase 0, item 6). So each wait asks the machine itself, over ssh.
  private func awaitHostname(of id: UUID) async throws {
    try await poll(id, "test \"$(hostname)\" = \(PosixShell.quoted(name(of: id)))", tries: 50) {
      "\(self.name(of: id)) never took its name: \($0)"
    }
  }

  /// Until the identity unit has run on this machine, its marker names another or none. With
  /// `rebootedFrom`, it also waits out the reboot: the boot must be a new one.
  private func awaitIdentity(of id: UUID, rebootedFrom boot: String? = nil) async throws {
    let name = PosixShell.quoted(name(of: id))
    try await poll(
      id,
      "test \"$(cat /etc/workroom-identity 2>/dev/null)\" = \(name)"
        + " && test \"$(hostname)\" = \(name)"
        // A failed read is empty, which differs from any boot_id, so it must not pass as new.
        + (boot.map {
          " && boot=$(cat /proc/sys/kernel/random/boot_id) && test -n \"$boot\""
            + " && test \"$boot\" != \(PosixShell.quoted($0))"
        } ?? ""),
      tries: 150
    ) { "\(self.name(of: id)) never minted its identity: \($0)" }
  }

  private func bootID(of id: UUID) async throws -> String {
    let (status, output) = try await exec(
      "cat /proc/sys/kernel/random/boot_id", on: .remote(id)
    ).communicate(nil, timeout: 30)
    // The whole output must be the UUID: it carries stderr too, and a warning in it would make
    // an unchanged boot_id compare as a new one.
    let boot = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard status == 0, UUID(uuidString: boot) != nil else {
      throw HostDriverError.provisioning("reading \(name(of: id))'s boot_id failed: \(output)")
    }
    return boot
  }

  /// Until the supervisor's agent answers on its socket. A base that was never given an agent
  /// hands none on, and there is nothing to wait for: the bootstrap installs one and waits itself.
  private func awaitAgent(of id: UUID) async throws {
    let socket = configuration.agentSocket
    let binary = PosixShell.quoted(AgentBootstrap.binary(besideSocket: socket))
    try await poll(
      id,
      "test ! -e \(binary) || \(binary) list --socket \(PosixShell.quoted(socket)) > /dev/null",
      tries: 75
    ) { "\(self.name(of: id))'s agent never answered: \($0)" }
  }

  /// Refuses to act while boxd's active org or signed-in account is not this driver's
  /// (`Configuration.org`, `Configuration.account`).
  private func checkOrg() async throws {
    let account = try await signedIn()
    if let expected = configuration.account, account.userID != expected {
      throw HostDriverError.invalidConfiguration(
        "boxd is signed in to another account than the one this workroom's machines are in; sign"
          + " back in to that account with `boxd auth login`")
    }
    guard account.activeOrg == configuration.org else {
      throw HostDriverError.invalidConfiguration(
        "boxd's active org is \(account.activeOrg ?? "your own"), but this workroom's machines are"
          + " in \(configuration.org ?? "your own"); switch back with `boxd auth switch`")
    }
  }

  /// The signed-in account, as `boxd auth --json` reports it. Throws, naming `boxd auth login`,
  /// when nobody is signed in.
  func signedIn() async throws -> Account {
    do {
      return try decode(Account.self, await cli(["auth"]), "the signed-in account")
    } catch let failure as CLIFailure {
      throw HostDriverError.provisioning(
        "\(failure.localizedDescription). Sign in with `boxd auth login`.")
    }
  }

  private func poll(
    _ id: UUID, _ check: String, tries: Int, failure: (String) -> String
  ) async throws {
    var last = ""
    for _ in 0..<tries {
      // A machine mid-reboot refuses, or holds the connection: neither is the answer, but the
      // last one is what the failure says.
      do {
        let (status, output) = try await exec(check, on: .remote(id)).communicate(nil, timeout: 20)
        if status == 0 { return }
        last = output
      } catch is CancellationError {
        throw CancellationError()
      } catch { last = error.localizedDescription }
      try await Task.sleep(for: .milliseconds(400))
    }
    throw HostDriverError.provisioning(failure(last))
  }

  // MARK: The CLI

  /// A CLI command that failed, with the CLI's own `error:` line. Never thrown out of the driver:
  /// `undo` and the callers below turn it into a `HostDriverError`.
  private struct CLIFailure: Error, LocalizedError {
    let command: String
    let said: String
    var notFound: Bool { BoxdHostDriver.isNotFound(said) }
    var errorDescription: String? { "boxd \(command): \(said)" }
  }

  /// `auth --json`, as far as the driver reads it.
  struct Account: Decodable, Equatable {
    let activeOrg: String?
    let userID: String?
    enum CodingKeys: String, CodingKey {
      case activeOrg = "active_org"
      case userID = "user_id"
    }
  }

  /// `machine get --json`, as far as the driver reads it.
  struct Machine: Decodable {
    /// `standalone`, `fork/<name>` or `snapshot/<name>:<version>`.
    let source: String
    /// `running`, `standby` (suspended; `get` normalises the raw `suspended`), `hibernated`,
    /// `stopped`, and others in passing (boxd CLI docs).
    var status: String? = nil
  }

  /// Whether `host` is asleep, from boxd's own record, without reaching the machine: an ssh login
  /// would wake it (#356). Nil when boxd can't say (no CLI, signed out, offline), which a caller
  /// must not take for either answer.
  func isAsleep(_ host: HostID) async -> Bool? {
    guard case .remote(let id) = host,
      let machine = try? decode(Machine.self, await cli(["machine", "get", name(of: id)]), "")
    else { return nil }
    return Self.asleepStatuses.contains(machine.status ?? "")
  }

  /// The statuses a connection would wake from: suspended and hibernated.
  static let asleepStatuses: Set<String> = ["standby", "hibernated"]

  private func decode<T: Decodable>(_ type: T.Type, _ output: String, _ name: String) throws -> T {
    do {
      return try JSONDecoder().decode(T.self, from: Data(output.utf8))
    } catch {
      throw HostDriverError.provisioning("boxd said something unreadable about \(name): \(output)")
    }
  }

  /// One CLI command with `--json`, and its stdout. A failure says the CLI's own `error:` line,
  /// without the update notice it prints to stderr besides.
  private func cli(_ arguments: [String], timeout: TimeInterval = 120) async throws -> String {
    let result = await runner.run(
      configuration.cli.path, arguments + ["--json"], in: NSHomeDirectory(), timeout: timeout)
    // The runner kills the CLI when the task is cancelled, and that reads as a failure.
    try Task.checkCancellation()
    guard result.ok else {
      let said =
        Self.errorLine(result.stderr)
        ?? (result.timedOut ? "timed out after \(Int(timeout))s" : "exited \(result.exitCode)")
      throw CLIFailure(command: arguments.prefix(2).joined(separator: " "), said: said)
    }
    return result.stdout
  }

  static func errorLine(_ stderr: String) -> String? {
    stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .first { $0.hasPrefix("error:") }
  }

  /// The CLI's answers for a machine or snapshot that does not exist: `error: VM '<name>' not
  /// found` and `error: snapshot not found` (measured). Matched whole, so a transport failure
  /// that happens to say "not found" is never taken for a removal.
  static func isNotFound(_ said: String) -> Bool {
    said == "error: snapshot not found"
      || (said.hasPrefix("error: VM '") && said.hasSuffix("' not found"))
  }

  static func setupScript() throws -> String {
    guard
      let url = Bundle.main.url(
        forResource: "boxd", withExtension: "sh", subdirectory: "host-setup")
    else { throw HostDriverError.invalidConfiguration("this build has no host-setup/boxd.sh") }
    return try String(contentsOf: url, encoding: .utf8)
  }

  // MARK: ssh

  /// The machine's ssh details, from the CLI's blocks in the user's ssh files.
  private func ssh(_ id: UUID) throws -> ContainerHostDriver.Host {
    let name = name(of: id)
    let config = (try? String(contentsOf: configuration.sshConfig, encoding: .utf8)) ?? ""
    let known = (try? String(contentsOf: configuration.knownHosts, encoding: .utf8)) ?? ""
    guard let details = SSHDetails(machine: name, sshConfig: config, knownHosts: known) else {
      throw HostDriverError.invalidConfiguration(
        "boxd has written no ssh details for \(name); `boxd machine list` refreshes them")
    }
    return ContainerHostDriver.Host(
      address: details.hostName, port: details.port, user: details.user,
      identityFile: details.identityFile, hostKey: details.hostKey,
      agentSocket: configuration.agentSocket)
  }

  func openStream(to host: HostID) async throws -> HostStream {
    let id = try id(of: host)
    let target = try ssh(id)
    return try ContainerHostDriver.exec(
      ContainerHostDriver.relayCommand(binary: target.agentBinary, socket: target.agentSocket),
      on: target, in: hostDirectory(id), purpose: .connection)
  }

  func exec(_ command: String, on host: HostID) async throws -> HostStream {
    let id = try id(of: host)
    return try ContainerHostDriver.exec(
      command, on: try ssh(id), in: hostDirectory(id), purpose: .exchange)
  }

  func attachCommand(
    to host: HostID, session: UUID, workingDirectory: String, restored: Bool,
    metadata: [(key: String, value: String)]
  ) throws -> String {
    let id = try id(of: host)
    return try ContainerHostDriver.attachCommand(
      to: try ssh(id), in: hostDirectory(id), session: session,
      workingDirectory: workingDirectory, restored: restored, metadata: metadata)
  }

  func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool {
    guard case .remote(let id) = host else { return false }
    return ContainerHostDriver.refusedLastAttach(of: session, in: hostDirectory(id))
  }
}

/// One boxd machine's ssh details, read from the blocks the CLI manages in the user's ssh files
/// (`# BEGIN boxd` … `# END boxd` in `~/.ssh/config`, `# BEGIN boxd-hosts` … in
/// `~/.ssh/known_hosts`), and from nowhere else in them: a `Host *` of the user's own adds an
/// `IdentityFile` ahead of boxd's, and `ssh -G` would hand back both.
struct SSHDetails: Equatable {
  let hostName: String
  let port: Int
  let user: String
  let identityFile: String
  /// `<type> <base64>`.
  let hostKey: String

  init?(machine: String, sshConfig: String, knownHosts: String) {
    var values: [String: String] = [:]
    var inStanza = false
    for line in Self.block("boxd", in: sshConfig) {
      let (keyword, value) = Self.split(line)
      if keyword == "host" {
        inStanza = value.split(separator: " ").contains { $0 == "\(machine).boxd" }
      } else if inStanza, values[keyword] == nil {
        values[keyword] = value
      }
    }
    guard let hostName = values["hostname"], let port = Int(values["port"] ?? "22"),
      let user = values["user"], let identityFile = values["identityfile"]
    else { return nil }
    let name = port == 22 ? hostName : "[\(hostName)]:\(port)"
    guard
      let key = Self.block("boxd-hosts", in: knownHosts)
        .map({ $0.split(separator: " ") })
        .first(where: { $0.count >= 3 && $0[0] == name })
    else { return nil }
    self.hostName = hostName
    self.port = port
    self.user = user
    self.identityFile = identityFile
    self.hostKey = "\(key[1]) \(key[2])"
  }

  /// The lines between `# BEGIN <marker>` and `# END <marker>`, trimmed, without blanks or
  /// comments.
  private static func block(_ marker: String, in text: String) -> [String] {
    var lines: [String] = []
    var inside = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = line.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("# BEGIN \(marker) ") || line == "# BEGIN \(marker)" {
        inside = true
      } else if line.hasPrefix("# END \(marker) ") || line == "# END \(marker)" {
        inside = false
      } else if inside, !line.isEmpty, !line.hasPrefix("#") {
        lines.append(line)
      }
    }
    return lines
  }

  /// `Keyword value`, the keyword lowercased and a quoted value unquoted.
  private static func split(_ line: String) -> (String, String) {
    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
    var value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
    if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
      value = String(value.dropFirst().dropLast())
    }
    return (parts[0].lowercased(), value)
  }
}

import AgentConnection
import Foundation
import WorkroomSystem
import WorkroomVCS
import os

/// The first real provider driver (#256): boxd.sh machines, driven through the `boxd` CLI and
/// reached over ssh. Each workroom is a fresh machine of its own: there is no base to derive from.
///
/// - **The CLI, not an SDK.** Every call is `boxd … --json`, its JSON read here into the driver's
///   own result. The CLI also writes each machine's ssh stanza into `~/.ssh/config` and its host
///   key into `~/.ssh/known_hosts`, inside blocks it manages; the driver reads the machine's
///   address, port, user, key and host key from those blocks only (`SSHDetails`), and writes its
///   own locked-down configuration from them (`SSHTransport.writeConfiguration`), so
///   nothing else in the user's ssh config applies. The host key is boxd's gateway's, the same
///   for every machine, which is why a machine's own regenerated keys never trip it (Phase 0,
///   item 6). The VM's sshd is not what answers: boxd terminates ssh at the gateway.
/// - **A host** is a fresh machine with `Resources/host-setup/systemd.sh` run on it: the identity
///   unit and the agent's supervisor, both systemd units (see the script). The identity unit is
///   load-bearing here: every fresh boxd machine boots with the image's one machine-id and ssh
///   host key (measured, 2026-10-10).
/// - **Names.** A host is the machine `<prefix>-<host id>`. A failed step removes by name, since
///   the CLI's own output may never have arrived, and a driver made after a relaunch reaches a
///   recorded host by its ID alone.
///
/// Everything the agent keeps is on the machine's home disk (`agentSocket`), so a machine that is
/// stopped and started keeps its binary and its screens.
public final class BoxdHostDriver: HostTerminalDriver, @unchecked Sendable {
  public struct Configuration: Sendable {
    /// The `boxd` CLI, signed in.
    public var cli: URL
    /// What every machine this driver makes is named after.
    public var prefix: String
    /// The boxd org this driver's machines belong to, as `boxd auth --json` reports the active
    /// one: nil for the account's own. The CLI acts in whichever org is active, and its own org
    /// cannot be named with `--org` (measured: "you are not a member of org …"), so the driver
    /// checks the active org instead of choosing it, and refuses to act in another: there, its
    /// machines read as "not found", which `destroy` would take for gone and leave running.
    /// Whoever records a host records this beside it.
    public var org: String?
    /// The boxd account this driver's machines belong to, `boxd auth --json`'s `user_id`, or nil
    /// to accept any (#356). Every personal account's org is nil, so after a switch to another
    /// account the org check alone passes, and a machine of the first account reads as "not
    /// found", which `destroy` would take for gone. Whoever records a host records this beside it.
    public var account: String?
    /// The agent's socket on every host. On the home disk, never the tmpfs `/run`: the agent's
    /// binary is installed beside it, and a stopped machine would lose it.
    public var agentSocket: String

    /// Where the supervisor has the agent keep each session's last screen (#232).
    public var screens: String
    /// The files the CLI writes each machine's ssh stanza and host key into.
    public var sshConfig: URL
    public var knownHosts: URL
    /// The home the CLI runs with, which holds its sign-in (`credentialsFile`). The user's own,
    /// except in the fresh-user harness (`make app-run-boxd-fresh`).
    public var home: URL

    public init(
      cli: URL, prefix: String = "workroom", org: String? = nil, account: String? = nil,
      agentSocket: String = "\(BoxdHostDriver.stateDirectory)/agent/agent.sock",
      screens: String = "\(BoxdHostDriver.stateDirectory)/screens",
      sshConfig: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        ".ssh/config"),
      knownHosts: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        ".ssh/known_hosts"),
      home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
      self.cli = cli
      self.prefix = prefix
      self.org = org
      self.account = account
      self.agentSocket = agentSocket
      self.screens = screens
      self.sshConfig = sshConfig
      self.knownHosts = knownHosts
      self.home = home
    }
  }

  /// The host descriptor's `driver` for this provider's hosts.
  public static let driverName = "boxd"
  /// The user every boxd machine logs in as, whose home holds the agent's state and the clone.
  public static let user = "boxd"
  /// Where Workroom keeps its state on a boxd machine: the agent's socket and the sessions' screens.
  public static let stateDirectory = "/home/\(user)/.local/state/workroom"

  public let configuration: Configuration
  public var agentSocket: String { configuration.agentSocket }
  /// Where each host's `ssh_config` and `known_hosts` are written.
  public let directory: URL
  private let runner: any StatusCommandRunning

  public init(
    configuration: Configuration, directory: URL,
    runner: any StatusCommandRunning = StatusCommandRunner()
  ) {
    self.configuration = configuration
    self.directory = directory
    self.runner = runner
  }

  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "BoxdHostDriver")

  public func name(of id: UUID) -> String {
    "\(configuration.prefix)-\(id.uuidString.lowercased())"
  }

  private func id(of host: HostID) throws -> UUID {
    guard case .remote(let id) = host else { throw HostDriverError.unknownHost(host) }
    return id
  }

  private func hostDirectory(_ id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString)
  }

  // MARK: Provisioning

  /// A fresh machine, set up as a workroom's host: the identity unit has minted its identity and
  /// the supervisor is waiting for an agent. A machine that gets no further is removed.
  public func create() async throws -> HostID {
    try await checkOrg()
    let id = UUID()
    let name = name(of: id)
    try markPending(id)
    do {
      ProvisioningProgress.reportStep?(.machine)
      _ = try await cli(["machine", "new", name])
      ProvisioningProgress.reportStep?(.setup)
      let script = try HostSetup.systemdScript()
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
      try await awaitIdentity(of: id, named: name)
      return .remote(id)
    } catch {
      try await undo(error, id: id)
    }
  }

  /// Removes the machine. One already gone counts as removed, so a caller retrying after a later
  /// step of its own failed gets past the destroy it already did.
  public func destroy(_ host: HostID) async throws {
    let id = try id(of: host)
    try await checkOrg()
    if let failure = await remove(machine: name(of: id)) {
      try Task.checkCancellation()
      throw HostDriverError.provisioning(failure)
    }
    // An older build's derive that failed or was quit partway can leave its snapshot, named as its
    // machine is (#356), with the base's disk in it: it goes too, while such builds' pending
    // machines and failed records are still about. Best-effort: the machine is gone, which is what
    // a delete reports, so a failure here is logged rather than made to read as a running box.
    // Usually "not found", which this org (just checked) makes final, so no second org check.
    do {
      _ = try await cli(["snapshots", "remove", name(of: id), "-y"])
    } catch let failure as CLIFailure where failure.notFound {
    } catch is CancellationError {
      // A cancelled delete isn't done: it fails, so the record of the snapshot stays.
      throw CancellationError()
    } catch {
      Self.logger.error(
        "snapshot \(self.name(of: id), privacy: .public) not removed: \(error.localizedDescription, privacy: .public)"
      )
    }
    PendingMachines.forget([id], in: directory)
    try? FileManager.default.removeItem(at: hostDirectory(id))
  }

  /// Names machine `id` as pending before the call that makes it, so a crash before config records
  /// its host still leaves it for the sweep (#373).
  private func markPending(_ id: UUID) throws {
    try PendingMachines.add(
      .init(
        id: id, driver: Self.driverName, org: configuration.org,
        account: configuration.account), in: directory)
  }

  /// Removes what a failed `create` made, then rethrows `error`, or says what is still there. In a
  /// task of its own, so a cancelled caller still cleans up.
  private func undo(_ error: any Error, id: UUID) async throws -> Never {
    let name = name(of: id)
    let leftover = await Task { () -> [String] in
      // In another org, it would read as not found and count as removed.
      do { try await self.checkOrg() } catch {
        return ["\(name) not removed: \(error.localizedDescription)"]
      }
      return await self.remove(machine: name).map { [$0] } ?? []
    }.value
    try? FileManager.default.removeItem(at: hostDirectory(id))
    let error =
      (error as? CLIFailure).map { HostDriverError.provisioning($0.localizedDescription) }
      ?? error
    guard !leftover.isEmpty else {
      PendingMachines.forget([id], in: directory)
      throw error
    }
    throw HostDriverError.leftBehind(
      cause: error.localizedDescription, leftover: leftover, host: .remote(id))
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

  /// "Not found" means gone only in this driver's org: one switched to since the last check would
  /// say the same of a machine still running there.
  private func goneUnlessOrgChanged(_ name: String) async -> String? {
    do {
      try await checkOrg()
      return nil
    } catch { return "\(name) not removed: \(error.localizedDescription)" }
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
  public func signedIn() async throws -> Account {
    do {
      return try decode(Account.self, await cli(["auth"]), "the signed-in account")
    } catch let failure as CLIFailure {
      let advice = failure.said == Self.unreadableSignIn ? "" : " Sign in with `boxd auth login`."
      throw HostDriverError.provisioning("\(failure.localizedDescription).\(advice)")
    }
  }

  // MARK: The CLI

  /// A CLI command that failed, with the CLI's own `error:` line. Never thrown out of the driver:
  /// `undo` and the callers below turn it into a `HostDriverError`.
  private struct CLIFailure: Error, LocalizedError {
    let command: String
    let said: String
    /// The CLI ran and answered with its own `error:` line, as opposed to timing out or failing to
    /// run at all.
    var answered = false
    var notFound: Bool { BoxdHostDriver.isNotFound(said) }
    /// boxd refused the token: it expired or was revoked (measured: "… is invalid or expired …"
    /// from `auth`, "invalid or expired session" from `manage integrations list`).
    var expired: Bool { said.contains("invalid or expired") }
    var errorDescription: String? { "boxd \(command): \(said)" }
  }

  /// `auth --json`, as far as the driver reads it.
  public struct Account: Decodable, Equatable, Sendable {
    public let activeOrg: String?
    public let userID: String?
    public var displayName: String? = nil
    public var orgs: [Org]? = nil
    public enum CodingKeys: String, CodingKey {
      case activeOrg = "active_org"
      case userID = "user_id"
      case displayName = "display_name"
      case orgs
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      activeOrg = try container.decodeIfPresent(String.self, forKey: .activeOrg)
      userID = try container.decodeIfPresent(String.self, forKey: .userID)
      // Only the setup sheet shows these: a shape boxd changes them to must not fail every create
      // and delete, which decode this too (`signedIn()`).
      displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
      orgs = try? container.decodeIfPresent([Org].self, forKey: .orgs)
    }

    public struct Org: Decodable, Equatable, Sendable {
      public let name: String?
      public let active: Bool?
    }

    /// The active org's name (`orgs[].active`), as the setup sheet shows the signed-in account.
    public var activeOrgName: String? { orgs?.first { $0.active == true }?.name }

    /// The account's id, which a new host records (#356): without it, deleting the host would skip
    /// the check that the same account is signed in, and another account's "not found" would read
    /// as gone.
    public func requiredUserID() throws -> String {
      guard let userID else {
        throw HostDriverError.provisioning(
          "boxd didn't say which account is signed in. Sign in again with `boxd auth login`.")
      }
      return userID
    }
  }

  /// `machine get --json`, as far as the driver reads it.
  public struct Machine: Decodable {
    /// `running`, `standby` (suspended; `get` normalises the raw `suspended`), `hibernated`,
    /// `stopped`, and others in passing (boxd CLI docs).
    public var status: String? = nil
  }

  /// Whether `host` is asleep, from boxd's own record, without reaching the machine: an ssh login
  /// would wake it (#356). Nil when the CLI could not answer (missing, timed out, output it did not
  /// expect, a machine without a status); `RemoteHosts` takes that as asleep for a background read.
  ///
  /// `gone` when boxd answers that the machine is not found: deleted outside the app, or in an org
  /// that isn't active. Any other error the CLI answers with (signed out, another account) counts
  /// as asleep: the read can't tell, and connecting would wake a box the user may be paying for,
  /// so a background read leaves it alone; opening the workroom still connects.
  public func presence(_ host: HostID) async -> Presence? {
    guard case .remote(let id) = host else { return nil }
    do {
      let output = try await cli(
        ["machine", "get", name(of: id)], timeout: Self.statusTimeout)
      let machine = try decode(Machine.self, output, name(of: id))
      // A reply without a status says nothing either way: taken as awake, it would wake the box.
      guard let status = machine.status else { return nil }
      return Self.asleepStatuses.contains(status) ? .asleep : .awake
    } catch let failure as CLIFailure {
      if failure.notFound { return .gone }
      return failure.answered ? .asleep : nil
    } catch { return nil }
  }

  /// What boxd says of a machine, for a background read (#356).
  public enum Presence: Equatable, Sendable { case awake, asleep, gone }

  /// How long a status read (`presence`) waits for the CLI: a status sweep and a
  /// connect wait on it, so a hung CLI must not hold them for the CLI's usual 120 s.
  public static let statusTimeout: TimeInterval = 10

  /// The statuses a connection would wake from: suspended and hibernated.
  public static let asleepStatuses: Set<String> = ["standby", "hibernated"]

  private func decode<T: Decodable>(_ type: T.Type, _ output: String, _ name: String) throws -> T {
    do {
      return try JSONDecoder().decode(T.self, from: Data(output.utf8))
    } catch {
      throw HostDriverError.provisioning("boxd said something unreadable about \(name): \(output)")
    }
  }

  /// One CLI command with `--json`, and its stdout. A failure says the CLI's own `error:` line,
  /// without the update notice it prints to stderr besides.
  ///
  /// Never runs boxd without a sign-in: signed out, every boxd command that needs an account
  /// starts the browser sign-in and waits there, with or without a terminal (measured, boxd 0.2.23).
  /// With one, boxd runs on that saved sign-in, which a token boxd refuses fails cleanly ("your
  /// saved login token is invalid or expired", no browser; measured, boxd 0.2.25). Never with the
  /// token as `BOXD_TOKEN`: boxd takes that for an API key and then writes no ssh stanza for the
  /// machines it makes (measured), so the runner strips an inherited one too.
  private func cli(_ arguments: [String], timeout: TimeInterval = 120) async throws -> String {
    let command = arguments.prefix(2).joined(separator: " ")
    switch Self.credential(home: configuration.home) {
    case .token: break
    case .none: throw CLIFailure(command: command, said: "not signed in to boxd", answered: true)
    case .unreadable:
      throw CLIFailure(command: command, said: Self.unreadableSignIn, answered: true)
    }
    let result = await runner.run(
      configuration.cli.path, arguments + ["--json"], in: configuration.home.path,
      timeout: timeout,
      environment: ["HOME": configuration.home.path])
    // The runner kills the CLI when the task is cancelled, and that reads as a failure.
    try Task.checkCancellation()
    guard result.ok else {
      let line = Self.errorLine(result.stderr)
      let said =
        line ?? (result.timedOut ? "timed out after \(Int(timeout))s" : "exited \(result.exitCode)")
      throw CLIFailure(command: command, said: said, answered: line != nil)
    }
    return result.stdout
  }

  // MARK: Sign-in

  /// What boxd is signed in with: the token in `credentialsFile`, read leniently (any JSON object
  /// with a string `token`), since the file is boxd's own and undocumented.
  public enum Credential: Equatable, Sendable {
    case none
    /// There, but not one Workroom can read. boxd starts its sign-in for a truncated or unfamiliar
    /// file too (measured), so this counts as signed out.
    case unreadable
    case token(String)
  }

  /// Why boxd wasn't run with a sign-in Workroom can't read. A truncated file is fixed by signing in
  /// again; a format boxd has changed to needs a Workroom that reads it.
  static let unreadableSignIn =
    "Workroom can't read boxd's sign-in. If signing in again with `boxd auth login` doesn't fix "
    + "it, boxd has changed how it keeps it and Workroom needs an update"

  /// Where boxd keeps its sign-in, under the home it runs with.
  public static func credentialsFile(home: URL) -> URL {
    home.appendingPathComponent("Library/Application Support/boxd/credentials.json")
  }

  public static func credential(home: URL) -> Credential {
    let file = credentialsFile(home: home)
    guard let data = try? Data(contentsOf: file) else {
      return FileManager.default.fileExists(atPath: file.path) ? .unreadable : .none
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let token = object["token"] as? String, !token.isEmpty
    else { return .unreadable }
    return .token(token)
  }

  /// Who boxd is signed in as, for the setup sheet, without ever starting boxd's own sign-in.
  public enum AccountState: Equatable, Sendable {
    /// Nobody, with why when there is more to say than that.
    case signedOut(String?)
    case signedIn(Account)
    /// boxd's sign-in is there but Workroom can't read it, so boxd isn't asked: it would start its
    /// own sign-in.
    case unreadable
    /// boxd couldn't be asked, or its answer couldn't be read: the create goes ahead and boxd's
    /// own error, if any, says what's wrong.
    case unknown(String)
  }

  /// How long a setup check waits for the CLI, as exe.dev's do. A timeout counts as unknown.
  public static let checkTimeout: TimeInterval = 60

  public func account() async -> AccountState {
    switch Self.credential(home: configuration.home) {
    case .none: return .signedOut(nil)
    case .unreadable: return .unreadable
    case .token: break
    }
    let output: String
    do {
      output = try await cli(["auth"], timeout: Self.checkTimeout)
    } catch let failure as CLIFailure {
      if failure.expired { return .signedOut("Your boxd sign-in has expired.") }
      return .unknown(failure.localizedDescription)
    } catch {
      return .unknown(error.localizedDescription)
    }
    guard let account = try? JSONDecoder().decode(Account.self, from: Data(output.utf8)) else {
      return .unknown("boxd said something unreadable about the signed-in account")
    }
    return .signedIn(account)
  }

  /// Whether boxd's git integration, the user's own GitHub sign-in that `git` and `gh` use on their
  /// machines, is connected.
  public enum GitHubState: Equatable, Sendable {
    case connected
    case notConnected
    case unknown(String)
  }

  public func gitHub() async -> GitHubState {
    struct List: Decodable {
      struct Integration: Decodable {
        let id: String?
        let `class`: String?
        let connected: Bool?
      }
      let integrations: [Integration]
    }
    do {
      let output = try await cli(["manage", "integrations", "list"], timeout: Self.checkTimeout)
      guard let list = try? JSONDecoder().decode(List.self, from: Data(output.utf8)) else {
        return .unknown("boxd said something unreadable about its integrations")
      }
      // The org's shared connection (`class: shared`) serves only shared machines.
      let connected = list.integrations.contains {
        $0.id == "git" && $0.class == "private" && $0.connected == true
      }
      return connected ? .connected : .notConnected
    } catch {
      return .unknown(error.localizedDescription)
    }
  }

  /// Starts boxd's sign-in, which opens the browser and waits for the user there.
  public func signIn() throws -> ClickedCommand {
    try ClickedCommand(configuration.cli, ["auth", "login"], home: configuration.home)
  }

  /// Starts connecting boxd's git integration, which opens GitHub in the browser and waits.
  public func connectGitHub() throws -> ClickedCommand {
    try ClickedCommand(
      configuration.cli, ["manage", "integrations", "connect", "git"], home: configuration.home)
  }

  /// Runs boxd's own installer, which puts `boxd` in `~/.local/bin` under `home`. Without a
  /// terminal it installs only the binary: the PATH line, completions and agent skills it offers
  /// are asked about on `/dev/tty`, and with none it installs none. Never with `-y`, which would
  /// install them all. It checks the download's sha256 and moves it into place whole, so a
  /// cancelled install leaves no `boxd` behind.
  public static func install(home: URL) throws -> ClickedCommand {
    try ClickedCommand(
      URL(fileURLWithPath: "/bin/sh"), ["-c", "curl -fsSL \(installer) | sh"], home: home)
  }

  public static let installer = "https://boxd.sh/downloads/install.sh"

  /// A command the user started with a click: boxd's sign-in, its GitHub connection, or its
  /// installer. It may wait in the browser, so it runs until it exits or is cancelled. Its
  /// environment is the app's, with `home` as `HOME` and no inherited `BOXD_TOKEN`, so boxd signs
  /// in and reads its sign-in where `credential(home:)` looks.
  public final class ClickedCommand: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var heard = Data()

    public init(_ executable: URL, _ arguments: [String], home: URL) throws {
      var environment = ProcessInfo.processInfo.environment
      environment["HOME"] = home.path
      environment["PATH"] = ShellEnvironment.path()
      environment.removeValue(forKey: "BOXD_TOKEN")
      process.executableURL = executable
      process.arguments = arguments
      process.environment = environment
      process.currentDirectoryURL = home
      // No terminal: boxd and its installer then ask nothing (see `install`).
      process.standardInput = FileHandle.nullDevice
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      try process.run()
      let reading = pipe.fileHandleForReading
      DispatchQueue.global().async { [weak self] in
        while let chunk = try? reading.read(upToCount: 4096), !chunk.isEmpty {
          guard let self else { return }
          self.lock.withLock { self.heard.append(chunk) }
        }
      }
    }

    deinit { cancel() }

    /// Everything it has printed so far.
    public var output: String { lock.withLock { String(decoding: heard, as: UTF8.self) } }

    /// The first web address it printed, such as boxd's sign-in page, for the sheet to offer again.
    /// Not the installer's: an out-of-date boxd prints its update notice, which names it, first
    /// (measured, boxd 0.2.23).
    public var link: URL? {
      output.split(whereSeparator: \.isWhitespace).lazy
        .first { $0.hasPrefix("https://") && $0 != BoxdHostDriver.installer }
        .flatMap { URL(string: String($0)) }
    }

    /// Its exit status, once it ends.
    public func wait() async -> Int32 {
      let process = self.process
      return await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
          process.waitUntilExit()
          continuation.resume(returning: process.terminationStatus)
        }
      }
    }

    /// Its last line of output, for a failure to say.
    public var lastLine: String? {
      output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .last { !$0.isEmpty }
    }

    public func cancel() {
      if process.isRunning { ProcessTree.killTree(process.processIdentifier) }
    }
  }

  public static func errorLine(_ stderr: String) -> String? {
    stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .first { $0.hasPrefix("error:") }
  }

  /// The CLI's answers for a machine or snapshot that does not exist: `error: VM '<name>' not
  /// found` and `error: snapshot not found` (measured). Matched whole, so a transport failure
  /// that happens to say "not found" is never taken for a removal.
  public static func isNotFound(_ said: String) -> Bool {
    said == "error: snapshot not found"
      || (said.hasPrefix("error: VM '") && said.hasSuffix("' not found"))
  }

  // MARK: ssh

  /// The machine's ssh details, from the CLI's blocks in the user's ssh files.
  private func ssh(_ id: UUID) throws -> SSHTransport.Host {
    let name = name(of: id)
    let config = (try? String(contentsOf: configuration.sshConfig, encoding: .utf8)) ?? ""
    let known = (try? String(contentsOf: configuration.knownHosts, encoding: .utf8)) ?? ""
    guard let details = SSHDetails(machine: name, sshConfig: config, knownHosts: known) else {
      throw HostDriverError.invalidConfiguration(
        "boxd has written no ssh details for \(name); `boxd machine list` refreshes them")
    }
    return SSHTransport.Host(
      address: details.hostName, port: details.port, user: details.user,
      identityFile: details.identityFile, hostKey: details.hostKey,
      agentSocket: configuration.agentSocket)
  }

  public func openStream(to host: HostID) async throws -> HostStream {
    let id = try id(of: host)
    let target = try ssh(id)
    return try SSHTransport.exec(
      SSHTransport.relayCommand(binary: target.agentBinary, socket: target.agentSocket),
      on: target, in: hostDirectory(id), purpose: .connection)
  }

  public func exec(_ command: String, on host: HostID) async throws -> HostStream {
    let id = try id(of: host)
    return try SSHTransport.exec(
      command, on: try ssh(id), in: hostDirectory(id), purpose: .exchange)
  }

  public func attachCommand(
    to host: HostID, session: UUID, workingDirectory: String, restored: Bool,
    metadata: [(key: String, value: String)]
  ) throws -> String {
    let id = try id(of: host)
    return try SSHTransport.attachCommand(
      to: try ssh(id), in: hostDirectory(id), session: session,
      workingDirectory: workingDirectory, restored: restored, metadata: metadata)
  }

  public func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool {
    guard case .remote(let id) = host else { return false }
    return SSHTransport.refusedLastAttach(of: session, in: hostDirectory(id))
  }

  public func lastAttachLostLink(of session: UUID, on host: HostID) -> Bool {
    guard case .remote(let id) = host else { return false }
    return SSHTransport.lostLinkLastAttach(of: session, in: hostDirectory(id))
  }
}

/// One boxd machine's ssh details, read from the blocks the CLI manages in the user's ssh files
/// (`# BEGIN boxd` … `# END boxd` in `~/.ssh/config`, `# BEGIN boxd-hosts` … in
/// `~/.ssh/known_hosts`), and from nowhere else in them: a `Host *` of the user's own adds an
/// `IdentityFile` ahead of boxd's, and `ssh -G` would hand back both.
public struct SSHDetails: Equatable {
  public let hostName: String
  public let port: Int
  public let user: String
  public let identityFile: String
  /// `<type> <base64>`.
  public let hostKey: String

  public init?(machine: String, sshConfig: String, knownHosts: String) {
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

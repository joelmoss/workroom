import DaemonConnection
import Foundation
import Synchronization
import WorkroomDomain
import WorkroomSystem

/// Railway sandboxes as workroom hosts (ADRs 0071, 0073, 0074; #629): made, read and destroyed
/// through Railway's GraphQL API with the app's own sign-in (`RailwayAPI`), never the `railway`
/// CLI, and reached with the system ssh through Railway's relay.
///
/// - **A host** is a sandbox in this Mac's environment of the `Workroom` project
///   (`Configuration.environmentID`), made with its idle timeout off, so it lasts until its
///   workroom is deleted. Then `Resources/host-setup/railway.sh` runs on it as root: a sandbox has
///   no systemd and an empty machine id, so it gets Workroom's identity file, and the daemon is
///   started from an ssh login, which it outlives (`startsDaemon`).
/// - **The relay.** `ssh.railway.com`, user `sbx:<environment>:<sandbox>`, with a key Workroom
///   makes for this Mac and registers on the account. The relay's host key ships in the app
///   (`relayHostKey`; Railway publishes none) and is the only one any login trusts, whatever a
///   record or an older build's pin says: a relay presenting another key fails ssh's own check,
///   a refusal the pane stops on, until an update of Workroom ships the new key.
/// - **Records.** A sandbox has no name or label, so the record (`RailwayHostRecord`, through
///   `HostRecording`) is all that ties it to its workroom; a driver made after a relaunch reaches
///   only the hosts it adopted.
/// - **Presence** is the sandbox's status, read without a login: it never sleeps.
/// - **Git** (ADR 0072): Railway has no git integration, so the host holds the Mac's `gh` token in
///   `gitHubTokenPath`, written over stdin at create and on every connect when it changed
///   (`GitHubTokenCarrying`); `railway-github.sh` sets the credential helper and the rewrites.
/// - **Host options** (#633): region, size and host image (Railway's default, or a checkpoint in
///   this Mac's environment), in `RailwayHostOptions.swift`. A host made from a checkpoint has the
///   source's checkout and token file cleared before its clone (`CheckoutClearingDriver`).
///
/// What a create runs on its host (the identity file and the readiness of the relay) goes through
/// the command runner, so tests stub it; a host's later exchanges (`exec`, `openStream`) are
/// `HostStream`s over ssh, as on every ssh host.
public final class RailwayHostDriver: HostTerminalDriver, OptionedProvisioningDriver,
  HostPresenceReporting, HostRecording, GitHubTokenCarrying, HostOptionsReading,
  CheckoutClearingDriver, UnrecordedHostSweeping, @unchecked Sendable
{
  public struct Configuration: Sendable {
    /// This Mac's environment in the `Workroom` project, where every sandbox it makes goes.
    public var environmentID: String
    public var projectID: String?
    /// The workspace the project is in, whose plan caps a host's size (#633); nil reads no plan.
    public var workspaceID: String?
    /// This Mac's folder for its Railway ssh key (`id_ed25519`) and create ledger: one for
    /// Release and Nightly, a Dev build's own.
    public var keys: URL
    /// The relay every login goes through.
    public var relayHost: String
    /// The name the Mac's key is registered under on the account.
    public var keyName: String
    /// The daemon's socket, beside which it keeps its screens and layouts (`DaemonBootstrap`).
    public var daemonSocket: String
    public var hostSetup: HostSetup
    /// How long between reads of a new sandbox's status, and how many before giving up.
    public var pollInterval: Duration
    public var readyTries: Int
    /// The Mac's `gh` token for github.com, which each host's git uses in the user's name (ADR
    /// 0072): written at create and rewritten on a connect when it changed. Nil gives a host no
    /// GitHub credentials.
    public var gitHubToken: (@Sendable () async throws -> String)?

    public init(
      environmentID: String, projectID: String?, workspaceID: String? = nil, keys: URL,
      relayHost: String = RailwayHostDriver.relay,
      keyName: String = "Workroom on \(ProcessInfo.processInfo.hostName)",
      daemonSocket: String = "\(RailwayHostDriver.stateDirectory)/daemon/workroomd.sock",
      hostSetup: HostSetup, pollInterval: Duration = .seconds(2), readyTries: Int = 150,
      gitHubToken: (@Sendable () async throws -> String)? = nil
    ) {
      self.environmentID = environmentID
      self.projectID = projectID
      self.workspaceID = workspaceID
      self.keys = keys
      self.relayHost = relayHost
      self.keyName = keyName
      self.daemonSocket = daemonSocket
      self.hostSetup = hostSetup
      self.pollInterval = pollInterval
      self.readyTries = readyTries
      self.gitHubToken = gitHubToken
    }
  }

  /// The host descriptor's `driver` for this provider's hosts.
  public static let driverName = HostKind.railway.driver
  /// Railway's ssh relay (from its CLI's source, not its docs: ADR 0071).
  public static let relay = "ssh.railway.com"
  /// The relay's host key, `<type> <base64>`, as the live spike of 2026-11-13 read it on every
  /// connection (ADR 0071's amendment): shipped in the app, so the first login is checked as
  /// strongly as the rest. Railway publishes none; a relay presenting another key is refused
  /// until an update of Workroom ships the new one.
  public static let relayHostKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ8X3z81/tuP7CvmK3ZqWgwEvHUR6b04oi2lQJGld2C1"
  /// Every sandbox logs in as root, whose home holds the daemon's state and the clone (spike).
  public static let user = "root"
  public static let stateDirectory = "/root/.local/state/workroom"
  /// The host's copy of the Mac's `gh` token (ADR 0072), readable only by root, its owner. The
  /// git credential helper `railway-github.sh` sets answers github.com from it. Clearing a
  /// checkpoint's checkout must remove it too (#633).
  public static let gitHubTokenPath = "\(stateDirectory)/gh-token"

  public let configuration: Configuration
  public var daemonSocket: String { configuration.daemonSocket }
  /// No supervisor on a sandbox: each connect starts the daemon when nothing listens.
  public var startsDaemon: Bool { true }
  public var hostsSleep: Bool { false }
  /// Where each host's `ssh_config`, `known_hosts` and attach logs are written.
  public let directory: URL
  let api: RailwayAPI
  private let runner: any StatusCommandRunning
  private let hosts = Mutex<[UUID: RailwayHostRecord]>([:])
  /// The ledger intent of each sandbox this driver's creates made that is still on the ledger, by
  /// sandbox id.
  private let intents = Mutex<[String: UUID]>([:])
  /// Hosts whose record names no workspace and whose workspace couldn't be told
  /// (`workspace(of:_:)`): not looked up again this session.
  private let unresolved = Mutex<Set<UUID>>([])
  /// Hosts whose record names no project and whose environment's project Railway wouldn't name
  /// (`project(of:_:)`): not looked up again this session.
  private let unprojected = Mutex<Set<UUID>>([])

  public init(
    configuration: Configuration, api: RailwayAPI, directory: URL,
    runner: any StatusCommandRunning = StatusCommandRunner()
  ) {
    self.configuration = configuration
    self.api = api
    self.directory = directory
    self.runner = runner
  }

  func hostDirectory(_ id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString)
  }

  func record(of host: HostID) throws -> (UUID, RailwayHostRecord) {
    guard case .remote(let id) = host, let record = hosts.withLock({ $0[id] }) else {
      throw HostDriverError.unknownHost(host)
    }
    return (id, record)
  }

  // MARK: Provisioning

  /// A sandbox of Railway's default image, region and size, with its idle timeout off, set up as
  /// a workroom's host. One that gets no further is destroyed.
  public func create() async throws -> HostID { try await create(options: ResolvedHostOptions()) }

  /// A sandbox made with `options` (#633), with its idle timeout off, set up as a workroom's host:
  /// in their region and size, from their checkpoint, which must be in this Mac's environment.
  /// One that gets no further is destroyed.
  public func create(options: ResolvedHostOptions) async throws -> HostID {
    let sandboxOptions = try RailwaySandboxOptions(options)
    let (identity, hostKey, token) = try await ProvisioningProgress.step(
      .account, report: false
    ) {
      if let checkpoint = sandboxOptions.checkpoint {
        try await self.checkHeld(checkpoint: checkpoint)
      }
      // One create at a time makes the key; the rest find it.
      let identity = try await RailwaySerial.shared.run { try await self.macKey() }
      let hostKey = Self.relayHostKey
      // Read before anything is made: a Mac signed out of gh bills no sandbox.
      return (identity, hostKey, try await self.macGitHubToken())
    }
    let sandbox = try await ProvisioningProgress.step(.machine) {
      // Written down before Railway is asked, with where it is asked: the sweep destroys only
      // what the ledger names, in the environment it was made in.
      let intent = try await ledger.begin(
        environmentID: configuration.environmentID, workspaceID: configuration.workspaceID,
        projectID: configuration.projectID)
      let sandbox: String
      let delivery = RailwayDelivery()
      do {
        sandbox = try await api.createSandbox(
          environmentID: configuration.environmentID, options: sandboxOptions, delivery: delivery)
      } catch {
        // Nothing reached Railway (signed out, a refresh that failed, a cancel before sending),
        // or Railway said no (a 4xx), so made nothing. Anything else (the link, a cancel, an
        // answer that couldn't be read, a server error, a 2xx with errors) may have lost the
        // reply to a sandbox that exists: its entry stays for the user (`RailwayLostCreates`).
        if !delivery.mayHaveActed || Self.isRefusal(error) { try? await ledger.drop([intent]) }
        throw error
      }
      // Held from here, so recording, destroying or undoing this host takes its entry off by
      // its intent even when the id never reached the ledger.
      intents.withLock { $0[sandbox] = intent }
      await nameIntent(intent, sandbox: sandbox)
      return sandbox
    }
    let id = UUID()
    let record = RailwayHostRecord(
      projectID: configuration.projectID, environmentID: configuration.environmentID,
      sandboxID: sandbox, hostKey: hostKey, workspaceID: configuration.workspaceID)
    hosts.withLock { $0[id] = record }
    do {
      try await ProvisioningProgress.step(.boot) { try await awaitRunning(record) }
      try await ProvisioningProgress.step(.setup) {
        try await setUp(id, record, identity: identity)
        if let token { try await setUpGitHub(id, record, identity: identity, token: token) }
      }
      return .remote(id)
    } catch {
      try await undo(error, id: id, record: record)
    }
  }

  /// Destroys the sandbox. One already gone counts as destroyed, so a retry gets past it.
  public func destroy(_ host: HostID) async throws {
    let (id, held) = try record(of: host)
    var record = held
    // A record an older build wrote names no project or workspace: resolved once, or left
    // unknown, which leaves a "no such sandbox" read unconfirmed.
    record.projectID = try? await project(of: id, held, lookingAgain: true)
    record.workspaceID = try? await workspace(of: id, record, lookingAgain: true)
    if let failure = await destroySandbox(record) {
      try Task.checkCancellation()
      throw HostDriverError.provisioning(failure)
    }
    hosts.withLock { $0[id] = nil }
    await settle(record.sandboxID)
    try? FileManager.default.removeItem(at: hostDirectory(id))
  }

  /// Destroys what a failed `create` made, then rethrows `error`, or says what is still there. In
  /// a task of its own, so a cancelled caller still cleans up.
  private func undo(_ error: any Error, id: UUID, record: RailwayHostRecord) async throws
    -> Never
  {
    let failure = await Task { await self.destroySandbox(record) }.value
    try? FileManager.default.removeItem(at: hostDirectory(id))
    guard let failure else {
      hosts.withLock { $0[id] = nil }
      await settle(record.sandboxID)
      throw error
    }
    throw HostDriverError.leftBehind(
      cause: error.localizedDescription, leftover: [failure], host: .remote(id))
  }

  /// Nil once the sandbox is gone (`RailwayAPI.destroyConfirmed`).
  private func destroySandbox(_ record: RailwayHostRecord) async -> String? {
    await api.destroyConfirmed(record)
  }

  /// Whether this sign-in can see `workspaceID` (`RailwayAPI.sees(workspace:)`).
  func seesWorkspace(_ workspaceID: String?) async throws -> Bool {
    try await api.sees(workspace: workspaceID)
  }

  /// The project host `id`'s sandbox is in: its record's; for a record an older build wrote
  /// without one, this driver's when the sandbox is in its environment, else the one Railway says
  /// its environment is in. Kept on the held record once found; nil when Railway won't name it,
  /// remembered for this driver's life as `workspace(of:_:)` does, and asked again for
  /// `lookingAgain`. Throws when Railway can't be asked.
  func project(of id: UUID, _ record: RailwayHostRecord, lookingAgain: Bool = false)
    async throws -> String?
  {
    if let project = record.projectID { return project }
    if !lookingAgain, unprojected.withLock({ $0.contains(id) }) { return nil }
    var found: String?
    if record.environmentID == configuration.environmentID { found = configuration.projectID }
    if found == nil { found = try await api.project(ofEnvironment: record.environmentID) }
    if let found {
      hosts.withLock { $0[id]?.projectID = found }
    } else {
      unprojected.withLock { _ = $0.insert(id) }
    }
    return found
  }

  /// The workspace host `id`'s sandbox is in: its record's; for a record an older build wrote
  /// without one, this driver's when the sandbox is in its environment, else the workspace whose
  /// projects include the record's project, of those the sign-in sees. Whatever is found is kept
  /// on the held record, so it is looked up once and the next write of the record keeps it
  /// (`record(_:in:)`). Nil when it can't be told, which is remembered for this driver's life, so
  /// a host polled for its presence lists the workspaces and their projects once, not at every
  /// read; `lookingAgain` (a destroy the user asked for, perhaps after signing in to another
  /// account) asks anyway. Throws when Railway can't list them.
  func workspace(of id: UUID, _ record: RailwayHostRecord, lookingAgain: Bool = false)
    async throws -> String?
  {
    if let workspace = record.workspaceID { return workspace }
    if !lookingAgain, unresolved.withLock({ $0.contains(id) }) { return nil }
    var found: String?
    if record.environmentID == configuration.environmentID {
      found = configuration.workspaceID
    }
    if found == nil, let project = record.projectID {
      for workspace in try await api.grantedWorkspaces()
      where try await api.projects(workspaceID: workspace.id).contains(where: { $0.id == project })
      {
        found = workspace.id
        break
      }
    }
    if let found {
      hosts.withLock { $0[id]?.workspaceID = found }
    } else {
      unresolved.withLock { _ = $0.insert(id) }
    }
    return found
  }

  /// How many reads in a row a new sandbox may be unknown to Railway before the create takes it
  /// for gone: one just made can lag in its reads.
  static let unknownTries = 5

  /// Until Railway says the sandbox runs. One that failed, or went, never will.
  private func awaitRunning(_ record: RailwayHostRecord) async throws {
    var unknown = 0
    for _ in 0..<configuration.readyTries {
      let status = try await api.sandboxStatus(
        record.sandboxID, environmentID: record.environmentID)
      if status == nil {
        unknown += 1
        if unknown < Self.unknownTries {
          try await Task.sleep(for: configuration.pollInterval)
          continue
        }
      } else {
        unknown = 0
      }
      switch status {
      case RailwaySandbox.running: return
      case RailwaySandbox.creating: try await Task.sleep(for: configuration.pollInterval)
      default:
        throw HostDriverError.provisioning(
          "Railway's sandbox \(record.sandboxID) is \(status?.lowercased() ?? "gone") instead of"
            + " running")
      }
    }
    throw HostDriverError.provisioning(
      "Railway's sandbox \(record.sandboxID) didn't start running in time")
  }

  /// Runs `railway.sh` on the new host, over the relay: its identity file and the daemon's
  /// folders. The first login to a new sandbox, so one the relay drops is tried again (`login`).
  private func setUp(_ id: UUID, _ record: RailwayHostRecord, identity: String) async throws {
    let script = try configuration.hostSetup.script("railway")
    let config = try SSHTransport.writeConfiguration(
      for: target(record, identity: identity), in: hostDirectory(id))
    let command =
      "sh -s -- "
      + [
        id.uuidString.lowercased(), configuration.daemonSocket,
        // Where the daemon really keeps them, which a checkpoint's copy has to clear.
        try DaemonBootstrap.screens(besideSocket: configuration.daemonSocket),
      ]
      .map(PosixShell.quoted).joined(separator: " ")
    try await login(
      config, command, stdin: Data(script.utf8),
      failure: "setting up Railway's sandbox \(record.sandboxID) failed", timeout: 120,
      attempts: 5)
  }

  /// What a create says when the relay refused it.
  static func refusal(_ said: String) -> String {
    let lowered = said.lowercased()
    if lowered.contains("host key verification failed")
      || lowered.contains("remote host identification has changed")
    {
      return "Railway's ssh relay presented a host key other than the one this version of "
        + "Workroom ships for it, so Workroom refused to connect. Either the relay's key changed, "
        + "and Workroom needs an update: update Workroom, then try again. Or someone is "
        + "intercepting the connection. ssh said: \(said)"
    }
    return "Railway's ssh relay refused Workroom's key: \(said)"
  }

  // MARK: GitHub

  /// The Mac's current `gh` token, checked fit for the host's token file: nil when this driver
  /// gives hosts none.
  private func macGitHubToken() async throws -> String? {
    guard let source = configuration.gitHubToken else { return nil }
    let token = try await source().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty, !token.contains(where: \.isNewline) else {
      throw HostDriverError.provisioning(
        "gh gave no usable GitHub token on this Mac: run `gh auth login`")
    }
    return token
  }

  /// Points the new host's git at the user's token: `railway-github.sh` sets the credential
  /// helper and the remote rewrites, then the token is written.
  private func setUpGitHub(
    _ id: UUID, _ record: RailwayHostRecord, identity: String, token: String
  ) async throws {
    let script = try configuration.hostSetup.script("railway-github")
    let config = try SSHTransport.writeConfiguration(
      for: target(record, identity: identity), in: hostDirectory(id))
    try await login(
      config, "sh -s -- \(PosixShell.quoted(Self.gitHubTokenPath))", stdin: Data(script.utf8),
      failure: "setting up git on Railway's sandbox \(record.sandboxID) failed")
    try await writeGitHubToken(token, config: config, record: record)
  }

  /// The Mac's current token on `host`, rewritten there only when it differs. Writes the host's
  /// ssh files first: a host adopted after a relaunch may have none yet.
  public func refreshGitHubToken(on host: HostID) async throws {
    guard let token = try await macGitHubToken() else { return }
    let (id, record) = try record(of: host)
    let config = try SSHTransport.writeConfiguration(
      for: target(record, identity: configuration.keys.appendingPathComponent("id_ed25519").path),
      in: hostDirectory(id))
    try await writeGitHubToken(token, config: config, record: record)
  }

  /// Writes `token` to the host's token file unless it already holds it. The token travels on
  /// ssh's stdin only, so no process list, log or Railway variable ever has it.
  private func writeGitHubToken(
    _ token: String, config: URL, record: RailwayHostRecord
  ) async throws {
    try await login(
      config, Self.gitHubTokenCommand(path: Self.gitHubTokenPath), stdin: Data(token.utf8),
      failure: "writing the GitHub token to Railway's sandbox \(record.sandboxID) failed")
  }

  /// The host's side of a token write, a line for its shell with the token on stdin: compares it
  /// with the file's, and only when they differ replaces the file, made readable by its owner
  /// alone. Says `unchanged` or `rewritten`, never the token. The token is only ever in a shell
  /// variable and builtins' arguments, never another process's argv.
  static func gitHubTokenCommand(path: String) -> String {
    let file = PosixShell.quoted(path)
    return "f=\(file); umask 077; mkdir -p \"${f%/*}\"; t=$(cat); [ -n \"$t\" ] || exit 64; "
      + "if [ -f \"$f\" ] && [ \"$(cat \"$f\")\" = \"$t\" ]; then echo unchanged; "
      + "else printf '%s\\n' \"$t\" > \"$f.new\" && chmod 600 \"$f.new\" && mv -f \"$f.new\" \"$f\" "
      + "&& echo rewritten; fi"
  }

  /// A login to the host through the relay, running `command` with `stdin`, up to `attempts`
  /// times: a login the relay drops (ssh's own failure, 255) while the sandbox comes up is tried
  /// again; a refusal (a changed host key, a key Railway doesn't know) is final, with its reason.
  /// The log gets the command and what it printed, never `stdin`.
  func login(
    _ config: URL, _ command: String, stdin: Data, failure: String, timeout: TimeInterval = 60,
    attempts: Int = 1
  ) async throws {
    ProvisioningProgress.record("$ \(command)")
    var said = ""
    for attempt in 0..<attempts {
      if attempt > 0 { try await Task.sleep(for: configuration.pollInterval) }
      let result = await runner.run(
        "/usr/bin/ssh", ["-F", config.path, SSHTransport.alias, command], in: NSHomeDirectory(),
        timeout: timeout, stdin: stdin)
      try Task.checkCancellation()
      ProvisioningProgress.record(result.stdout)
      ProvisioningProgress.record(result.stderr)
      if result.ok { return }
      said = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      if SSHTransport.isRefusal(said) { throw HostDriverError.provisioning(Self.refusal(said)) }
      guard result.exitCode == 255 else { break }
    }
    throw HostDriverError.provisioning("\(failure): \(said)")
  }

  // MARK: Keys

  /// This Mac's private key for the relay, made once and registered on the account unless Railway
  /// already has it (the other build's sign-in may have registered it).
  private func macKey() async throws -> String {
    let key = configuration.keys.appendingPathComponent("id_ed25519")
    let manager = FileManager.default
    // Made under the lock Release and Nightly share, looked for again inside it: the other app
    // may be making it now, and two would each register a key and keep only one.
    try await keysLock.withLock {
      guard !manager.fileExists(atPath: key.path) else { return }
      let made = await runner.run(
        "/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "workroom", "-f", key.path],
        in: NSHomeDirectory(), timeout: 30)
      guard made.ok else {
        throw HostDriverError.provisioning(
          "ssh-keygen couldn't make Workroom's Railway key: "
            + made.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }
    let publicKey = try String(
      contentsOf: key.appendingPathExtension("pub"), encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let known = try await api.sshPublicKeys().map(Self.keyBody)
    if !known.contains(Self.keyBody(publicKey)) {
      try await api.createSSHPublicKey(name: configuration.keyName, publicKey: publicKey)
    }
    return key.path
  }

  /// `<type> <base64>` of a public key line, without its comment.
  static func keyBody(_ line: String) -> String {
    line.split(separator: " ").prefix(2).joined(separator: " ")
  }

  /// Held while the Mac's key is made (`CrossProcessLock`): Release and Nightly share the folder.
  /// Never across a call to Railway. Taken inside `RailwaySerial`.
  private var keysLock: CrossProcessLock {
    CrossProcessLock(path: configuration.keys.appendingPathComponent("keys.lock"))
  }

  // MARK: Presence

  /// The sandbox's status, read through the API: running (or still being made) is awake;
  /// destroyed or failed is gone. Unknown to Railway is gone only when this sign-in can see the
  /// sandbox's workspace and project (`RailwayAPI.confirmsMissing`); under an account that can't,
  /// it is signed out. A sign-in Railway no longer takes is signed out; anything else Railway
  /// couldn't answer is nil.
  public func presence(_ host: HostID) async -> HostPresence? {
    guard let (id, held) = try? record(of: host) else { return nil }
    do {
      let status = try await api.sandboxStatus(held.sandboxID, environmentID: held.environmentID)
      if let status { return Self.isGone(status) ? .gone : .awake }
      var record = held
      // With no project known, nothing can confirm the read either way.
      record.projectID = try await project(of: id, held)
      guard record.projectID != nil, let workspace = try await workspace(of: id, record) else {
        return nil
      }
      record.workspaceID = workspace
      return try await api.confirmsMissing(record) ? .gone : .signedOut
    } catch RailwaySessionError.signedOut {
      return .signedOut
    } catch RailwayAPIError.unauthorized {
      return .signedOut
    } catch {
      return nil
    }
  }

  static func isGone(_ status: String) -> Bool { RailwaySandbox.isGone(status) }

  // MARK: Records

  /// Only fills in `descriptor`: the create's ledger entry stays until the record is written
  /// (`recorded`), so a sandbox whose config write fails or never happens is still swept.
  public func record(_ host: HostID, in descriptor: inout HostDescriptor) {
    guard case .remote(let id) = host, let record = hosts.withLock({ $0[id] }) else { return }
    descriptor.railway = record
  }

  /// `descriptor` is in config now: its sandbox comes off the ledger, for its record to answer for.
  public func recorded(_ descriptor: HostDescriptor) async {
    guard let sandbox = descriptor.railway?.sandboxID else { return }
    await settle(sandbox)
  }

  public func adopt(_ descriptor: HostDescriptor) throws {
    guard let id = descriptor.id, let record = descriptor.railway else {
      throw HostDriverError.invalidConfiguration("the Railway host's record is incomplete")
    }
    hosts.withLock { $0[id] = $0[id] ?? record }
  }

  // MARK: ssh

  /// The login to `record`'s sandbox through the relay, trusting only the shipped relay key: a
  /// record from a build that pinned on first use may hold another.
  func target(_ record: RailwayHostRecord, identity: String) -> SSHTransport.Host {
    SSHTransport.Host(
      address: configuration.relayHost, port: 22,
      user: "sbx:\(record.environmentID):\(record.sandboxID)", identityFile: identity,
      hostKey: Self.relayHostKey, daemonSocket: configuration.daemonSocket)
  }

  private func target(_ host: HostID) throws -> (UUID, SSHTransport.Host) {
    let (id, record) = try record(of: host)
    return (
      id,
      target(record, identity: configuration.keys.appendingPathComponent("id_ed25519").path)
    )
  }

  public func openStream(to host: HostID) async throws -> HostStream {
    let (id, target) = try target(host)
    return try SSHTransport.exec(
      SSHTransport.relayCommand(binary: target.daemonBinary, socket: target.daemonSocket),
      on: target, in: hostDirectory(id), purpose: .connection)
  }

  public func exec(_ command: String, on host: HostID) async throws -> HostStream {
    let (id, target) = try target(host)
    return try SSHTransport.exec(command, on: target, in: hostDirectory(id), purpose: .exchange)
  }

  /// The Mac's attach client over `ssh -T` (ADR 0074): no host terminal, so the relay writes no
  /// banner and takes no Ctrl+\ then d. Never the relay's durable-session resume.
  public func attachCommand(
    to host: HostID, session: UUID, workingDirectory: String, restored: Bool,
    metadata: [(key: String, value: String)], runCommand: String?
  ) throws -> String {
    let (id, target) = try target(host)
    return try SSHTransport.attachCommand(
      to: target, in: hostDirectory(id), session: session, workingDirectory: workingDirectory,
      restored: restored, metadata: metadata, runCommand: runCommand)
  }

  public func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool {
    guard case .remote(let id) = host else { return false }
    return SSHTransport.refusedLastAttach(of: session, in: hostDirectory(id))
  }

  public func lastAttach(of session: UUID, on host: HostID) -> LastAttach {
    guard case .remote(let id) = host else { return .finished }
    return SSHTransport.lastAttach(of: session, in: hostDirectory(id))
  }
}

// MARK: The launch sweep (#630)

extension RailwayHostDriver {
  /// This Mac's creates (`RailwayCreateLedger`), beside its Railway key.
  var ledger: RailwayCreateLedger { RailwayCreateLedger(directory: configuration.keys) }

  /// Whether `error` is Railway answering no, so a `sandboxCreate` made nothing: a refused
  /// sign-in, or a client error (4xx). Anything else may have made one: a server error, a 2xx
  /// with GraphQL errors (it can carry partial data), an answer that couldn't be read, a lost
  /// link, or no HTTP status at all.
  static func isRefusal(_ error: any Error) -> Bool {
    switch error as? RailwayAPIError {
    case .unauthorized: true
    case .http(let status, _): (400..<500).contains(status)
    case .graphQL, .malformed, nil: false
    }
  }

  /// Destroys the sandboxes this Mac made that no host record names (ADR 0071 and its amendment):
  /// what a crash between `sandboxCreate` and its record left, or a create whose cleanup failed.
  /// Only a sandbox whose id this Mac's create ledger holds is ever destroyed, by that id, with no
  /// listing: a sandbox has no name or label, and another Mac sharing the environment (a copied
  /// placement) has live hosts that no record here names. Each entry is acted on in the
  /// environment it was made in, which may be one the placement has since left. Returns what it
  /// couldn't do; throws only when Railway can't list the workspaces an entry needs (signed out,
  /// offline), so the sweep is owed again.
  ///
  /// - An entry whose reply was lost (no id) is never acted on, whatever its age or what Railway
  ///   holds: Workroom never guesses which sandbox a create made. It stays on the ledger until
  ///   the user destroys one of its candidates or dismisses it (`RailwayLostCreates`).
  /// - Kept, unacted on: an entry in a workspace this sign-in can't see (another account's), for a
  ///   sign-in that can.
  /// - Kept: whatever `recorded` names (which also takes its entry off), every sandbox this driver
  ///   holds, and any entry younger than `grace`, which may be a create still under way in the
  ///   other build sharing the ledger (Release and Nightly, ADR 0036).
  ///
  /// With no entry due, Railway isn't asked anything.
  public func sweep(keeping recorded: Set<String>, grace: TimeInterval = sweepGrace) async throws
    -> [String]
  {
    let now = Date()
    let held = Set(hosts.withLock { $0.values.map(\.sandboxID) })
    let heldIntents = Set(intents.withLock { $0.values })
    let entries = try await ledger.update {
      $0.removeAll { $0.sandbox.map(recorded.contains) ?? false }
    }
    let due = entries.filter { entry in
      guard let sandbox = entry.sandbox else { return false }
      return now.timeIntervalSince(entry.started) >= grace && !held.contains(sandbox)
        && !heldIntents.contains(entry.intent)
    }
    guard !due.isEmpty else { return [] }
    var failures: [String] = []
    var done: Set<UUID> = []
    var granted: Set<String>?
    do {
      for entry in due {
        guard let sandbox = entry.sandbox else { continue }
        var (environment, workspace, project) = place(of: entry)
        // An entry from before entries named their project is in the one Railway says its
        // environment is in; unknown leaves a "no such sandbox" read unconfirmed.
        if project == nil { project = try? await api.project(ofEnvironment: environment) }
        // Today's environment is this sign-in's to act on; an older one only if it sees it.
        if environment != configuration.environmentID {
          if granted == nil { granted = Set(try await api.grantedWorkspaces().map(\.id)) }
          guard let workspace, granted?.contains(workspace) == true else {
            failures.append(
              "Railway sandbox \(sandbox): made in a Railway workspace this sign-in can't see, "
                + "so Workroom kept it, to destroy when signed in to the account that made it")
            continue
          }
        }
        let record = RailwayHostRecord(
          projectID: project, environmentID: environment, sandboxID: sandbox,
          hostKey: "", workspaceID: workspace)
        if let failure = await destroySandbox(record) {
          failures.append(failure)
        } else {
          done.insert(entry.intent)
        }
      }
    } catch {
      // What was destroyed stays destroyed; the rest is owed again.
      try? await ledger.drop(done)
      throw error
    }
    try? await ledger.drop(done)
    return failures
  }

  /// The environment `entry`'s sandbox was asked for in, its workspace and its project: the
  /// placement's for an entry from before entries named them, and the placement's project for
  /// one in today's environment from before entries named it.
  private func place(of entry: RailwayCreateLedger.Entry) -> (String, String?, String?) {
    guard let environment = entry.environmentID else {
      return (configuration.environmentID, configuration.workspaceID, configuration.projectID)
    }
    let project =
      entry.projectID
      ?? (environment == configuration.environmentID ? configuration.projectID : nil)
    return (environment, entry.workspaceID, project)
  }

  /// Takes the entry of `sandbox`'s create off the ledger, by its intent when this driver made
  /// it (so an entry whose id write failed goes too), and by the id otherwise.
  func settle(_ sandbox: String) async {
    let intent = intents.withLock { $0.removeValue(forKey: sandbox) }
    try? await ledger.update { entries in
      entries.removeAll { $0.intent == intent || $0.sandbox == sandbox }
    }
  }

  /// Fills in the sandbox Railway made for `intent`, tried a few times: an entry left with no id
  /// is never swept, and waits for the user (`RailwayLostCreates`). Recording, destroying or
  /// undoing the host takes the entry off by its intent either way (`settle`).
  private func nameIntent(_ intent: UUID, sandbox: String) async {
    for attempt in 0..<3 {
      do {
        try await ledger.name(intent, sandbox: sandbox)
        return
      } catch {
        ProvisioningProgress.record(
          "Writing Railway sandbox \(sandbox) to this Mac's create ledger failed (try "
            + "\(attempt + 1) of 3): \(error.localizedDescription)")
        try? await Task.sleep(for: configuration.pollInterval)
      }
    }
  }

  /// This Mac's creates no record has named yet: their sandboxes, for those Railway answered.
  public var pendingSandboxes: Set<String> {
    get async { Set(((try? await ledger.entries()) ?? []).compactMap(\.sandbox)) }
  }

  /// How old a ledger entry must be before the sweep takes it: longer than any create takes to
  /// record its host (the boot and setup a create waits on), as `PendingMachines.grace`.
  public static let sweepGrace: TimeInterval = PendingMachines.grace
}

// MARK: The API calls the driver makes

extension RailwayAPI {
  /// A sandbox in `environmentID` that never idles out (ADR 0071), made with `options`: its id.
  public func createSandbox(
    environmentID: String, options: RailwaySandboxOptions = RailwaySandboxOptions(),
    delivery: RailwayDelivery? = nil
  ) async throws -> String {
    struct Answer: Decodable {
      struct Sandbox: Decodable { let id: String }
      let sandboxCreate: Sandbox
    }
    return try await query(
      "mutation sandboxCreate($input: SandboxCreateInput!) { sandboxCreate(input: $input) "
        + "{ id status } }",
      variables: ["input": options.input(environmentID: environmentID)], as: Answer.self,
      delivery: delivery
    ).sandboxCreate.id
  }

  /// The sandbox's status (`CREATING`, `RUNNING`, `DESTROYING`, `DESTROYED`, `FAILED`), or nil
  /// when Railway has no such sandbox.
  public func sandboxStatus(_ id: String, environmentID: String) async throws -> String? {
    struct Answer: Decodable {
      struct Sandbox: Decodable { let status: String }
      let sandbox: Sandbox?
    }
    return try await query(
      "query sandbox($environmentId: String!, $id: String!) { sandbox(environmentId: "
        + "$environmentId, id: $id) { id status } }",
      variables: ["environmentId": .string(environmentID), "id": .string(id)], as: Answer.self
    ).sandbox?.status
  }

  /// Asks Railway to destroy the sandbox. An answer naming no sandbox, even without errors,
  /// throws (`malformed`): it confirms nothing, so the caller reads the sandbox's status.
  public func destroySandbox(_ id: String, environmentID: String) async throws {
    struct Answer: Decodable {
      struct Sandbox: Decodable { let id: String }
      let sandboxDestroy: Sandbox?
    }
    let answer = try await query(
      "mutation sandboxDestroy($id: String!, $environmentId: String!) { sandboxDestroy(id: $id, "
        + "environmentId: $environmentId) { id status } }",
      variables: ["id": .string(id), "environmentId": .string(environmentID)], as: Answer.self)
    guard answer.sandboxDestroy != nil else {
      throw RailwayAPIError.malformed("Railway's destroy named no sandbox")
    }
  }

  /// Destroys `record`'s sandbox: nil once it is gone, whether this destroyed it or it already
  /// was, else what is wrong. Railway's answer for a sandbox it no longer has isn't documented, so
  /// a refusal is checked against the sandbox's status rather than its words. The record's
  /// workspace and project are what a "no such sandbox" read is confirmed against
  /// (`confirmsMissing`).
  func destroyConfirmed(_ record: RailwayHostRecord) async -> String? {
    do {
      try await destroySandbox(record.sandboxID, environmentID: record.environmentID)
      return nil
    } catch {
      // A read that went through and found it destroyed is gone, and so is one that found it
      // failed: Railway won't destroy a failed sandbox, and this destroy was tried. One that found
      // no such sandbox is gone only when this sign-in can see its workspace and project.
      // Anything else (still destroying, which may bill on), or a read that failed, leaves the
      // destroy unconfirmed.
      do {
        let status = try await sandboxStatus(record.sandboxID, environmentID: record.environmentID)
        if let status {
          if status == RailwaySandbox.destroyed || status == RailwaySandbox.failed { return nil }
        } else if try await confirmsMissing(record) {
          return nil
        } else {
          return "Railway sandbox \(record.sandboxID): Railway's sign-in can't see the workspace "
            + "or project it was made in, so Workroom can't tell whether it is gone. Sign in to "
            + "Railway with the account that made it, then try again."
        }
      } catch {}
      return "Railway sandbox \(record.sandboxID): \(error.localizedDescription)"
    }
  }

  /// Whether this sign-in can see `workspaceID` (`me { workspaces }`): what makes Railway's "no
  /// such sandbox" trustworthy, with the project (`confirmsMissing`), since an account that can't
  /// see the workspace reads every sandbox in it as missing. False for no workspace; throws when
  /// Railway can't list them.
  func sees(workspace workspaceID: String?) async throws -> Bool {
    guard let workspaceID else { return false }
    return try await grantedWorkspaces().contains { $0.id == workspaceID }
  }

  /// Whether Railway's "no such sandbox" for `record`'s sandbox can be trusted: this sign-in sees
  /// its workspace, and its project among that workspace's projects. A sign-in granted the
  /// workspace but not the project reads every sandbox in it as missing too. False for a record
  /// naming no workspace or project; throws when Railway can't list them.
  func confirmsMissing(_ record: RailwayHostRecord) async throws -> Bool {
    try await sees(project: record.projectID, in: record.workspaceID)
  }

  /// Whether this sign-in sees `workspaceID`, and `projectID` among its projects: what makes an
  /// empty or "no such sandbox" answer for an environment in that project trustworthy, since a
  /// sign-in granted the workspace but not the project reads its environments as empty. False for
  /// no workspace or project; throws when Railway can't list them.
  func sees(project projectID: String?, in workspaceID: String?) async throws -> Bool {
    guard let workspaceID, let projectID, try await sees(workspace: workspaceID) else {
      return false
    }
    return try await projects(workspaceID: workspaceID).contains { $0.id == projectID }
  }

  /// The project `environmentID` is in, as Railway names it: what a ledger entry or record from
  /// before they named their project is checked against. Nil when Railway won't name it (an
  /// environment this sign-in can't see answers with an error), which is unknown, never gone;
  /// throws when Railway can't be asked.
  func project(ofEnvironment environmentID: String) async throws -> String? {
    struct Answer: Decodable {
      struct Environment: Decodable { let projectId: String? }
      let environment: Environment?
    }
    do {
      return try await query(
        "query environment($id: String!) { environment(id: $id) { id projectId } }",
        variables: ["id": .string(environmentID)], as: Answer.self
      ).environment?.projectId
    } catch RailwayAPIError.graphQL {
      return nil
    }
  }

  /// The user's own ssh keys on the account, as their public key lines, page by page.
  public func sshPublicKeys() async throws -> [String] {
    struct Key: Decodable, Sendable { let publicKey: String }
    struct Answer: Decodable { let sshPublicKeys: RailwayConnection<Key> }
    // The first page is asked for as the live checks have it, with no arguments; only a later
    // page names `after` (Relay's argument, which Railway's other connections take).
    let fields = "{ edges { node { id publicKey } } pageInfo { hasNextPage endCursor } }"
    return try await pages { after in
      guard let after else {
        return try await query(
          "query sshPublicKeys { sshPublicKeys \(fields) }", as: Answer.self
        ).sshPublicKeys
      }
      return try await query(
        "query sshPublicKeys($after: String) { sshPublicKeys(after: $after) \(fields) }",
        variables: ["after": .string(after)], as: Answer.self
      ).sshPublicKeys
    }.map(\.publicKey)
  }

  public func createSSHPublicKey(name: String, publicKey: String) async throws {
    struct Answer: Decodable {
      struct Key: Decodable { let id: String }
      let sshPublicKeyCreate: Key
    }
    _ = try await query(
      "mutation sshPublicKeyCreate($input: SshPublicKeyCreateInput!) { sshPublicKeyCreate("
        + "input: $input) { id } }",
      variables: ["input": ["name": .string(name), "publicKey": .string(publicKey)]],
      as: Answer.self)
  }
}

// MARK: The API calls the launch sweep makes (#630)

/// A sandbox as `sandboxes` lists it.
public struct RailwaySandbox: Decodable, Equatable, Sendable {
  public let id: String
  public let status: String
  public let createdAt: String?
  public let environmentID: String

  enum CodingKeys: String, CodingKey {
    case id, status, createdAt
    case environmentID = "environmentId"
  }

  // Railway's sandbox statuses, as `sandboxStatus` and `sandboxes` read them.
  public static let creating = "CREATING"
  public static let running = "RUNNING"
  public static let destroying = "DESTROYING"
  public static let destroyed = "DESTROYED"
  public static let failed = "FAILED"

  /// Destroyed, or on its way: no longer a live sandbox.
  public static func isEnding(_ status: String) -> Bool {
    status == destroyed || status == destroying
  }

  /// What a workroom reads as its host gone: ending, or failed.
  public static func isGone(_ status: String) -> Bool { isEnding(status) || status == failed }
}

extension RailwayAPI {
  /// Every live sandbox in `environmentID`, page by page: Railway's `active` filter (ADR 0071)
  /// leaves out destroyed ones, so the page cap counts live sandboxes. A Railway that refuses the
  /// argument by name is asked again without it, destroyed ones and all. Callers still check each
  /// status.
  public func sandboxes(environmentID: String) async throws -> [RailwaySandbox] {
    do {
      return try await sandboxes(environmentID: environmentID, active: true)
    } catch let error as RailwayAPIError where Self.refusesActive(error) {
      return try await sandboxes(environmentID: environmentID, active: false)
    }
  }

  private func sandboxes(environmentID: String, active: Bool) async throws -> [RailwaySandbox] {
    struct Answer: Decodable { let sandboxes: RailwayConnection<RailwaySandbox> }
    return try await pages { after in
      var variables: [String: RailwayJSON] = [
        "environmentId": .string(environmentID), "first": 100,
      ]
      if active { variables["active"] = true }
      if let after { variables["after"] = .string(after) }
      let filter = active ? ", $active: Boolean" : ""
      let argument = active ? ", active: $active" : ""
      return try await query(
        "query sandboxes($environmentId: String!, $first: Int, $after: String\(filter)) { "
          + "sandboxes(environmentId: $environmentId, first: $first, after: $after\(argument)) "
          + "{ edges { node { id status createdAt environmentId } } pageInfo { hasNextPage "
          + "endCursor } } }",
        variables: variables, as: Answer.self
      ).sandboxes
    }
  }

  /// Whether Railway refused the `active` argument itself (a schema without it).
  static func refusesActive(_ error: RailwayAPIError) -> Bool {
    let messages: [String]
    switch error {
    case .graphQL(let said): messages = said
    case .http(status: 400, message: let said): messages = [said]
    default: return false
    }
    return messages.contains { $0.contains("\"active\"") || $0.contains("argument 'active'") }
  }

  /// The most pages a listing reads (`pages`): 10,000 sandboxes at 100 a page, far past what an
  /// environment holds (Railway caps its live ones at 100, and only live ones are listed), and
  /// far past any account's ssh keys.
  public static let maxPages = 100

  /// Every node of a Relay connection, asking for each page after the last one's `endCursor`. A
  /// next page with no cursor, or a cursor already asked for, fails the whole listing
  /// (`malformed`): it would ask for its pages forever, and part of a list read as all of it
  /// would let a placement leave an environment that still holds a sandbox, offer a lost
  /// create the wrong candidates, or register a key Railway already has.
  func pages<Node: Decodable & Sendable>(
    _ page: (_ after: String?) async throws -> RailwayConnection<Node>
  ) async throws -> [Node] {
    var all: [Node] = []
    var after: String?
    var seen: Set<String> = []
    repeat {
      guard seen.count < Self.maxPages else {
        throw RailwayAPIError.malformed("a listing of more than \(Self.maxPages) pages")
      }
      let connection = try await page(after)
      all += connection.edges.map(\.node)
      guard connection.pageInfo.hasNextPage else { break }
      guard let next = connection.pageInfo.endCursor, seen.insert(next).inserted else {
        throw RailwayAPIError.malformed("a next page whose cursor doesn't advance")
      }
      after = next
    } while true
    return all
  }
}

/// A page of a Railway (Relay) connection.
struct RailwayConnection<Node: Decodable & Sendable>: Decodable, Sendable {
  struct Edge: Decodable, Sendable { let node: Node }
  struct PageInfo: Decodable, Sendable {
    let hasNextPage: Bool
    let endCursor: String?
  }
  let edges: [Edge]
  let pageInfo: PageInfo
}

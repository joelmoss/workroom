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
///   makes for this Mac and registers on the account, and the relay's host key pinned on first use
///   (Railway publishes none). The pin is written once and never replaced: a relay presenting
///   another key fails ssh's own check, which is a refusal the pane stops on.
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
    /// This Mac's folder for its Railway ssh key (`id_ed25519`) and the relay's pinned host key
    /// (`relay_host_key`): one for Release and Nightly, a Dev build's own.
    public var keys: URL
    /// The relay every login goes through.
    public var relayHost: String
    /// The name the Mac's key is registered under on the account.
    public var keyName: String
    public var daemonSocket: String
    public var screens: String
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
      screens: String = "\(RailwayHostDriver.stateDirectory)/screens",
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
      self.screens = screens
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
      // One create at a time makes the key and the pin; the rest find them.
      let (identity, hostKey) = try await RailwaySerial.shared.run {
        (try await self.macKey(), try await self.pinnedRelayKey())
      }
      // Read before anything is made: a Mac signed out of gh bills no sandbox.
      return (identity, hostKey, try await self.macGitHubToken())
    }
    let sandbox = try await ProvisioningProgress.step(.machine) {
      // Written down before Railway is asked: the sweep destroys only what the ledger names.
      let intent = try await ledger.begin()
      let sandbox: String
      do {
        sandbox = try await api.createSandbox(
          environmentID: configuration.environmentID, options: sandboxOptions)
      } catch {
        // Railway said no, so made nothing. Anything else (the link, a cancel, an answer that
        // couldn't be read, a server error) may have lost the reply to a sandbox that exists,
        // which the sweep reconciles by when it was made.
        if Self.isRefusal(error) { try? await ledger.drop([intent]) }
        throw error
      }
      // Best-effort: an intent with no id is still reconciled by its time.
      try? await ledger.name(intent, sandbox: sandbox)
      return sandbox
    }
    let id = UUID()
    let record = RailwayHostRecord(
      projectID: configuration.projectID, environmentID: configuration.environmentID,
      sandboxID: sandbox, hostKey: hostKey)
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
    let (id, record) = try record(of: host)
    if let failure = await destroySandbox(record) {
      try Task.checkCancellation()
      throw HostDriverError.provisioning(failure)
    }
    hosts.withLock { $0[id] = nil }
    try? await ledger.forget([record.sandboxID])
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
      try? await ledger.forget([record.sandboxID])
      throw error
    }
    throw HostDriverError.leftBehind(
      cause: error.localizedDescription, leftover: [failure], host: .remote(id))
  }

  /// Nil once the sandbox is gone, whether this destroyed it or it already was. Railway's answer
  /// for a sandbox it no longer has isn't documented, so a refusal is checked against the
  /// sandbox's status rather than its words.
  private func destroySandbox(_ record: RailwayHostRecord) async -> String? {
    do {
      try await api.destroySandbox(record.sandboxID, environmentID: record.environmentID)
      return nil
    } catch {
      // A read that went through and found no such sandbox (nil) is as gone as a destroyed one;
      // only a read that failed leaves the destroy unconfirmed.
      do {
        let status = try await api.sandboxStatus(
          record.sandboxID, environmentID: record.environmentID)
        if Self.isGone(status) { return nil }
      } catch {}
      return "Railway sandbox \(record.sandboxID): \(error.localizedDescription)"
    }
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
      case "RUNNING": return
      case "CREATING": try await Task.sleep(for: configuration.pollInterval)
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
      + [id.uuidString.lowercased(), configuration.daemonSocket, configuration.screens]
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
      return "Railway's ssh relay presented a different host key from the one Workroom pinned "
        + "for it, so Workroom refused to connect: someone may be intercepting the connection. "
        + "ssh said: \(said)"
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

  /// The relay's host key, `<type> <base64>`: read from the pin, or on first use scanned and
  /// pinned. Never scanned again once pinned.
  private func pinnedRelayKey() async throws -> String {
    let pin = configuration.keys.appendingPathComponent("relay_host_key")
    func pinned() -> String? {
      (try? String(contentsOf: pin, encoding: .utf8))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }
    if let pinned = pinned() { return pinned }
    let scan = await runner.run(
      "/usr/bin/ssh-keyscan", ["-t", "ed25519", configuration.relayHost], in: NSHomeDirectory(),
      timeout: 30)
    guard
      let fields = scan.stdout.split(separator: "\n").lazy
        .filter({ !$0.hasPrefix("#") }).map({ $0.split(separator: " ") })
        .first(where: { $0.count >= 3 })
    else {
      throw HostDriverError.provisioning(
        "Workroom couldn't read the host key of Railway's ssh relay (\(configuration.relayHost))"
          + ": \(scan.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    let key = "\(fields[1]) \(fields[2])"
    // Written once, under the lock the other app shares: a pin it wrote meanwhile is kept.
    return try await keysLock.withLock {
      if let pinned = pinned() { return pinned }
      try (key + "\n").write(to: pin, atomically: true, encoding: .utf8)
      return key
    }
  }

  /// Held while the Mac's key or the relay's pin is made (`CrossProcessLock`): Release and Nightly
  /// share the folder. Never across a call to Railway. Taken inside `RailwaySerial`.
  private var keysLock: CrossProcessLock {
    CrossProcessLock(path: configuration.keys.appendingPathComponent("keys.lock"))
  }

  // MARK: Presence

  /// The sandbox's status, read through the API: running (or still being made) is awake;
  /// destroyed, failed or unknown to Railway is gone. A sign-in Railway no longer takes is
  /// signed out; anything else Railway couldn't answer is nil.
  public func presence(_ host: HostID) async -> HostPresence? {
    guard let (_, record) = try? record(of: host) else { return nil }
    do {
      let status = try await api.sandboxStatus(
        record.sandboxID, environmentID: record.environmentID)
      return Self.isGone(status) ? .gone : .awake
    } catch RailwaySessionError.signedOut {
      return .signedOut
    } catch RailwayAPIError.unauthorized {
      return .signedOut
    } catch {
      return nil
    }
  }

  static func isGone(_ status: String?) -> Bool {
    guard let status else { return true }
    return ["DESTROYED", "DESTROYING", "FAILED"].contains(status)
  }

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
    try? await ledger.forget([sandbox])
  }

  public func adopt(_ descriptor: HostDescriptor) throws {
    guard let id = descriptor.id, let record = descriptor.railway else {
      throw HostDriverError.invalidConfiguration("the Railway host's record is incomplete")
    }
    hosts.withLock { $0[id] = $0[id] ?? record }
  }

  // MARK: ssh

  func target(_ record: RailwayHostRecord, identity: String) -> SSHTransport.Host {
    SSHTransport.Host(
      address: configuration.relayHost, port: 22,
      user: "sbx:\(record.environmentID):\(record.sandboxID)", identityFile: identity,
      hostKey: record.hostKey, daemonSocket: configuration.daemonSocket)
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

  /// Whether `error` is Railway answering no, so a `sandboxCreate` made nothing: a GraphQL error,
  /// a refused sign-in, or a client error. A server error or a lost link may have made one.
  static func isRefusal(_ error: any Error) -> Bool {
    switch error as? RailwayAPIError {
    case .graphQL, .unauthorized: true
    case .http(let status, _): status < 500
    case .malformed, nil: false
    }
  }

  /// Destroys the sandboxes this Mac made that no host record names (ADR 0071 and its amendment):
  /// what a crash between `sandboxCreate` and its record left, or a create whose cleanup failed.
  /// Only a sandbox this Mac's create ledger accounts for is ever destroyed: a sandbox has no name
  /// or label, and another Mac sharing the environment (a copied placement) has live hosts that no
  /// record here names. Returns the destroys that failed; throws only when Railway can't list the
  /// sandboxes a lost reply needs (signed out, offline), so the sweep is owed again.
  ///
  /// - An entry with its sandbox's id is destroyed by that id, with no listing.
  /// - An entry whose reply was lost (no id) is matched by time: the one live sandbox in the
  ///   environment that nothing names (no record, no other entry, no host this driver holds) and
  ///   that Railway made from `reconcileBefore` before the intent to `reconcileAfter` after it.
  ///   None there drops the entry. More candidates than lost intents, or more than one left for
  ///   an intent, destroys none and says so. The residual risk is another Mac's create landing
  ///   alone in that window just as this Mac's reply was lost.
  /// - Kept: whatever `recorded` names (which also takes its entry off), every sandbox this driver
  ///   holds, and any entry younger than `grace`, which may be a create still under way in the
  ///   other build sharing the ledger (Release and Nightly, ADR 0036).
  ///
  /// With no entry due, Railway isn't asked anything.
  public func sweep(keeping recorded: Set<String>) async throws -> [String] {
    try await sweep(keeping: recorded, grace: Self.sweepGrace)
  }

  public func sweep(keeping recorded: Set<String>, grace: TimeInterval) async throws -> [String] {
    let now = Date()
    let held = Set(hosts.withLock { $0.values.map(\.sandboxID) })
    let entries = try await ledger.update {
      $0.removeAll { $0.sandbox.map(recorded.contains) ?? false }
    }
    let due = entries.filter {
      now.timeIntervalSince($0.started) >= grace && !($0.sandbox.map(held.contains) ?? false)
    }
    guard !due.isEmpty else { return [] }
    var failures: [String] = []
    var done: Set<UUID> = []
    for entry in due {
      guard let sandbox = entry.sandbox else { continue }
      if let failure = await destroySandbox(sweptRecord(sandbox)) {
        failures.append(failure)
      } else {
        done.insert(entry.intent)
      }
    }
    let lost = due.filter { $0.sandbox == nil }.sorted { $0.started < $1.started }
    if !lost.isEmpty {
      do {
        let (settled, said) = try await reconcile(
          lost, accounted: recorded.union(held).union(entries.compactMap(\.sandbox)))
        done.formUnion(settled)
        failures += said
      } catch {
        // What was destroyed by id stays destroyed; the lost replies are owed again.
        try? await ledger.drop(done)
        throw error
      }
    }
    try? await ledger.drop(done)
    return failures
  }

  private func sweptRecord(_ sandbox: String) -> RailwayHostRecord {
    RailwayHostRecord(
      projectID: configuration.projectID, environmentID: configuration.environmentID,
      sandboxID: sandbox, hostKey: "")
  }

  /// Matches each create whose reply was lost (`lost`) to the sandbox Railway made for it, by
  /// time, and destroys it (see `sweep`): the intents now settled, and what failed.
  private func reconcile(_ lost: [RailwayCreateLedger.Entry], accounted: Set<String>)
    async throws -> (done: Set<UUID>, failures: [String])
  {
    let environment = configuration.environmentID
    let live = try await api.sandboxes(environmentID: environment).filter {
      $0.environmentID == environment && !["DESTROYED", "DESTROYING"].contains($0.status)
        && !accounted.contains($0.id)
    }
    func candidates(_ entry: RailwayCreateLedger.Entry) -> [String] {
      live.filter { sandbox in
        guard let made = sandbox.createdAt.flatMap(Self.date) else { return false }
        let offset = made.timeIntervalSince(entry.started)
        return offset >= -Self.reconcileBefore && offset <= Self.reconcileAfter
      }.map(\.id)
    }
    let all = Set(lost.flatMap(candidates))
    guard all.count <= lost.count else {
      return (
        Set(lost.map(\.intent)),
        [
          "Railway sandboxes \(all.sorted().joined(separator: ", ")): \(lost.count) of this Mac's"
            + " creates lost Railway's reply, and Workroom can't tell which of these were theirs,"
            + " so it left them all"
        ]
      )
    }
    var done: Set<UUID> = []
    var failures: [String] = []
    var claimed: Set<String> = []
    for entry in lost {
      let left = candidates(entry).filter { !claimed.contains($0) }
      guard left.count <= 1 else {
        failures.append(
          "Railway sandboxes \(left.sorted().joined(separator: ", ")): a create of this Mac's lost"
            + " Railway's reply, and Workroom can't tell which was its, so it left them")
        done.insert(entry.intent)
        continue
      }
      guard let sandbox = left.first else {
        done.insert(entry.intent)
        continue
      }
      claimed.insert(sandbox)
      if let failure = await destroySandbox(sweptRecord(sandbox)) {
        failures.append(failure)
      } else {
        done.insert(entry.intent)
      }
    }
    return (done, failures)
  }

  /// This Mac's creates no record has named yet: their sandboxes, for those Railway answered.
  public var pendingSandboxes: Set<String> {
    get async { Set(((try? await ledger.entries()) ?? []).compactMap(\.sandbox)) }
  }

  /// How old a ledger entry must be before the sweep takes it: longer than any create takes to
  /// record its host (the boot and setup a create waits on), as `PendingMachines.grace`.
  public static let sweepGrace: TimeInterval = PendingMachines.grace
  /// How long before a lost reply's intent Railway's clock may put its sandbox (the two clocks
  /// differ), and how long after it: the create's own request, its token refresh and the call,
  /// each bounded, has reached Railway by then.
  public static let reconcileBefore: TimeInterval = 120
  public static let reconcileAfter: TimeInterval = 300

  /// Railway's `DateTime`, ISO 8601 with or without fractional seconds.
  static func date(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }
}

// MARK: The API calls the driver makes

extension RailwayAPI {
  /// A sandbox in `environmentID` that never idles out (ADR 0071), made with `options`: its id.
  public func createSandbox(
    environmentID: String, options: RailwaySandboxOptions = RailwaySandboxOptions()
  ) async throws -> String {
    struct Answer: Decodable {
      struct Sandbox: Decodable { let id: String }
      let sandboxCreate: Sandbox
    }
    return try await query(
      "mutation sandboxCreate($input: SandboxCreateInput!) { sandboxCreate(input: $input) "
        + "{ id status } }",
      variables: ["input": options.input(environmentID: environmentID)], as: Answer.self
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

  public func destroySandbox(_ id: String, environmentID: String) async throws {
    struct Answer: Decodable {
      struct Sandbox: Decodable { let id: String }
      let sandboxDestroy: Sandbox?
    }
    _ = try await query(
      "mutation sandboxDestroy($id: String!, $environmentId: String!) { sandboxDestroy(id: $id, "
        + "environmentId: $environmentId) { id status } }",
      variables: ["id": .string(id), "environmentId": .string(environmentID)], as: Answer.self)
  }

  /// The user's own ssh keys on the account, as their public key lines.
  public func sshPublicKeys() async throws -> [String] {
    struct Answer: Decodable {
      struct Connection: Decodable {
        struct Edge: Decodable {
          struct Node: Decodable { let publicKey: String }
          let node: Node
        }
        let edges: [Edge]
      }
      let sshPublicKeys: Connection
    }
    return try await query(
      "query sshPublicKeys { sshPublicKeys { edges { node { id publicKey } } } }",
      as: Answer.self
    ).sshPublicKeys.edges.map(\.node.publicKey)
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
}

extension RailwayAPI {
  /// Every sandbox in `environmentID`, page by page; destroyed ones are listed too.
  public func sandboxes(environmentID: String) async throws -> [RailwaySandbox] {
    struct Answer: Decodable {
      struct Connection: Decodable {
        struct Edge: Decodable { let node: RailwaySandbox }
        struct PageInfo: Decodable {
          let hasNextPage: Bool
          let endCursor: String?
        }
        let edges: [Edge]
        let pageInfo: PageInfo
      }
      let sandboxes: Connection
    }
    var all: [RailwaySandbox] = []
    var after: String?
    var seen: Set<String> = []
    repeat {
      var variables: [String: RailwayJSON] = [
        "environmentId": .string(environmentID), "first": 100,
      ]
      if let after { variables["after"] = .string(after) }
      let page = try await query(
        "query sandboxes($environmentId: String!, $first: Int, $after: String) { sandboxes("
          + "environmentId: $environmentId, first: $first, after: $after) { edges { node { id "
          + "status createdAt environmentId } } pageInfo { hasNextPage endCursor } } }",
        variables: variables, as: Answer.self
      ).sandboxes
      all += page.edges.map(\.node)
      // A cursor that doesn't advance (one already asked for) would ask for its pages forever.
      let next = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : nil
      after = next.flatMap { seen.insert($0).inserted ? $0 : nil }
    } while after != nil
    return all
  }
}

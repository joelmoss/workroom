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
///
/// What a create runs on its host (the identity file and the readiness of the relay) goes through
/// the command runner, so tests stub it; a host's later exchanges (`exec`, `openStream`) are
/// `HostStream`s over ssh, as on every ssh host.
public final class RailwayHostDriver: HostTerminalDriver, ProvisioningHostDriver,
  HostPresenceReporting, HostRecording, @unchecked Sendable
{
  public struct Configuration: Sendable {
    /// This Mac's environment in the `Workroom` project, where every sandbox it makes goes.
    public var environmentID: String
    public var projectID: String?
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

    public init(
      environmentID: String, projectID: String?, keys: URL,
      relayHost: String = RailwayHostDriver.relay,
      keyName: String = "Workroom on \(ProcessInfo.processInfo.hostName)",
      daemonSocket: String = "\(RailwayHostDriver.stateDirectory)/daemon/workroomd.sock",
      screens: String = "\(RailwayHostDriver.stateDirectory)/screens",
      hostSetup: HostSetup, pollInterval: Duration = .seconds(2), readyTries: Int = 150
    ) {
      self.environmentID = environmentID
      self.projectID = projectID
      self.keys = keys
      self.relayHost = relayHost
      self.keyName = keyName
      self.daemonSocket = daemonSocket
      self.screens = screens
      self.hostSetup = hostSetup
      self.pollInterval = pollInterval
      self.readyTries = readyTries
    }
  }

  /// The host descriptor's `driver` for this provider's hosts.
  public static let driverName = HostKind.railway.driver
  /// Railway's ssh relay (from its CLI's source, not its docs: ADR 0071).
  public static let relay = "ssh.railway.com"
  /// Every sandbox logs in as root, whose home holds the daemon's state and the clone (spike).
  public static let user = "root"
  public static let stateDirectory = "/root/.local/state/workroom"

  public let configuration: Configuration
  public var daemonSocket: String { configuration.daemonSocket }
  /// No supervisor on a sandbox: each connect starts the daemon when nothing listens.
  public var startsDaemon: Bool { true }
  public var hostsSleep: Bool { false }
  /// Where each host's `ssh_config`, `known_hosts` and attach logs are written.
  public let directory: URL
  private let api: RailwayAPI
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

  private func hostDirectory(_ id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString)
  }

  private func record(of host: HostID) throws -> (UUID, RailwayHostRecord) {
    guard case .remote(let id) = host, let record = hosts.withLock({ $0[id] }) else {
      throw HostDriverError.unknownHost(host)
    }
    return (id, record)
  }

  // MARK: Provisioning

  /// A sandbox of Railway's default image, region and size, with its idle timeout off, set up as
  /// a workroom's host. One that gets no further is destroyed.
  public func create() async throws -> HostID {
    let (identity, hostKey) = try await ProvisioningProgress.step(.account, report: false) {
      // One create at a time makes the key and the pin; the rest find them.
      try await RailwaySerial.shared.run {
        (try await self.macKey(), try await self.pinnedRelayKey())
      }
    }
    let sandbox = try await ProvisioningProgress.step(.machine) {
      try await api.createSandbox(environmentID: configuration.environmentID)
    }
    markPending(sandbox)
    let id = UUID()
    let record = RailwayHostRecord(
      projectID: configuration.projectID, environmentID: configuration.environmentID,
      sandboxID: sandbox, hostKey: hostKey)
    hosts.withLock { $0[id] = record }
    do {
      try await ProvisioningProgress.step(.boot) { try await awaitRunning(record) }
      try await ProvisioningProgress.step(.setup) {
        try await setUp(id, record, identity: identity)
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
    forgetPending([record.sandboxID])
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
      forgetPending([record.sandboxID])
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
      if let status = try? await api.sandboxStatus(
        record.sandboxID, environmentID: record.environmentID), Self.isGone(status)
      {
        return nil
      }
      return "Railway sandbox \(record.sandboxID): \(error.localizedDescription)"
    }
  }

  /// Until Railway says the sandbox runs. One that failed, or went, never will.
  private func awaitRunning(_ record: RailwayHostRecord) async throws {
    for _ in 0..<configuration.readyTries {
      let status = try await api.sandboxStatus(
        record.sandboxID, environmentID: record.environmentID)
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
  /// folders. A login the relay drops while the sandbox comes up is tried again; a refusal (a
  /// changed host key, a key Railway doesn't know) is final, with its reason.
  private func setUp(_ id: UUID, _ record: RailwayHostRecord, identity: String) async throws {
    let script = try configuration.hostSetup.script("railway")
    let config = try SSHTransport.writeConfiguration(
      for: target(record, identity: identity), in: hostDirectory(id))
    let command =
      "sh -s -- "
      + [id.uuidString.lowercased(), configuration.daemonSocket, configuration.screens]
      .map(PosixShell.quoted).joined(separator: " ")
    ProvisioningProgress.record("$ \(command)")
    var said = ""
    for attempt in 0..<5 {
      if attempt > 0 { try await Task.sleep(for: configuration.pollInterval) }
      let result = await runner.run(
        "/usr/bin/ssh", ["-F", config.path, SSHTransport.alias, command],
        in: NSHomeDirectory(), timeout: 120, stdin: Data(script.utf8))
      try Task.checkCancellation()
      ProvisioningProgress.record(result.stdout)
      ProvisioningProgress.record(result.stderr)
      if result.ok { return }
      said = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      if SSHTransport.isRefusal(said) { throw HostDriverError.provisioning(Self.refusal(said)) }
      // Only ssh's own failure, 255, is a link that may still come up.
      guard result.exitCode == 255 else { break }
    }
    throw HostDriverError.provisioning(
      "setting up Railway's sandbox \(record.sandboxID) failed: \(said)")
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

  // MARK: Keys

  /// This Mac's private key for the relay, made once and registered on the account unless Railway
  /// already has it (the other build's sign-in may have registered it).
  private func macKey() async throws -> String {
    let key = configuration.keys.appendingPathComponent("id_ed25519")
    let manager = FileManager.default
    if !manager.fileExists(atPath: key.path) {
      try manager.createDirectory(
        at: configuration.keys, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
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
    if let pinned = try? String(contentsOf: pin, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines), !pinned.isEmpty
    {
      return pinned
    }
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
    try FileManager.default.createDirectory(
      at: configuration.keys, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try (key + "\n").write(to: pin, atomically: true, encoding: .utf8)
    return key
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

  public func record(_ host: HostID, in descriptor: inout HostDescriptor) {
    guard case .remote(let id) = host, let record = hosts.withLock({ $0[id] }) else { return }
    descriptor.railway = record
    forgetPending([record.sandboxID])
  }

  public func adopt(_ descriptor: HostDescriptor) throws {
    guard let id = descriptor.id, let record = descriptor.railway else {
      throw HostDriverError.invalidConfiguration("the Railway host's record is incomplete")
    }
    hosts.withLock { $0[id] = $0[id] ?? record }
  }

  // MARK: ssh

  private func target(_ record: RailwayHostRecord, identity: String) -> SSHTransport.Host {
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
  /// Destroys every sandbox in this Mac's environment that no host record names (ADR 0071): what a
  /// crash between `sandboxCreate` and its record left, or a create whose cleanup failed. A sandbox
  /// has no name or label, so the environment is all that says it is this Mac's; another Mac's
  /// environment is never listed. Throws when Railway can't list the sandboxes (signed out,
  /// offline), so the sweep is owed again; returns the destroys that failed.
  ///
  /// Kept besides `recorded`: every sandbox this driver holds, whose create may not have recorded
  /// it yet, and any made within `grace`, which may be a create still under way in the other build
  /// sharing this environment (Release and Nightly, ADR 0036). A sandbox whose age Railway doesn't
  /// give in a form this reads counts as new.
  ///
  /// `onlyPending` takes only the sandboxes a create made that no record has named since
  /// (`pendingSandboxes`): for when no record names this environment, which is also what a lost
  /// config, or a launch with a throwaway `HOME` (which doesn't isolate this folder), reads, where
  /// every live sandbox would otherwise look unrecorded. With none pending it lists nothing.
  public func sweep(
    keeping recorded: Set<String>, onlyPending: Bool = false, now: Date = Date(),
    grace: TimeInterval = sweepGrace
  ) async throws -> [String] {
    let environment = configuration.environmentID
    forgetPending(recorded)
    let pending = onlyPending ? pendingSandboxes : []
    if onlyPending && pending.isEmpty { return [] }
    let kept = recorded.union(hosts.withLock { $0.values.map(\.sandboxID) })
    func old(_ sandbox: RailwaySandbox) -> Bool {
      guard let made = sandbox.createdAt.flatMap(Self.date) else { return false }
      return now.timeIntervalSince(made) >= grace
    }
    var failures: [String] = []
    for sandbox in try await api.sandboxes(environmentID: environment)
    where sandbox.environmentID == environment && !kept.contains(sandbox.id)
      && !["DESTROYED", "DESTROYING"].contains(sandbox.status) && old(sandbox)
      && (!onlyPending || pending.contains(sandbox.id))
    {
      let record = RailwayHostRecord(
        projectID: configuration.projectID, environmentID: environment, sandboxID: sandbox.id,
        hostKey: "")
      if let failure = await destroySandbox(record) {
        failures.append(failure)
      } else {
        forgetPending([sandbox.id])
      }
    }
    return failures
  }

  /// The sandboxes a create made that no record has named since, kept beside the Mac's Railway key
  /// so Release and Nightly, which share the environment, share them too. A create writes its
  /// sandbox down the moment Railway names it; recording, destroying or sweeping it takes it off.
  public var pendingSandboxes: Set<String> {
    Self.pendingLock.withLock { readPending() }
  }

  private static let pendingLock = NSLock()
  private var pendingFile: URL {
    configuration.keys.appendingPathComponent("pending-sandboxes.json")
  }

  private func readPending() -> Set<String> {
    Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: pendingFile))) ?? [])
  }

  /// Best-effort: a sandbox not written down is still swept once a record names this environment.
  private func markPending(_ sandbox: String) {
    Self.pendingLock.withLock {
      let pending = readPending().union([sandbox])
      try? FileManager.default.createDirectory(
        at: configuration.keys, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try? JSONEncoder().encode(pending.sorted()).write(to: pendingFile, options: .atomic)
    }
  }

  private func forgetPending(_ sandboxes: Set<String>) {
    guard !sandboxes.isEmpty else { return }
    Self.pendingLock.withLock {
      let before = readPending()
      let pending = before.subtracting(sandboxes)
      guard pending != before else { return }
      if pending.isEmpty {
        try? FileManager.default.removeItem(at: pendingFile)
      } else {
        try? JSONEncoder().encode(pending.sorted()).write(to: pendingFile, options: .atomic)
      }
    }
  }

  /// How old an unrecorded sandbox must be before the sweep takes it: longer than any create takes
  /// to record its host (the boot and setup a create waits on), as `PendingMachines.grace`.
  public static let sweepGrace: TimeInterval = PendingMachines.grace

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
  /// A sandbox in `environmentID` that never idles out (ADR 0071): its id.
  public func createSandbox(environmentID: String) async throws -> String {
    struct Answer: Decodable {
      struct Sandbox: Decodable { let id: String }
      let sandboxCreate: Sandbox
    }
    return try await query(
      "mutation sandboxCreate($input: SandboxCreateInput!) { sandboxCreate(input: $input) "
        + "{ id status } }",
      variables: [
        "input": ["environmentId": .string(environmentID), "idleTimeoutMinutes": 0]
      ], as: Answer.self
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
      after = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : nil
    } while after != nil
    return all
  }
}

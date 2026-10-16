import AgentConnection
import CryptoKit
import Foundation
import WorkroomSystem
import WorkroomVCS
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
/// - **A new user** (`ExeDevSetup`): the driver can make `~/.ssh/id_ed25519` when ssh has no default
///   key, add exe.dev's gateway key to the user's known_hosts once it matches the published
///   fingerprint, and run exe.dev's sign-up over the user's ssh. Debug builds can swap the user's
///   ssh config for `-F $WR_EXEDEV_SSH_CONFIG` (`testConfig`).
///
/// exe.dev has no stop, start or idle timer, and its VMs were never put to sleep while idle
/// (spike), so nothing here reads presence or keeps a box awake.
public final class ExeDevHostDriver: HostTerminalDriver, @unchecked Sendable {
  public struct Configuration: Sendable {
    /// What every VM this driver makes is named after.
    public var prefix: String
    /// The exe.dev account this driver's VMs belong to, `whoami`'s email, or nil to accept any.
    /// Checked before every create, destroy and rollback: another account's VM reads as
    /// "not found", which `destroy` would take for gone. Whoever records a host records this.
    public var account: String?
    /// The agent's socket on every host, on the home disk: the agent's binary is installed beside
    /// it, and `/run` is a tmpfs (spike).
    public var agentSocket: String
    /// Where the supervisor has the agent keep each session's last screen (#232).
    public var screens: String
    /// The user's ssh-agent socket, or nil for none. Their `IdentityAgent`, if set, wins.
    public var sshAgent: String?

    public init(
      prefix: String = "workroom", account: String? = nil,
      agentSocket: String = "\(ExeDevHostDriver.stateDirectory)/agent/agent.sock",
      screens: String = "\(ExeDevHostDriver.stateDirectory)/screens",
      sshAgent: String? = ExeDevHostDriver.userSSHAgent()
    ) {
      self.prefix = prefix
      self.account = account
      self.agentSocket = agentSocket
      self.screens = screens
      self.sshAgent = sshAgent
    }
  }

  /// The host descriptor's `driver` for this provider's hosts.
  public static let driverName = "exedev"
  /// The user every exe.dev VM logs in as (exeuntu's `exe.dev/login-user`).
  public static let user = "exedev"
  public static let stateDirectory = "/home/\(user)/.local/state/workroom"
  public static let lobby = "exe.dev"
  /// The gateway's key's fingerprint as exe.dev publishes it (`ssh exe.dev doc faq/host-key`): quoted
  /// in the error that asks the user to sign in once, and the only key `trustGatewayKey` writes to
  /// the user's known_hosts (`verifiedGatewayKey`).
  public static let gatewayFingerprint = "SHA256:JJOP/lwiBGOMilfONPWZCXUrfK154cnJFXcqlsi6lPo"

  public let configuration: Configuration
  public var agentSocket: String { configuration.agentSocket }
  /// Where each host's attach logs are kept.
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
    subsystem: "com.developwithstyle.workroom", category: "ExeDevHostDriver")

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

  /// A fresh VM, set up as a workroom's host: the identity unit has minted its identity and the
  /// supervisor is waiting for an agent. A VM that gets no further is removed.
  public func create() async throws -> HostID {
    // The app announces the account step itself (it asks before the driver does): only its log here.
    try await ProvisioningProgress.step(.account, report: false) { try await checkAccount() }
    let id = UUID()
    let name = name(of: id)
    try markPending(id)
    do {
      try await ProvisioningProgress.step(.machine) {
        _ = try await cli(["new", "--name", name, "--no-email"])
      }
      try await ProvisioningProgress.step(.boot) { try await awaitBoot(of: id) }
      try await ProvisioningProgress.step(.setup) {
        let command =
          "sudo sh -s -- "
          + [Self.user, configuration.agentSocket, configuration.screens]
          .map(PosixShell.quoted).joined(separator: " ")
        // Command lines only: the scripts on stdin are never logged.
        ProvisioningProgress.record("$ \(command)")
        let (status, output) = try await exec(command, on: .remote(id))
          .communicate(Data(try HostSetup.systemdScript().utf8), timeout: 120)
        ProvisioningProgress.record(output)
        guard status == 0 else {
          throw HostDriverError.provisioning("setting up \(name) failed: \(output)")
        }
        // git and gh reach GitHub through exe.dev's integration, never with a token on the VM.
        let integrationCommand = "sudo sh -s -- /etc/profile.d"
        ProvisioningProgress.record("$ \(integrationCommand)")
        let (gitStatus, gitOutput) = try await exec(integrationCommand, on: .remote(id))
          .communicate(Data(try HostSetup.exeDevGitHubScript().utf8), timeout: 30)
        ProvisioningProgress.record(gitOutput)
        guard gitStatus == 0 else {
          throw HostDriverError.provisioning("setting up git on \(name) failed: \(gitOutput)")
        }
        try await awaitIdentity(of: id, named: name)
      }
      return .remote(id)
    } catch {
      try await undo(error, id: id)
    }
  }

  /// Gives this account's VMs `owner/name` through an exe.dev GitHub integration, adding one when
  /// none that new VMs can use names it, so a create needs nothing done in Terminal first. The
  /// integration acts as the user (pushes are theirs), is attached to every VM (`auto:all`), and
  /// outlives the workroom, for the project's next one. When exe.dev won't add one (its GitHub App
  /// isn't installed for the owner, as for a public upstream), the create carries on: exe.dev serves
  /// public repositories with no integration, and a private one fails at the clone with
  /// `credentialHint`. A repository on another host than github.com is left to the clone.
  public func grantGitHub(host: String, owner: String, name: String) async throws {
    guard host == "github.com" else { return }
    try await checkAccount()
    let slug = "\(owner)/\(name)"
    if try await hasGitHubIntegration(for: slug) { return }
    do {
      _ = try await cli([
        "integrations", "add", "github", "--name", Self.integrationName(owner: owner, name: name),
        "--repository", slug, "--act-as-user", "--attach", "auto:all",
      ])
    } catch let failure as CLIFailure {
      Self.logger.notice(
        "no integration for \(slug, privacy: .public): \(failure.said, privacy: .public)")
    }
  }

  /// Whether a GitHub integration that a new VM can use names `slug` (`owner/name`): attached to
  /// every VM and acting as the user. One attached to a single VM, or acting as exe.dev's App, would
  /// leave the clone without access or the pushes under the App's name.
  private func hasGitHubIntegration(for slug: String) async throws -> Bool {
    let output: String
    do { output = try await cli(["integrations", "list"]) } catch let failure as CLIFailure {
      throw HostDriverError.provisioning(failure.localizedDescription)
    }
    // `list` prints one JSON array, not the objects `jsonObjects` reads (spike, 2026-10-12).
    guard let integrations = try? JSONDecoder().decode([Integration].self, from: Data(output.utf8))
    else {
      throw HostDriverError.provisioning(
        "exe.dev said something unreadable about its integrations: \(output)")
    }
    return integrations.contains {
      $0.type == "github" && ($0.attachments ?? []).contains("auto:all")
        && $0.config?.actAsUser == true
        && ($0.config?.repositories ?? []).contains {
          $0.caseInsensitiveCompare(slug) == .orderedSame
        }
    }
  }

  /// `workroom-<owner>-<name>-<hash>`, as exe.dev takes a name: lowercase letters, digits and
  /// hyphens, at most 63 characters (spike, 2026-10-12). The hash of `owner/name` keeps apart the
  /// repositories the rest maps alike (`my.app` and `my-app`, `a-b/c` and `a/b-c`, long names).
  public static func integrationName(owner: String, name: String) -> String {
    let slug = "\(owner)/\(name)".lowercased()
    let hash = SHA256.hash(data: Data(slug.utf8)).prefix(4).map { String(format: "%02x", $0) }
      .joined()
    let raw = "workroom-\(owner)-\(name)".lowercased()
    let trimmed = String(
      String(raw.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        .replacingOccurrences(of: "-+", with: "-", options: .regularExpression).prefix(54))
    return String(trimmed.reversed().drop { $0 == "-" }.reversed()) + "-" + hash
  }

  /// Removes the VM. One already gone counts as removed, so a caller retrying after a later step
  /// of its own failed gets past the destroy it already did.
  public func destroy(_ host: HostID) async throws {
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
      .init(id: id, driver: Self.driverName, account: configuration.account),
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

  /// Refuses to act while exe.dev answers as another account than this driver's.
  private func checkAccount() async throws {
    let email = try await signedIn()
    if let expected = configuration.account, email != expected {
      throw HostDriverError.invalidConfiguration(
        "exe.dev knows your ssh key as \(email), but this workroom's VMs are in \(expected)'s"
          + " account; use that account's key")
    }
  }

  /// The account exe.dev knows the user's key as, `whoami`'s email. Throws `SignInRequired` when
  /// the user's ssh can't sign in to exe.dev yet.
  public func signedIn() async throws -> String {
    let result = await run(["whoami", "--json"], timeout: 120)
    try Task.checkCancellation()
    switch Self.account(from: result) {
    case .signedIn(let email): return email
    case .needsSignUp, .unknownHostKey, .noUsableKey:
      throw SignInRequired(said: Self.errorLine(result) ?? "exited \(result.exitCode)")
    case .failed(let said):
      // Answered, but not with an account: say what it printed.
      if result.ok { return try decode(Whoami.self, result.stdout, "the signed-in account").email }
      throw HostDriverError.provisioning("exe.dev whoami: \(said)")
    }
  }

  /// The user's ssh can't sign in to exe.dev yet: `ExeDevSetup` walks them through it.
  public struct SignInRequired: Error, LocalizedError {
    public let said: String
    public var errorDescription: String? { "exe.dev can't sign you in yet: \(said)" }
  }

  // MARK: Setting up a new user (`ExeDevSetup`)

  /// What `whoami` says about the user's ssh and exe.dev account (spike, 2026-10-12).
  public enum Account: Equatable, Sendable {
    case signedIn(String)
    /// exe.dev doesn't know the key: "Please complete registration by running: ssh exe.dev" on
    /// stdout, exit 1.
    case needsSignUp
    /// The user's known_hosts has no key for exe.dev, which `BatchMode` refuses: 255.
    case unknownHostKey
    /// ssh offered no key: none exists, or one has a passphrase and isn't in the agent. ssh's words.
    case noUsableKey(String)
    case failed(String)
  }

  public func account() async -> Account {
    Self.account(from: await run(["whoami", "--json"], timeout: 60))
  }

  public static func account(from result: CommandResult) -> Account {
    if result.ok,
      let whoami = jsonObjects(result.stdout).compactMap({
        try? JSONDecoder().decode(Whoami.self, from: $0)
      }).last
    {
      return .signedIn(whoami.email)
    }
    if result.stdout.contains("complete registration") { return .needsSignUp }
    if result.exitCode == 255, result.stderr.contains("Host key verification failed") {
      return .unknownHostKey
    }
    if result.exitCode == 255, result.stderr.contains("Permission denied") {
      let said = result.stderr.split(separator: "\n").last.map(String.init) ?? "Permission denied"
      return .noUsableKey(said.trimmingCharacters(in: .whitespaces))
    }
    return .failed(
      errorLine(result) ?? (result.timedOut ? "timed out" : "exited \(result.exitCode)"))
  }

  /// Whether exe.dev's GitHub connection works: `--verify` ticks each connected account
  /// (`  joelmoss ✓`) and says "No GitHub accounts connected." otherwise, exit 0 both ways. It
  /// takes no `--json` (spike, 2026-10-12). Any other exit or answer is a check that couldn't
  /// answer, which throws rather than reading as "not connected".
  public func gitHubConnected() async throws -> Bool {
    let result = await run(["integrations", "setup", "github", "--verify"], timeout: 60)
    try Task.checkCancellation()
    guard result.ok else {
      throw CLIFailure(
        command: "integrations",
        said: Self.errorLine(result)
          ?? (result.timedOut ? "timed out after 60s" : "exited \(result.exitCode)"))
    }
    if result.stdout.contains("✓") { return true }
    if result.stdout.contains("No GitHub accounts connected") { return false }
    throw CLIFailure(
      command: "integrations",
      said:
        "an answer Workroom doesn't know: \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))"
    )
  }

  /// Whether the account's plan lets it make VMs: a new account's is Basic with `max_vms` 0, and
  /// `new` refuses it until a plan is chosen (spike, 2026-10-12). `paid` is no guide.
  public func planAllowsVMs() async throws -> Bool {
    struct Plan: Decodable {
      let maxVMs: Int
      enum CodingKeys: String, CodingKey { case maxVMs = "max_vms" }
    }
    do {
      return try decode(Plan.self, try await cli(["billing", "plan"]), "your plan").maxVMs > 0
    } catch let failure as CLIFailure {
      throw HostDriverError.provisioning(failure.localizedDescription)
    }
  }

  /// A one-time link that signs the browser in to this account and lands on `path` of exe.dev, so
  /// a step on the website is the account the app uses, whoever the browser was signed in as.
  /// Single use: mint one per click.
  public func magicLink(to path: String) async throws -> URL {
    struct Link: Decodable {
      let url: String
      enum CodingKeys: String, CodingKey { case url = "magic_link" }
    }
    let link: Link
    do { link = try decode(Link.self, try await cli(["browser"]), "a sign-in link") } catch let
      failure as CLIFailure
    {
      throw HostDriverError.provisioning(failure.localizedDescription)
    }
    guard let url = Self.url(link.url, redirectingTo: path) else {
      throw HostDriverError.provisioning("exe.dev gave an unusable sign-in link")
    }
    return url
  }

  /// `link` with `redirect=path`, `/` and `#` escaped so the fragment survives (spike: lands on
  /// `/integrations#github`).
  public static func url(_ link: String, redirectingTo path: String) -> URL? {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    guard let redirect = path.addingPercentEncoding(withAllowedCharacters: allowed) else {
      return nil
    }
    return URL(string: link + (link.contains("?") ? "&" : "?") + "redirect=" + redirect)
  }

  /// Adds exe.dev's gateway key to the known_hosts file the user's ssh reads, once it matches the
  /// published fingerprint: what answering ssh's first-connection prompt would do, so a user who has
  /// never run `ssh exe.dev` sees no prompt. exe.dev presents one RSA key (spike, 2026-10-12).
  public func trustGatewayKey() async throws {
    let home = NSHomeDirectory()
    let scan = await runner.runNetwork(
      "/usr/bin/ssh-keyscan", ["-t", "rsa", Self.lobby], in: home, timeout: 30)
    // ssh-keyscan reads no ssh config, so a user who reaches exe.dev through a proxy gets nothing.
    guard Self.hasScannedKey(scan.stdout) else {
      let said = scan.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      throw HostDriverError.provisioning(
        "Workroom couldn't reach exe.dev to read its host key"
          + (said.isEmpty ? "" : " (\(said))") + ". If you reach exe.dev through a proxy, run "
          + "`ssh exe.dev` in Terminal once and check its key is \(Self.gatewayFingerprint).")
    }
    guard let line = Self.verifiedGatewayKey(in: scan.stdout) else {
      throw HostDriverError.provisioning(
        "exe.dev's host key doesn't match its published fingerprint (\(Self.gatewayFingerprint)),"
          + " so Workroom won't trust it. Check your network, or run `ssh exe.dev` in Terminal.")
    }
    let resolved = await runner.run(
      "/usr/bin/ssh", Self.testConfig + ["-G", Self.lobby], in: home, timeout: 10)
    guard let path = Self.knownHostsFile(in: resolved.stdout) else {
      throw HostDriverError.provisioning("ssh named no known_hosts file for exe.dev")
    }
    try Self.appendKnownHost(line, to: URL(fileURLWithPath: path))
  }

  /// Appends `line` to the known_hosts `file`, on a line of its own, making the file and its
  /// directory (0700) when they don't exist.
  public static func appendKnownHost(_ line: String, to file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    if !FileManager.default.fileExists(atPath: file.path) {
      FileManager.default.createFile(atPath: file.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    // A file that doesn't end in a newline would glue this entry to its last one.
    let existing = (try? Data(contentsOf: file)) ?? Data()
    let lead = existing.last.map { $0 == UInt8(ascii: "\n") ? "" : "\n" } ?? ""
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((lead + line + "\n").utf8))
  }

  /// Whether `ssh-keyscan` printed a key at all, as against one that doesn't match.
  public static func hasScannedKey(_ scan: String) -> Bool {
    scan.split(separator: "\n").contains {
      !$0.hasPrefix("#") && $0.split(separator: " ").count >= 3
    }
  }

  /// The `exe.dev <type> <key>` line of `ssh-keyscan`'s output whose key's SHA256 fingerprint is
  /// `fingerprint`, or nil when none is.
  public static func verifiedGatewayKey(in scan: String, fingerprint: String = gatewayFingerprint)
    -> String?
  {
    for line in scan.split(separator: "\n") where !line.hasPrefix("#") {
      let fields = line.split(separator: " ")
      guard fields.count >= 3, let blob = Data(base64Encoded: String(fields[2])) else { continue }
      let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
      if "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "=")) == fingerprint {
        return "\(lobby) \(fields[1]) \(fields[2])"
      }
    }
    return nil
  }

  /// The first file `ssh -G`'s `userknownhostsfile` names, `~` expanded.
  public static func knownHostsFile(in resolved: String) -> String? {
    for line in resolved.split(separator: "\n") where line.hasPrefix("userknownhostsfile ") {
      guard let first = line.split(separator: " ").dropFirst().first else { return nil }
      return (String(first) as NSString).expandingTildeInPath
    }
    return nil
  }

  /// ssh's default identities, which it offers when no config names one. OpenSSH 10 lists the
  /// first five; older ones (macOS 15's) and builds with XMSS add `id_dsa` and `id_xmss`.
  public static let defaultKeyNames = [
    "id_rsa", "id_ecdsa", "id_ecdsa_sk", "id_ed25519", "id_ed25519_sk", "id_dsa", "id_xmss",
  ]

  /// Whether `~/.ssh` holds one of ssh's default identities.
  public static func hasDefaultKey(in directory: URL = sshDirectory) -> Bool {
    defaultKeyNames.contains {
      FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
    }
  }

  public static var sshDirectory: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh", isDirectory: true)
  }

  /// Whether making `~/.ssh/id_ed25519` would give ssh a key for exe.dev: the user's ssh config
  /// names no identity of its own and no agent, and none of ssh's default keys exists. A config
  /// that names one has a key ssh couldn't use (locked, or its passphrase outside the agent), and
  /// a new default key would not be offered in its place.
  public func mayCreateDefaultKey() async -> Bool {
    let resolved = await runner.run(
      "/usr/bin/ssh", Self.testConfig + ["-G", Self.lobby], in: NSHomeDirectory(), timeout: 10)
    guard resolved.ok else { return !Self.hasDefaultKey() }
    return Self.mayCreateDefaultKey(resolved: resolved.stdout)
  }

  /// `mayCreateDefaultKey` for `ssh -G`'s output: only ssh's default identities, all missing from
  /// `directory`, and no `identityagent`.
  public static func mayCreateDefaultKey(resolved: String, in directory: URL = sshDirectory) -> Bool
  {
    let lines = resolved.split(separator: "\n").map(String.init)
    if lines.contains(where: { $0.hasPrefix("identityagent ") && $0 != "identityagent none" }) {
      return false
    }
    let defaults = Set(defaultKeyNames.map { directory.appendingPathComponent($0).path })
    let identities = lines.filter { $0.hasPrefix("identityfile ") }
      .map { (String($0.dropFirst("identityfile ".count)) as NSString).expandingTildeInPath }
    return identities.allSatisfy(defaults.contains) && !hasDefaultKey(in: directory)
  }

  /// Makes `id_ed25519` in `directory` with no passphrase: the identity ssh offers by default, so
  /// `ssh exe.dev` in Terminal signs in with it too. Never over a default identity already there.
  public func createDefaultKey(in directory: URL = sshDirectory) async throws {
    guard !Self.hasDefaultKey(in: directory) else { return }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let result = await runner.run(
      "/usr/bin/ssh-keygen",
      ["-q", "-t", "ed25519", "-N", "", "-f", directory.appendingPathComponent("id_ed25519").path],
      in: NSHomeDirectory(), timeout: 30)
    guard result.ok else {
      throw HostDriverError.provisioning(
        "ssh-keygen couldn't make a key: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
      )
    }
  }

  /// `ssh exe.dev` as a terminal runs it, for a user finishing exe.dev's sign-up by hand
  /// (`ExeDevSetupSheet`'s fallback): the driver's own ssh agent and test config.
  public var signInCommand: String {
    let agent = configuration.sshAgent.map { ["/usr/bin/env", "SSH_AUTH_SOCK=\($0)"] } ?? []
    return (agent + ["/usr/bin/ssh"] + Self.testConfig + [Self.lobby]).map(PosixShell.quoted)
      .joined(separator: " ")
  }

  /// Starts exe.dev's sign-up over the user's own ssh, as `ssh exe.dev` with a key it doesn't know
  /// runs it. Needs no terminal: its stdin's EOF cancels it ("Registration cancelled."), so the
  /// session stays open until `SignUp.end` (spike, 2026-10-12).
  public func signUp() throws -> SignUp {
    var environment = configuration.sshAgent.map { ["SSH_AUTH_SOCK": $0] } ?? [:]
    environment["PATH"] = ShellEnvironment.path()
    return SignUp(
      stream: try HostStream.spawn(
        URL(fileURLWithPath: "/usr/bin/ssh"), Self.sshOptions + [Self.lobby],
        environment: environment, handshakeTimeout: 20, purpose: .connection))
  }

  /// One sign-up session: exe.dev asks "Please enter your email address: ", then says
  /// "Verification email sent to: <email>" and "Waiting for verification...", and holds the
  /// session until the link is clicked (spike, 2026-10-12).
  public final class SignUp: @unchecked Sendable {
    public enum Outcome: Equatable {
      /// exe.dev sent the link and is waiting for it.
      case sent
      /// exe.dev said something else: its words.
      case said(String)
    }

    private let stream: HostStream

    public init(stream: HostStream) { self.stream = stream }

    deinit { stream.end() }

    /// Answers the email prompt with `email` and says how exe.dev took it. When exe.dev said
    /// nothing at all, the words are ssh's own (it never got in).
    public func submit(_ email: String) async -> Outcome {
      let outcome = await answer(email)
      guard outcome == .said("") else { return outcome }
      return .said(await stream.failure())
    }

    /// Until the session ends: exe.dev drops a sign-up whose connection is lost before its link is
    /// clicked, and holds one whose link was clicked until `end`.
    public func waitForEnd() async {
      let descriptor = stream.descriptor
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
          var buffer = [UInt8](repeating: 0, count: 4096)
          while Darwin.read(descriptor, &buffer, buffer.count) > 0 {}
          continuation.resume()
        }
      }
    }

    private func answer(_ email: String) async -> Outcome {
      let descriptor = stream.descriptor
      return await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
          var heard = ""
          guard Self.read(descriptor, into: &heard, until: { $0.contains("email address:") })
          else {
            continuation.resume(returning: .said(heard.isEmpty ? "" : Self.lastWords(heard)))
            return
          }
          let line = Array((email + "\n").utf8)
          guard
            line.withUnsafeBytes({ Darwin.write(descriptor, $0.baseAddress, $0.count) })
              == line.count
          else {
            continuation.resume(returning: .said("exe.dev closed the connection"))
            return
          }
          var answer = ""
          _ = Self.read(descriptor, into: &answer) {
            $0.contains("Verification email sent") || $0.contains("email address:")
          }
          continuation.resume(
            returning: answer.contains("Verification email sent")
              ? .sent : .said(Self.lastWords(answer)))
        }
      }
    }

    /// Ends the session; exe.dev drops a sign-up still waiting.
    public func end() { stream.end() }

    /// Reads into `text` until `done` holds of it, 30 s pass in silence, or the stream ends.
    private static func read(
      _ descriptor: Int32, into text: inout String, until done: (String) -> Bool
    ) -> Bool {
      var buffer = [UInt8](repeating: 0, count: 4096)
      var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      while !done(text) {
        guard Darwin.poll(&poller, 1, 30_000) > 0 else { return false }
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return false }
        text += String(decoding: buffer[..<count], as: UTF8.self)
      }
      return true
    }

    /// The last thing exe.dev said, without its colours, prompt or banner.
    public static func lastWords(_ text: String) -> String {
      let plain = text.replacingOccurrences(
        of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
      let lines = plain.components(separatedBy: CharacterSet.newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("Please enter your email") }
      return lines.last ?? "exe.dev didn't answer"
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

  public struct Whoami: Decodable { let email: String }

  /// One entry of `integrations list`: a GitHub one's config names its repositories.
  private struct Integration: Decodable {
    struct Config: Decodable {
      let repositories: [String]?
      let actAsUser: Bool?
      enum CodingKeys: String, CodingKey {
        case repositories
        case actAsUser = "act_as_user"
      }
    }
    let type: String
    let attachments: [String]?
    let config: Config?
  }

  public struct Removal: Decodable {
    public let deleted: [String]
    public let failed: [String]
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
    // The command as typed, without ssh's options (they name the agent socket and the config).
    ProvisioningProgress.record(command: "ssh", [Self.lobby] + arguments)
    let result = await runner.runNetwork(
      "/usr/bin/ssh", Self.sshOptions + [Self.lobby] + arguments,
      in: NSHomeDirectory(), timeout: timeout)
    ProvisioningProgress.record(result.stdout)
    ProvisioningProgress.record(result.stderr)
    return result
  }

  /// exe.dev's error from a command's output: `{"error": "..."}`, printed on stdout and stderr
  /// alike (spike), or ssh's own message when it never got in.
  public static func errorLine(_ result: CommandResult) -> String? {
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
    // exe.dev prints a few answers as plain text on stdout, as for a key it doesn't know yet.
    let said = (result.stderr + "\n" + result.stdout).split(separator: "\n").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.first { !$0.isEmpty && !$0.hasPrefix("{") }
    return said.map { $0.hasPrefix("error: ") ? String($0.dropFirst(7)) : $0 }
  }

  /// Each line of `output` that is a JSON object, in order: `rm` prints two (spike).
  public static func jsonObjects(_ output: String) -> [Data] {
    output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.hasPrefix("{") }.map { Data($0.utf8) }
  }

  /// exe.dev's answer for a VM that doesn't exist: `VM "<name>" not found`, or `vm "<name>" not
  /// found` from `cp` (spike). Matched whole, so a transport failure that happens to say "not
  /// found" is never taken for a removal.
  public static func isNotFound(_ said: String) -> Bool {
    (said.hasPrefix("VM \"") || said.hasPrefix("vm \"")) && said.hasSuffix("\" not found")
      && !said.dropFirst(4).dropLast(11).contains("\"")
  }

  // MARK: ssh

  /// What Workroom sets over the user's own ssh configuration, which supplies the rest (keys,
  /// agent, Keychain, proxies), as for `ssh exe.dev` in Terminal. A background link can't prompt,
  /// takes a VM's key to be the gateway's, forwards nothing to a VM an agent works on, and notices
  /// a dead link (#228); a pane's ssh reads no escapes from what is typed in it. A pane's `-t`
  /// outranks `RequestTTY`.
  public static let sshOptions =
    testConfig
    + [
      "BatchMode=yes", "HostKeyAlias=\(lobby)", "ForwardAgent=no", "ForwardX11=no",
      "ClearAllForwardings=yes", "ControlMaster=no", "ControlPath=none", "RemoteCommand=none",
      "EscapeChar=none", "RequestTTY=no", "ServerAliveInterval=15", "ServerAliveCountMax=3",
      "ConnectTimeout=10",
      "LogLevel=ERROR",
    ].flatMap { ["-o", $0] }

  /// Debug builds only: `-F $WR_EXEDEV_SSH_CONFIG`, an ssh config standing in for the user's own, so
  /// a developer can be a user exe.dev has never seen (a fresh key, an empty `known_hosts`) without
  /// touching their own (`Scripts/exedev-fresh-user.sh`).
  private static let testConfig: [String] = {
    #if DEBUG
      if let path = ProcessInfo.processInfo.environment["WR_EXEDEV_SSH_CONFIG"], !path.isEmpty {
        return ["-F", path]
      }
    #endif
    return []
  }()

  /// The user's ssh-agent socket: the app's own environment's, else the login shell's, where an
  /// agent such as 1Password's is set (`StatusCommandRunner.forwardedAuthKeys`).
  public static func userSSHAgent(
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
  public func route(_ id: UUID, spawned: Bool) -> SSHTransport.Route {
    var environment = configuration.sshAgent.map { ["SSH_AUTH_SOCK": $0] } ?? [:]
    if spawned { environment["PATH"] = ShellEnvironment.path() }
    return SSHTransport.Route(
      options: Self.sshOptions, destination: "\(Self.user)@\(name(of: id)).exe.xyz",
      environment: environment)
  }

  public func openStream(to host: HostID) async throws -> HostStream {
    let id = try id(of: host)
    return try SSHTransport.exec(
      SSHTransport.relayCommand(
        binary: AgentInstall.binary(besideSocket: agentSocket), socket: agentSocket),
      via: route(id, spawned: true), purpose: .connection)
  }

  public func exec(_ command: String, on host: HostID) async throws -> HostStream {
    try SSHTransport.exec(
      command, via: route(try id(of: host), spawned: true), purpose: .exchange)
  }

  public func attachCommand(
    to host: HostID, session: UUID, workingDirectory: String, restored: Bool,
    metadata: [(key: String, value: String)]
  ) throws -> String {
    let id = try id(of: host)
    try FileManager.default.createDirectory(
      at: hostDirectory(id), withIntermediateDirectories: true)
    return SSHTransport.attachCommand(
      via: route(id, spawned: false), in: hostDirectory(id), agentSocket: agentSocket,
      session: session,
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

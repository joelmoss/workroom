import CryptoKit
import XCTest

@testable import Workroom

/// The exe.dev driver (#259) with exe.dev's ssh API stubbed: the key it signs in with, the gateway
/// key it trusts, its account guard, what it refuses to derive from, and how it reads `rm`. What it
/// runs on a VM (setup, `sync`, the readiness waits) goes over real ssh, so the live suite covers it.
final class ExeDevHostDriverTests: XCTestCase {
  /// exe.dev's gateway key, as `ssh exe.dev` records it in `known_hosts` (2026-10-08).
  static let gateway =
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDEKtEcRW8OBtro5B/MG+EaisD+ZVwwHFa5m7M8wFwBlMmPJJssY+1aGBRW3b9InAeCnTU2Kt7gazqbg/9od1KnK6x5piQNVQZ4C/lrjsC2ScBrOydnw9ry9G2+voFCAk+dQGabIrIT6gqqDJNOqxgFiG/lA3Xx6KwpfwI2BH5f3ab2fHCR2BGAC5jlB2RJXPgly80hMxYEHqexhJxYRwC+deeLrQSG795we9rSzPmdz58t9+9jLTKkyyqWKe/hmBvty1AYrEmRsefu6/TUrIGi/UWJfa+RBIQtFgWqN6xT1F6rRwELeVOfwwr5tZbsmgWY5frZU3EOtVWcF7Ve3gfL"

  /// The published fingerprint is the gateway key's: an error that asks the user to accept the key
  /// names the one exe.dev documents (`ssh exe.dev doc faq/host-key`).
  func testThePublishedFingerprintIsTheGatewayKeys() {
    XCTAssertEqual(
      ExeDevHostDriver.fingerprint(publicKey: Self.gateway), ExeDevHostDriver.gatewayFingerprint)
  }

  /// The gateway key comes from the user's own `known_hosts`, plain or hashed, and from no other
  /// host's line or marker line.
  func testTheGatewayKeyIsReadFromKnownHostsPlainOrHashed() {
    XCTAssertEqual(
      ExeDevHostDriver.gatewayKey(
        knownHosts: "other.example ssh-ed25519 AAAA\nexe.dev \(Self.gateway)\n"), Self.gateway)
    XCTAssertEqual(
      ExeDevHostDriver.gatewayKey(knownHosts: "exe.dev,1.2.3.4 \(Self.gateway) comment"),
      Self.gateway)
    // `ssh-keygen -H` of `exe.dev <key>`.
    XCTAssertEqual(
      ExeDevHostDriver.gatewayKey(
        knownHosts: "|1|1te+WPYkoFuiqF0FEFFyKXyKtQE=|OHAjt6yCr/ZhL2BhQicbdlFYrnw= \(Self.gateway)"),
      Self.gateway)
    XCTAssertNil(
      ExeDevHostDriver.gatewayKey(
        knownHosts: "|1|1te+WPYkoFuiqF0FEFFyKXyKtQE=|AAAAt6yCr/ZhL2BhQicbdlFYrnw= \(Self.gateway)"))
    XCTAssertNil(ExeDevHostDriver.gatewayKey(knownHosts: "@revoked exe.dev \(Self.gateway)"))
    XCTAssertNil(ExeDevHostDriver.gatewayKey(knownHosts: "notexe.dev \(Self.gateway)"))
  }

  /// Both of exe.dev's not-found answers, matched whole: anything else is not a removal.
  func testNotFoundIsExeDevsAnswerMatchedWhole() {
    XCTAssertTrue(ExeDevHostDriver.isNotFound(#"VM "workroom-x" not found"#))
    XCTAssertTrue(ExeDevHostDriver.isNotFound(#"vm "workroom-x" not found"#))
    XCTAssertFalse(ExeDevHostDriver.isNotFound("not found"))
    XCTAssertFalse(ExeDevHostDriver.isNotFound(#"VM "a" is fine, "b" not found"#))
    XCTAssertFalse(ExeDevHostDriver.isNotFound("ssh: Could not resolve hostname: not found"))
  }

  /// The ssh-agent is the app's own when it was launched with one, else the login shell's.
  func testTheSSHAgentIsTheAppsElseTheShells() {
    XCTAssertEqual(
      ExeDevHostDriver.userSSHAgent(
        inherited: ["SSH_AUTH_SOCK": "/app"], probed: ["SSH_AUTH_SOCK": "/shell"]), "/app")
    XCTAssertEqual(
      ExeDevHostDriver.userSSHAgent(inherited: [:], probed: ["SSH_AUTH_SOCK": "/shell"]), "/shell")
    XCTAssertNil(ExeDevHostDriver.userSSHAgent(inherited: ["SSH_AUTH_SOCK": ""], probed: [:]))
  }

  // MARK: With exe.dev stubbed

  /// Answers each lobby command from `answers` by its name, and lets in only the keys in
  /// `accepted`, by the `IdentityFile` of the config it is run with. Records every command.
  private final class StubExeDev: StatusCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(command: String, identity: String, arguments: [String])] = []
    let answers: [String: CommandResult]
    let accepted: Set<String>
    let email: String

    init(_ answers: [String: CommandResult], accepted: Set<String>, email: String = "me@x.dev") {
      self.answers = answers
      self.accepted = accepted
      self.email = email
    }

    /// Every command after the lobby's sign-ins, in order.
    var commands: [String] {
      lock.withLock { calls.map(\.command) }.filter { $0 != "whoami" }
    }
    var identities: [String] { lock.withLock { calls.map(\.identity) } }
    func arguments(of command: String) -> [String]? {
      lock.withLock { calls.last { $0.command == command }?.arguments }
    }

    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
      let config = (try? String(contentsOfFile: args[1], encoding: .utf8)) ?? ""
      let identity =
        config.split(separator: "\n").first { $0.contains("IdentityFile") }
        .map { URL(fileURLWithPath: $0.split(separator: "\"")[1].description).lastPathComponent }
        ?? ""
      let command = args[3]
      lock.withLock { calls.append((command, identity, Array(args.dropFirst(4)))) }
      guard accepted.contains(identity) else {
        return CommandResult(
          stdout: "", stderr: "exedev@exe.dev: Permission denied (publickey,keyboard-interactive).",
          exitCode: 255, timedOut: false)
      }
      if command == "whoami" { return ExeDevHostDriverTests.ok(#"{"email":"\#(email)"}"#) }
      // A rollback removes a VM the stub never made: not found, as exe.dev says it.
      if command == "rm", answers[command] == nil {
        let name = args[4]
        return ExeDevHostDriverTests.ok(
          #"{"error":"VM \"\#(name)\" not found"}"# + "\n"
            + #"{"deleted":[],"failed":["\#(name)"]}"#)
      }
      return answers[command]
        ?? CommandResult(
          stdout: #"{"error":"unexpected"}"#, stderr: "", exitCode: 1, timedOut: false)
    }
  }

  fileprivate static func ok(_ json: String) -> CommandResult {
    CommandResult(stdout: json + "\n", stderr: "", exitCode: 0, timedOut: false)
  }

  /// A driver over a scratch `~/.ssh` holding `keys` (each a pair) and, unless `knownHosts` says
  /// otherwise, the gateway's key.
  private func driver(
    _ exe: StubExeDev, keys: [String] = ["id_ed25519"], account: String? = nil,
    knownHosts: String? = nil
  ) throws -> (ExeDevHostDriver, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-exedev-\(UUID().uuidString)")
    let ssh = root.appendingPathComponent("ssh")
    try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
    for key in keys {
      try "private".write(to: ssh.appendingPathComponent(key), atomically: true, encoding: .utf8)
      let blob = Data(SHA256.hash(data: Data(key.utf8))).base64EncodedString()
      try "ssh-ed25519 \(blob) \(key)".write(
        to: ssh.appendingPathComponent("\(key).pub"), atomically: true, encoding: .utf8)
    }
    try (knownHosts ?? "exe.dev \(Self.gateway)\n").write(
      to: ssh.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return (
      ExeDevHostDriver(
        configuration: .init(account: account, sshDirectory: ssh, sshAgent: "/agent.sock"),
        directory: root.appendingPathComponent("hosts"), runner: exe),
      root
    )
  }

  /// The driver signs in with the first of the user's keys exe.dev accepts, through their agent
  /// and Keychain under `IdentitiesOnly`, and keeps using it.
  func testItSignsInWithTheKeyExeDevAccepts() async throws {
    let exe = StubExeDev([:], accepted: ["id_work"])
    let (driver, root) = try driver(exe, keys: ["id_ed25519", "id_work"])
    let email = try await driver.signedIn()
    XCTAssertEqual(email, "me@x.dev")
    _ = try await driver.signedIn()
    // Finding the key tries each in turn; each `whoami` after that uses the one that got in.
    XCTAssertEqual(exe.identities, ["id_ed25519", "id_work", "id_work", "id_work"])
    let config = try String(
      contentsOf: root.appendingPathComponent("hosts/exe.dev/ssh_config"), encoding: .utf8)
    XCTAssertTrue(config.contains("IdentitiesOnly yes"), config)
    XCTAssertTrue(config.contains(#"IdentityAgent "/agent.sock""#), config)
    XCTAssertTrue(config.contains("UseKeychain yes"), config)
    XCTAssertTrue(config.contains("User \"exedev\""), config)
    let known = try String(
      contentsOf: root.appendingPathComponent("hosts/exe.dev/known_hosts"), encoding: .utf8)
    XCTAssertEqual(known, "exe.dev \(Self.gateway)\n")
  }

  /// No key gets in: the error names each key it tried, with its fingerprint, and how to let
  /// Workroom unlock one. Nothing else runs.
  func testAKeyThatWontUnlockSaysHowToFixIt() async throws {
    let exe = StubExeDev(["new": Self.ok("{}")], accepted: [])
    let (driver, _) = try driver(exe, keys: ["id_ed25519"])
    do {
      _ = try await driver.create()
      XCTFail("created with no key that gets in")
    } catch HostDriverError.invalidConfiguration(let detail) {
      XCTAssertTrue(detail.contains("exe.dev refused every key"), detail)
      XCTAssertTrue(detail.contains("id_ed25519 (SHA256:"), detail)
      XCTAssertTrue(detail.contains("ssh-add --apple-use-keychain"), detail)
    }
    XCTAssertEqual(exe.commands, [], "a command ran without a key")
  }

  /// Without exe.dev's key in the user's `known_hosts`, nothing connects: the error says to accept
  /// it once, naming the fingerprint exe.dev publishes.
  func testWithoutTheGatewayKeyItAsksTheUserToAcceptIt() async throws {
    let exe = StubExeDev([:], accepted: ["id_ed25519"])
    let (driver, _) = try driver(exe, knownHosts: "other.example ssh-ed25519 AAAA\n")
    do {
      _ = try await driver.signedIn()
      XCTFail("signed in without the gateway's key")
    } catch HostDriverError.invalidConfiguration(let detail) {
      XCTAssertTrue(detail.contains("Run `ssh exe.dev`"), detail)
      XCTAssertTrue(detail.contains(ExeDevHostDriver.gatewayFingerprint), detail)
    }
    XCTAssertTrue(exe.identities.isEmpty, "ssh ran without a host key to check")
  }

  /// Another exe.dev account than the host's refuses every change before it is made: its VMs read
  /// as not found there, which a delete would take for gone.
  func testAnotherAccountIsRefusedBeforeAnythingChanges() async throws {
    let exe = StubExeDev(
      ["rm": Self.ok(#"{"deleted":[],"failed":[]}"#)], accepted: ["id_ed25519"],
      email: "other@x.dev")
    let (driver, _) = try driver(exe, account: "me@x.dev")
    let attempts: [() async throws -> Void] = [
      { try await driver.destroy(.remote(UUID())) },
      { _ = try await driver.create() },
      { _ = try await driver.deriveFromBase(.remote(UUID())) },
    ]
    for attempt in attempts {
      do {
        try await attempt()
        XCTFail("acted in another account")
      } catch HostDriverError.invalidConfiguration(let detail) {
        XCTAssertTrue(detail.contains("other@x.dev"), detail)
      }
    }
    XCTAssertEqual(exe.commands, [], "a change ran in another account")
  }

  /// Only a base is derived from: a VM without the base tag is a workroom, whose disk holds its
  /// own enrolment, and is refused before anything is copied. A base that's gone is unknown.
  func testOnlyATaggedBaseIsDerivedFrom() async throws {
    let base = UUID()
    let exe = StubExeDev([:], accepted: ["id_ed25519"])
    let (probe, _) = try driver(exe)
    let name = probe.name(of: base)
    for (listing, expected) in [
      (#"{"vms":[{"vm_name":"\#(name)"}]}"#, "untagged"),
      (#"{"vms":[{"vm_name":"\#(name)","tags":["prod"]}]}"#, "untagged"),
      (#"{"vms":[]}"#, "gone"),
    ] {
      let exe = StubExeDev(["ls": Self.ok(listing)], accepted: ["id_ed25519"])
      let (driver, _) = try driver(exe)
      do {
        _ = try await driver.deriveFromBase(.remote(base))
        XCTFail("derived from \(listing)")
      } catch HostDriverError.invalidConfiguration(let detail) {
        XCTAssertEqual(expected, "untagged")
        XCTAssertEqual(detail, "a workroom instance cannot be derived from")
      } catch HostDriverError.unknownHost(let host) {
        XCTAssertEqual(expected, "gone")
        XCTAssertEqual(host, .remote(base))
      }
      XCTAssertEqual(exe.commands, ["ls"], "\(listing): a copy was attempted")
      XCTAssertEqual(exe.arguments(of: "ls"), [name, "--json"])
    }
  }

  /// exe.dev failing to list the base is a provisioning error the app can show, never the driver's
  /// own failure type escaping it.
  func testAFailedListingIsAProvisioningError() async throws {
    let exe = StubExeDev(
      [
        "ls": CommandResult(
          stdout: #"{"error":"rate limited"}"#, stderr: "", exitCode: 1, timedOut: false)
      ],
      accepted: ["id_ed25519"])
    let (driver, _) = try driver(exe)
    do {
      _ = try await driver.deriveFromBase(.remote(UUID()))
      XCTFail("derived with no listing")
    } catch HostDriverError.provisioning(let detail) {
      XCTAssertEqual(detail, "exe.dev ls: rate limited")
    }
  }

  /// A base is made with the base tag, which a copy is made without.
  func testABaseIsTaggedAndARefusedOneHasNothingToRemove() async throws {
    let exe = StubExeDev(
      [
        "new": CommandResult(
          stdout: #"{"error":"VM limit reached"}"#, stderr: "", exitCode: 1, timedOut: false)
      ], accepted: ["id_ed25519"])
    let (driver, _) = try driver(exe)
    do {
      _ = try await driver.create()
      XCTFail("a refused VM became a base")
    } catch HostDriverError.provisioning(let detail) {
      XCTAssertEqual(detail, "exe.dev new: VM limit reached")
    }
    let new = try XCTUnwrap(exe.arguments(of: "new"))
    XCTAssertEqual(
      Array(new[new.firstIndex(of: "--tag")!...].prefix(2)), ["--tag", "workroom-base"])
    XCTAssertEqual(exe.commands, ["new", "rm"])
  }

  /// `rm` exits 0 whatever happened (spike), so a delete reads what it printed: deleted, or not
  /// found, is gone; anything else keeps the host and says why.
  func testADeleteReadsWhatRmPrintedNotItsStatus() async throws {
    let id = UUID()
    let exe = StubExeDev([:], accepted: ["id_ed25519"])
    let name = try driver(exe).0.name(of: id)
    for (printed, gone) in [
      (#"{"deleted":["\#(name)"],"failed":[]}"#, true),
      (
        #"{"error":"VM \"\#(name)\" not found"}"# + "\n" + #"{"deleted":[],"failed":["\#(name)"]}"#,
        true
      ),
      (#"{"error":"VM is busy"}"# + "\n" + #"{"deleted":[],"failed":["\#(name)"]}"#, false),
      ("", false),
    ] {
      let exe = StubExeDev(["rm": Self.ok(printed)], accepted: ["id_ed25519"])
      let (driver, _) = try driver(exe)
      do {
        try await driver.destroy(.remote(id))
        XCTAssertTrue(gone, "\(printed): reported gone")
      } catch HostDriverError.provisioning(let detail) {
        XCTAssertFalse(gone, "\(printed): \(detail)")
        XCTAssertTrue(detail.hasPrefix("VM \(name): "), detail)
      }
      XCTAssertEqual(exe.commands, ["rm"])
    }
  }

  /// A driver made after a relaunch attaches a pane with the key an earlier one found, before it
  /// has asked exe.dev anything itself.
  func testAPaneAfterARelaunchUsesTheKeyFoundBefore() async throws {
    let exe = StubExeDev([:], accepted: ["id_work"])
    let (first, root) = try driver(exe, keys: ["id_ed25519", "id_work"])
    _ = try await first.signedIn()
    let later = ExeDevHostDriver(
      configuration: first.configuration, directory: root.appendingPathComponent("hosts"),
      runner: exe)
    _ = try later.attachCommand(
      to: .remote(UUID()), session: UUID(), workingDirectory: "/home/exedev/r", restored: false)
    let configs = try FileManager.default.subpathsOfDirectory(
      atPath: root.appendingPathComponent("hosts").path
    ).filter { $0.hasSuffix("ssh_config") && !$0.hasPrefix("exe.dev") }
    let config = try String(
      contentsOf: root.appendingPathComponent("hosts").appendingPathComponent(
        try XCTUnwrap(configs.first)), encoding: .utf8)
    XCTAssertTrue(config.contains("id_work\""), config)
    XCTAssertTrue(config.contains(".exe.xyz\""), config)
    // And it signs in with that key first, rather than trying every key again.
    let before = exe.identities.count
    _ = try await later.signedIn()
    XCTAssertEqual(Array(exe.identities.dropFirst(before)), ["id_work", "id_work"])
  }
}

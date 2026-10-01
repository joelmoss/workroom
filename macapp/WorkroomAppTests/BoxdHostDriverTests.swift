import XCTest

@testable import Workroom

/// `BoxdHostDriver` without boxd (#256): how it reads the CLI's ssh blocks and answers, and what
/// it undoes when a step fails, with the CLI stubbed. `BoxdIntegrationTests` runs it on boxd.
final class BoxdHostDriverTests: XCTestCase {
  // What the CLI writes (measured, boxd 0.2.x), around a user's own config.
  private static let sshConfig = """
    Host *
    AddKeysToAgent yes
    IdentityFile ~/.ssh/id_ed25519

    Host workroom-1.boxd
      HostName evil.example.com
    # BEGIN boxd (managed by `boxd ssh-config`; do not edit between markers)
    Host *.boxd *.boxd.sh boxd.sh
        SetEnv BOXD_DEVICE_ID=8ec8aa2d

    Host workroom-1.boxd workroom-1.boxd.sh
        HostName workroom-1.boxd.sh
        Port 14996
        User boxd
        IdentityFile "/Users/me/Library/Application Support/boxd/id_ed25519_x"
        IdentitiesOnly yes
        ServerAliveInterval 30

    Host workroom-10.boxd workroom-10.boxd.sh
        HostName workroom-10.boxd.sh
        Port 25945
        User boxd
        IdentityFile "/Users/me/Library/Application Support/boxd/id_ed25519_x"
    # END boxd
    """
  private static let knownHosts = """
    [workroom-1.boxd.sh]:14996 ssh-ed25519 MINE
    # BEGIN boxd-hosts (managed by `boxd ssh-config`; do not edit between markers)
    [workroom-1.boxd.sh]:14996 ssh-ed25519 GATEWAY
    [workroom-10.boxd.sh]:25945 ssh-ed25519 GATEWAY
    # END boxd-hosts
    """

  func testSSHDetailsComeFromTheCLIsBlocksOnly() throws {
    let details = try XCTUnwrap(
      SSHDetails(machine: "workroom-1", sshConfig: Self.sshConfig, knownHosts: Self.knownHosts))
    XCTAssertEqual(
      details,
      SSHDetails(
        machine: "workroom-1", sshConfig: Self.sshConfig, knownHosts: Self.knownHosts))
    XCTAssertEqual(details.hostName, "workroom-1.boxd.sh", "a stanza outside the block was read")
    XCTAssertEqual(details.port, 14996)
    XCTAssertEqual(details.user, "boxd")
    XCTAssertEqual(
      details.identityFile, "/Users/me/Library/Application Support/boxd/id_ed25519_x",
      "the user's own IdentityFile was taken, or the quotes kept")
    XCTAssertEqual(details.hostKey, "ssh-ed25519 GATEWAY", "a key outside the block was pinned")
    // A name that is another's prefix is not that one.
    XCTAssertEqual(
      SSHDetails(machine: "workroom-10", sshConfig: Self.sshConfig, knownHosts: Self.knownHosts)?
        .port, 25945)
  }

  func testSSHDetailsAreNilWithoutAStanzaOrAHostKey() {
    XCTAssertNil(
      SSHDetails(machine: "workroom-2", sshConfig: Self.sshConfig, knownHosts: Self.knownHosts))
    XCTAssertNil(
      SSHDetails(machine: "workroom-1", sshConfig: Self.sshConfig, knownHosts: ""),
      "a machine with no pinned key was given one")
  }

  func testOnlyTheCLIsOwnNotFoundAnswersCountAsGone() {
    XCTAssertTrue(BoxdHostDriver.isNotFound("error: VM 'workroom-1' not found"))
    XCTAssertTrue(BoxdHostDriver.isNotFound("error: snapshot not found"))
    XCTAssertFalse(
      BoxdHostDriver.isNotFound(
        "error: cannot connect to https://boxd.sh:9443: dns error: not found"))
    XCTAssertEqual(
      BoxdHostDriver.errorLine(
        "\n  A new version of boxd is available (v0.2.20). Update with:\n"
          + "error: VM 'x' not found\n"),
      "error: VM 'x' not found")
  }

  func testTheSetupScriptShipsInTheBundle() throws {
    let script = try BoxdHostDriver.setupScript()
    XCTAssertTrue(script.contains("workroom-agent.service"))
  }

  // MARK: Failures, with the CLI stubbed

  /// Answers each CLI call from `answers`, by its first two words, and records every call.
  private final class StubCLI: StatusCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    let answers: [String: CommandResult]

    init(_ answers: [String: CommandResult]) { self.answers = answers }

    var commands: [String] { lock.withLock { calls.map { $0.prefix(2).joined(separator: " ") } } }

    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
      lock.withLock { calls.append(args) }
      return answers[args.prefix(2).joined(separator: " ")]
        ?? CommandResult(stdout: "", stderr: "error: unexpected", exitCode: 1, timedOut: false)
    }
  }

  private static func ok(_ json: String) -> CommandResult {
    CommandResult(stdout: json, stderr: "", exitCode: 0, timedOut: false)
  }
  private static func failed(_ said: String) -> CommandResult {
    CommandResult(stdout: "", stderr: "\n  A new version…\n\(said)\n", exitCode: 1, timedOut: false)
  }

  private func driver(_ cli: StubCLI) -> BoxdHostDriver {
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-boxd-\(UUID().uuidString)")
    return BoxdHostDriver(
      configuration: .init(
        cli: URL(fileURLWithPath: "/nonexistent/boxd"), sshConfig: empty, knownHosts: empty),
      directory: empty, runner: cli)
  }

  func testACreateWhoseMachineCannotBeReachedRemovesIt() async throws {
    // The machine is made, but the CLI never wrote its ssh details.
    let cli = StubCLI([
      "machine new": Self.ok(#"{"name":"x"}"#),
      "machine remove": Self.ok(#"{"status":"destroyed"}"#),
    ])
    do {
      _ = try await driver(cli).create()
      XCTFail("a machine with no ssh details became a base")
    } catch HostDriverError.invalidConfiguration(let detail) {
      XCTAssertTrue(detail.contains("no ssh details"), detail)
    }
    XCTAssertEqual(cli.commands, ["machine new", "machine remove"], "the machine was kept")
  }

  func testACreateWhoseMachineIsRefusedSaysTheCLIsReasonAndHasNothingToRemove() async throws {
    let cli = StubCLI([
      "machine new": Self.failed("error: quota exceeded"),
      "machine remove": Self.failed("error: VM 'workroom-x' not found"),
    ])
    do {
      _ = try await driver(cli).create()
      XCTFail("a refused machine became a base")
    } catch HostDriverError.provisioning(let detail) {
      XCTAssertEqual(detail, "boxd machine new: error: quota exceeded")
    }
  }

  func testARemovalThatFailsIsNamedAsLeftBehind() async throws {
    let cli = StubCLI([
      "machine new": Self.failed("error: quota exceeded"),
      "machine remove": Self.failed("error: internal"),
    ])
    do {
      _ = try await driver(cli).create()
      XCTFail("a refused machine became a base")
    } catch HostDriverError.leftBehind(let cause, let leftover) {
      XCTAssertEqual(cause, "Couldn't provision the host: boxd machine new: error: quota exceeded")
      XCTAssertEqual(leftover.count, 1)
      XCTAssertTrue(leftover[0].hasPrefix("machine workroom-"), leftover[0])
    }
  }

  func testAnInstanceCannotBeDerivedFromAndAnUnknownBaseIsUnknown() async throws {
    let instance = StubCLI([
      "machine get": Self.ok(#"{"name":"x","source":"snapshot/x:1"}"#)
    ])
    do {
      _ = try await driver(instance).deriveFromBase(.remote(UUID()))
      XCTFail("an instance was derived from")
    } catch HostDriverError.invalidConfiguration {}
    XCTAssertEqual(instance.commands, ["machine get"], "a derive went ahead from an instance")

    let missing = StubCLI(["machine get": Self.failed("error: VM 'x' not found")])
    let base = HostID.remote(UUID())
    do {
      _ = try await driver(missing).deriveFromBase(base)
      XCTFail("a derive went ahead from no base")
    } catch HostDriverError.unknownHost(let host) {
      XCTAssertEqual(host, base)
    }
  }

  func testDestroyingAMachineAlreadyGoneSucceedsAndAFailedRemovalThrows() async throws {
    let gone = StubCLI(["machine remove": Self.failed("error: VM 'x' not found")])
    try await driver(gone).destroy(.remote(UUID()))

    let failing = StubCLI(["machine remove": Self.failed("error: internal")])
    do {
      try await driver(failing).destroy(.remote(UUID()))
      XCTFail("a failed removal was swallowed")
    } catch HostDriverError.provisioning(let detail) {
      XCTAssertTrue(detail.hasSuffix("boxd machine remove: error: internal"), detail)
    }
  }
}

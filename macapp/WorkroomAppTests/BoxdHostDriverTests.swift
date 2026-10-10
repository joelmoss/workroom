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
    let script = try HostSetup.systemdScript()
    XCTAssertTrue(script.contains("workroom-agent.service"))
  }

  // MARK: Failures, with the CLI stubbed

  /// Answers each CLI call from `answers`, by its first two words, and records every call.
  private final class StubCLI: StatusCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    let answers: [String: CommandResult]
    /// The active org each `auth` answers with, in turn; the account's own once they run out.
    private var orgs: [String?]
    /// Cancels the calling task from inside the CLI call naming this command.
    var cancelling: String?
    /// Where pending machines are written down, read at each call into `pendingAt` (#373).
    var pendingIn: URL?
    private var pending: [String: [PendingMachines.Entry]] = [:]
    func pendingAt(_ command: String) -> [PendingMachines.Entry]? {
      lock.withLock { pending[command] }
    }

    init(_ answers: [String: CommandResult], orgs: [String?] = []) {
      self.answers = answers
      self.orgs = orgs
    }

    /// Every call's full arguments, org checks included.
    var arguments: [[String]] { lock.withLock { calls } }

    /// Every command but the org checks.
    var commands: [String] {
      lock.withLock { calls.map { $0.prefix(2).joined(separator: " ") } }
        .filter { $0 != "auth --json" }
    }

    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
      lock.withLock { calls.append(args) }
      let command = args.prefix(2).joined(separator: " ")
      if let pendingIn {
        let entries = PendingMachines.entries(in: pendingIn)
        lock.withLock { pending[command] = entries }
      }
      if command == cancelling { withUnsafeCurrentTask { $0?.cancel() } }
      // The account's own org is active unless a test says otherwise.
      if command == "auth --json", answers[command] == nil {
        let org = lock.withLock { orgs.isEmpty ? nil : orgs.removeFirst() }
        return BoxdHostDriverTests.ok(
          org.map { #"{"active_org":"\#($0)"}"# } ?? #"{"active_org":null}"#)
      }
      return answers[command]
        ?? CommandResult(stdout: "", stderr: "error: unexpected", exitCode: 1, timedOut: false)
    }
  }

  fileprivate static func ok(_ json: String) -> CommandResult {
    CommandResult(stdout: json, stderr: "", exitCode: 0, timedOut: false)
  }
  private static func failed(_ said: String) -> CommandResult {
    CommandResult(stdout: "", stderr: "\n  A new version…\n\(said)\n", exitCode: 1, timedOut: false)
  }

  private func driver(_ cli: StubCLI) -> BoxdHostDriver {
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-boxd-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: empty) }
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
      XCTFail("a machine with no ssh details became a host")
    } catch HostDriverError.invalidConfiguration(let detail) {
      XCTAssertTrue(detail.contains("no ssh details"), detail)
    }
    XCTAssertEqual(cli.commands, ["machine new", "machine remove"], "the machine was kept")
  }

  /// A create says which step it is on, for its project row (#356): the machine first, then its
  /// setup, which this one never reaches (the CLI wrote no ssh details).
  func testACreateReportsItsSteps() async throws {
    let cli = StubCLI([
      "machine new": Self.ok(#"{"name":"x"}"#),
      "machine remove": Self.ok(#"{"status":"destroyed"}"#),
    ])
    let steps = Steps()
    let report: @Sendable (RemoteProvisioning.Step) -> Void = { steps.add($0) }
    await RemoteProvisioning.$reportStep.withValue(report) {
      _ = try? await driver(cli).create()
    }
    XCTAssertEqual(steps.all, [.machine, .setup])
  }

  private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [RemoteProvisioning.Step] = []
    var all: [RemoteProvisioning.Step] { lock.withLock { seen } }
    func add(_ step: RemoteProvisioning.Step) { lock.withLock { seen.append(step) } }
  }

  func testACreateWhoseMachineIsRefusedSaysTheCLIsReasonAndHasNothingToRemove() async throws {
    let cli = StubCLI([
      "machine new": Self.failed("error: quota exceeded"),
      "machine remove": Self.failed("error: VM 'workroom-x' not found"),
    ])
    do {
      _ = try await driver(cli).create()
      XCTFail("a refused machine became a host")
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
      XCTFail("a refused machine became a host")
    } catch HostDriverError.leftBehind(let cause, let leftover, let host) {
      XCTAssertEqual(cause, "Couldn't provision the host: boxd machine new: error: quota exceeded")
      // Named, so the caller can record the machine for a delete to take down.
      XCTAssertEqual(leftover.count, 1)
      // Named exactly, so a later delete reaches the machine the leftover names.
      guard case .remote(let id) = host else {
        return XCTFail("a machine left behind was not named")
      }
      XCTAssertTrue(leftover[0].contains(id.uuidString.lowercased()), leftover[0])
      XCTAssertTrue(leftover[0].hasPrefix("machine workroom-"), leftover[0])
    }
  }

  /// A create names its machine as pending before `machine new`, so a crash before config records
  /// the host leaves it for the launch sweep (#373). A rollback that removed the machine takes it
  /// off; one that couldn't keeps it.
  func testAMachineStaysPendingUntilItIsRemoved() async throws {
    // Value: protects=a crash mid-create leaves the paid machine named for the sweep;
    // fails_when=the marker is written after the CLI call, never, or dropped on a failed removal;
    // why_new=#373 adds the marker; seam=the stub CLI reads the marker file at each call
    for removed in [true, false] {
      let cli = StubCLI([
        "machine new": Self.failed("error: quota exceeded"),
        "machine remove": removed ? Self.ok(#"{"status":"destroyed"}"#) : Self.failed("error: x"),
      ])
      let driver = driver(cli)
      cli.pendingIn = driver.directory
      _ = try? await driver.create()
      XCTAssertEqual(cli.pendingAt("machine new")?.map(\.driver), [RemoteWorkrooms.boxdDriver])
      XCTAssertNotNil(
        cli.pendingAt("machine new")?.first?.made, "an entry was written down with no age")
      XCTAssertEqual(PendingMachines.entries(in: driver.directory).count, removed ? 0 : 1)
    }
  }

  /// A delete that removed the machine takes it off the pending list, so the launch sweep never
  /// goes after a machine that is gone; one that failed keeps it (#373).
  func testADeleteTakesItsMachineOffThePendingList() async throws {
    // Value: protects=a deleted machine is not swept again, and a failed delete keeps its entry;
    // fails_when=destroy leaves the entry, or drops it when the removal failed;
    // why_new=the pending test covers only a create's rollback; seam=none
    for removed in [true, false] {
      let cli = StubCLI([
        "machine remove": removed ? Self.ok(#"{"status":"destroyed"}"#) : Self.failed("error: x")
      ])
      let driver = driver(cli)
      let id = UUID()
      try PendingMachines.add(
        .init(id: id, driver: RemoteWorkrooms.boxdDriver), in: driver.directory)
      _ = try? await driver.destroy(.remote(id))
      XCTAssertEqual(
        PendingMachines.entries(in: driver.directory).map(\.id), removed ? [] : [id])
    }
  }

  /// In another org this driver's machines read as not found, which `destroy` takes for gone: so
  /// nothing is done there, and a rollback names what it could not remove.
  func testNothingIsDoneWhileAnotherOrgIsActive() async throws {
    let cli = StubCLI([
      "auth --json": Self.ok(#"{"active_org":"acme"}"#),
      "machine remove": Self.failed("error: VM 'x' not found"),
    ])
    do {
      try await driver(cli).destroy(.remote(UUID()))
      XCTFail("a destroy went ahead in another org")
    } catch HostDriverError.invalidConfiguration(let detail) {
      XCTAssertTrue(detail.contains("acme"), detail)
    }
    do {
      _ = try await driver(cli).create()
      XCTFail("a create went ahead in another org")
    } catch HostDriverError.invalidConfiguration {}
    XCTAssertEqual(cli.commands, [], "a command ran in another org")

    // The same org, named: it goes ahead.
    let named = BoxdHostDriver(
      configuration: .init(cli: URL(fileURLWithPath: "/nonexistent/boxd"), org: "acme"),
      directory: FileManager.default.temporaryDirectory, runner: cli)
    try await named.destroy(.remote(UUID()))
    XCTAssertEqual(cli.commands, ["machine remove"])
  }

  // Value: protects=every new boxd host records the account it was made in, so a delete checks it;
  // fails_when=a boxd auth reply with no user_id is accepted and the host records no account;
  // why_new=the account check is tested only with an account recorded; seam=none
  /// A new host records its account (#356): an auth reply that names none is refused, so a later
  /// delete never skips the check that the same account is signed in.
  func testANewHostNeedsTheSignedInAccountsID() throws {
    let decode = { (json: String) in
      try JSONDecoder().decode(BoxdHostDriver.Account.self, from: Data(json.utf8))
    }
    XCTAssertEqual(try decode(#"{"active_org":null,"user_id":"usr_1"}"#).requiredUserID(), "usr_1")
    XCTAssertThrowsError(try decode(#"{"active_org":"acme"}"#).requiredUserID()) { error in
      XCTAssertTrue(error.localizedDescription.contains("boxd auth login"), "\(error)")
    }
  }

  /// Every personal account's org is nil, so after a switch to another account the org check alone
  /// passes and the first account's machines read as not found, which `destroy` would take for gone
  /// (#356). The account is checked too, and only the one that made the machines goes ahead.
  func testNothingIsDoneWhileAnotherAccountIsSignedIn() async throws {
    let cli = StubCLI([
      "auth --json": Self.ok(#"{"active_org":null,"user_id":"usr_other"}"#),
      "machine remove": Self.failed("error: VM 'x' not found"),
    ])
    let mine = BoxdHostDriver(
      configuration: .init(cli: URL(fileURLWithPath: "/nonexistent/boxd"), account: "usr_mine"),
      directory: FileManager.default.temporaryDirectory, runner: cli)
    do {
      try await mine.destroy(.remote(UUID()))
      XCTFail("a destroy went ahead on another account")
    } catch HostDriverError.invalidConfiguration(let detail) {
      XCTAssertTrue(detail.contains("boxd auth login"), detail)
    }
    XCTAssertEqual(cli.commands, [], "a command ran on another account")

    let other = BoxdHostDriver(
      configuration: .init(cli: URL(fileURLWithPath: "/nonexistent/boxd"), account: "usr_other"),
      directory: FileManager.default.temporaryDirectory, runner: cli)
    try await other.destroy(.remote(UUID()))
    XCTAssertEqual(cli.commands, ["machine remove"])
  }

  /// boxd's idle timers, whose encoding isn't documented: the shorter of the two that are set, in
  /// seconds, from a number or a string with a unit; a timer that is off, absent or unreadable
  /// Asleep is boxd's own status: suspended (`standby`) or hibernated, never a guess.
  func testAsleepIsBoxdsStandbyOrHibernated() async throws {
    for (status, presence) in [
      ("standby", BoxdHostDriver.Presence.asleep), ("hibernated", .asleep), ("running", .awake),
      ("stopped", .awake),
    ] {
      let cli = StubCLI(["machine get": Self.ok(#"{"status":"\#(status)"}"#)])
      let answer = await driver(cli).presence(.remote(UUID()))
      XCTAssertEqual(answer, presence, status)
    }
    // A reply without a status can't say the box is awake, so it doesn't.
    let statusless = await driver(StubCLI(["machine get": Self.ok(#"{"name":"x"}"#)]))
      .presence(.remote(UUID()))
    XCTAssertNil(statusless, "a reply without status failed open")
    // boxd answered with an error (signed out, another account): leave it alone.
    let refused = await driver(StubCLI(["machine get": Self.failed("error: not logged in")]))
      .presence(.remote(UUID()))
    XCTAssertEqual(refused, .asleep, "a CLI error woke the box")
    // boxd says the machine is not found: gone, which a read reports rather than "asleep".
    let gone = await driver(StubCLI(["machine get": Self.failed("error: VM 'x' not found")]))
      .presence(.remote(UUID()))
    XCTAssertEqual(gone, .gone)
    // boxd couldn't answer at all (timed out): nil, which `RemoteHosts` takes as asleep.
    let timedOut = await driver(
      StubCLI([
        "machine get": CommandResult(stdout: "", stderr: "", exitCode: 15, timedOut: true)
      ])
    ).presence(.remote(UUID()))
    XCTAssertNil(timedOut, "a CLI that never answered was taken for an answer")
  }

  /// Signed out of boxd, a create stops at its first CLI call and tells the user how to sign in.
  func testSignedOutSaysToSignInAndRunsNothingElse() async throws {
    let cli = StubCLI(["auth --json": Self.failed("error: not logged in")])
    do {
      _ = try await driver(cli).create()
      XCTFail("a create went ahead signed out")
    } catch HostDriverError.provisioning(let detail) {
      XCTAssertTrue(detail.contains("boxd auth login"), detail)
    }
    XCTAssertEqual(cli.commands, [], "a command ran signed out")
  }

  /// The org can change between the check and the removal: "not found" then means nothing.
  func testANotFoundAfterTheOrgChangedIsNotTakenForGone() async throws {
    let cli = StubCLI(
      ["machine remove": Self.failed("error: VM 'x' not found")], orgs: [nil, "acme"])
    do {
      try await driver(cli).destroy(.remote(UUID()))
      XCTFail("a machine in the old org was taken for gone")
    } catch HostDriverError.provisioning(let detail) {
      XCTAssertTrue(detail.contains("acme"), detail)
    }
  }

  /// A cancelled call is a cancellation, not a provisioning failure.
  func testACancelledCLICallThrowsCancellation() async throws {
    let cli = StubCLI(["machine remove": Self.ok("{}")])
    cli.cancelling = "machine remove"
    let destroy = Task { [driver = driver(cli)] in try await driver.destroy(.remote(UUID())) }
    do {
      try await destroy.value
      XCTFail("a cancelled destroy reported success")
    } catch is CancellationError {}
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

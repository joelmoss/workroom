import DaemonConnection
import Foundation
import Synchronization
import WorkroomDomain
import WorkroomSystem
import XCTest

@testable import HostDrivers

/// The Railway driver (#629) through its capability protocols, with Railway stubbed at HTTP
/// (`StubRailway`) and every ssh, ssh-keygen and ssh-keyscan it runs through the command runner
/// (`StubRelay`): nothing reaches Railway or its relay. A host's own exchanges over `exec` and
/// `openStream` go over real ssh, so the live suite covers them; no test here calls them.
final class RailwayHostDriverTests: XCTestCase {
  /// The relay's host key, as Workroom ships it (the 2026-11-13 spike's), and another key.
  static let relayKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ8X3z81/tuP7CvmK3ZqWgwEvHUR6b04oi2lQJGld2C1"
  static let otherKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOtherKeyOtherKeyOtherKeyOtherKey0"
  /// Never resolves, so a test that slipped past the runner reaches nothing.
  static let relayHost = "relay.railway.invalid"

  /// A token provider that hands out one token, or is signed out.
  private final class Tokens: RailwayAccessTokenProviding, Sendable {
    private let signedIn: Mutex<Bool>
    init(signedIn: Bool = true) { self.signedIn = Mutex(signedIn) }
    func signOut() { signedIn.withLock { $0 = false } }
    func accessToken() async throws -> String {
      guard signedIn.withLock({ $0 }) else { throw RailwaySessionError.signedOut }
      return "at-1"
    }
    func accessTokenRejected(_ token: String) async {}
  }

  /// ssh, ssh-keygen and ssh-keyscan as the driver runs them: keygen writes a key pair where `-f`
  /// says, a keyscan the driver should never run prints `otherKey`, and ssh answers `ssh` (exit 0
  /// by default).
  /// Records each call with its stdin.
  final class StubRelay: StatusCommandRunning, @unchecked Sendable {
    struct Call {
      let executable: String
      let args: [String]
      let stdin: Data?
    }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var ssh: [CommandResult] = []

    var calls: [Call] { lock.withLock { _calls } }
    func calls(to tool: String) -> [Call] { calls.filter { $0.executable.hasSuffix("/\(tool)") } }

    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
      await run(executable, args, in: directory, timeout: timeout, stdin: nil)
    }

    func run(
      _ executable: String, _ args: [String], in directory: String, timeout: TimeInterval,
      stdin: Data?
    ) async -> CommandResult {
      lock.withLock { _calls.append(Call(executable: executable, args: args, stdin: stdin)) }
      switch (executable as NSString).lastPathComponent {
      case "ssh-keygen":
        let path = args[args.firstIndex(of: "-f")! + 1]
        try? "PRIVATE".write(toFile: path, atomically: true, encoding: .utf8)
        try? "ssh-ed25519 AAAAMacKey workroom\n".write(
          toFile: path + ".pub", atomically: true, encoding: .utf8)
        return RailwayHostDriverTests.ok("")
      case "ssh-keyscan":
        // Railway's relay key ships in the app: a scan would trust whatever answers.
        return RailwayHostDriverTests.ok("\(args.last!) \(RailwayHostDriverTests.otherKey)\n")
      case "ssh":
        return lock.withLock { _ssh() }
      default:
        return CommandResult(stdout: "", stderr: "unexpected", exitCode: 1, timedOut: false)
      }
    }

    private func _ssh() -> CommandResult {
      ssh.isEmpty ? RailwayHostDriverTests.ok("") : ssh.removeFirst()
    }
  }

  static func ok(_ stdout: String) -> CommandResult {
    CommandResult(stdout: stdout, stderr: "", exitCode: 0, timedOut: false)
  }

  /// A Railway that makes sandbox `sbx-1`, RUNNING at once, and knows no ssh key.
  private func railway(status: String? = "RUNNING") -> StubRailway {
    let railway = StubRailway()
    railway.answer("sshPublicKeys", data: ["sshPublicKeys": StubRailway.lastPage([])])
    railway.answer("sshPublicKeyCreate", data: ["sshPublicKeyCreate": ["id": "key-1"]])
    railway.answer(
      "sandboxCreate", data: ["sandboxCreate": ["id": "sbx-1", "status": "CREATING"]])
    railway.answer(
      "sandbox",
      data: ["sandbox": status.map { ["id": "sbx-1", "status": $0] as Any } ?? NSNull()])
    railway.answer(
      "sandboxDestroy", data: ["sandboxDestroy": ["id": "sbx-1", "status": "DESTROYING"]])
    railway.answer(
      "me", data: ["me": ["workspaces": [["id": "ws-1", "name": "Mine", "plan": "PRO"]]]])
    return railway
  }

  private var root: URL!

  override func setUp() {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-railway-\(UUID().uuidString)")
    let root = root!
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
  }

  private var keys: URL { root.appendingPathComponent("railway") }

  private func driver(
    _ railway: StubRailway, _ relay: StubRelay, tokens: Tokens = Tokens(),
    workspaceID: String? = "ws-1"
  ) -> RailwayHostDriver {
    RailwayHostDriver(
      configuration: .init(
        environmentID: "env-1", projectID: "prj-1", workspaceID: workspaceID, keys: keys,
        relayHost: Self.relayHost, hostSetup: .checkout, pollInterval: .milliseconds(1)),
      api: RailwayAPI(transport: railway, tokens: tokens),
      directory: root.appendingPathComponent("hosts"), runner: relay)
  }

  private func variables(_ railway: StubRailway, _ field: String) -> [String: Any]? {
    railway.graphQLRequests.map(StubRailway.graphQLBody)
      .last { ($0["query"] as? String)?.contains("\(field)(") == true }?["variables"]
      as? [String: Any]
  }

  private func record(_ driver: RailwayHostDriver, _ host: HostID) -> RailwayHostRecord? {
    var descriptor = HostDescriptor(driver: "railway")
    driver.record(host, in: &descriptor)
    return descriptor.railway
  }

  // MARK: Create

  /// Value: protects=a Railway host lasts until its workroom is deleted (ADR 0071); fails_when=the
  /// sandbox is made with Railway's idle timeout, in another environment, or not through the API;
  /// seam=ProvisioningHostDriver.create + HostRecording over StubRailway
  func testACreateMakesASandboxThatNeverIdlesOutInThisMacsEnvironment() async throws {
    let railway = railway()
    let relay = StubRelay()
    let driver = driver(railway, relay)

    let host = try await driver.create()

    let input = try XCTUnwrap(variables(railway, "sandboxCreate")?["input"] as? [String: Any])
    XCTAssertEqual(input["environmentId"] as? String, "env-1")
    XCTAssertEqual(input["idleTimeoutMinutes"] as? Int, 0)
    XCTAssertEqual(
      record(driver, host),
      RailwayHostRecord(
        projectID: "prj-1", environmentID: "env-1", sandboxID: "sbx-1", hostKey: Self.relayKey,
        workspaceID: "ws-1"))
    XCTAssertFalse(
      relay.calls.contains { $0.executable.hasSuffix("railway") }, "never the railway CLI")
  }

  /// Value: protects=a host in an environment the placement has since left (whose driver knows no
  /// workspace) can still be found gone and removed: its record names its workspace, and a record
  /// an older build wrote without one has it resolved from its project once, and kept on the
  /// record the next write takes (review 4, X3); fails_when=such a host's null read never confirms,
  /// so it can never be removed, or the workspace is asked of Railway again on every read;
  /// seam=HostPresenceReporting, destroy and HostRecording over StubRailway, with the driver the
  /// app makes for another environment
  func testAHostInAnotherEnvironmentIsConfirmedGoneAgainstItsOwnWorkspace() async throws {
    let railway = railway()
    railway.answer("sandbox", data: ["sandbox": NSNull()])
    railway.answer("sandboxDestroy") { _ in
      RailwayHTTPResponse(
        status: 200, body: Data(#"{"errors":[{"message":"Sandbox not found"}]}"#.utf8))
    }
    railway.answer(
      "me",
      data: [
        "me": [
          "workspaces": [
            ["id": "ws-1", "name": "Mine", "plan": "PRO"],
            ["id": "ws-old", "name": "Before", "plan": "PRO"],
          ]
        ]
      ])
    railway.answer("projects") { request in
      let variables = StubRailway.graphQLBody(request)["variables"] as? [String: Any] ?? [:]
      let projects: [[String: Any]] =
        variables["workspaceId"] as? String == "ws-old"
        ? [["id": "prj-old", "name": "Workroom"]] : []
      return RailwayHTTPResponse(
        status: 200,
        body: try JSONSerialization.data(withJSONObject: [
          "data": ["projects": ["edges": projects.map { ["node": $0] }]]
        ]))
    }
    for legacy in [false, true] {
      // The app's driver for an environment other than the placement's knows no workspace.
      let driver = RailwayHostDriver(
        configuration: .init(
          environmentID: "env-old", projectID: nil, workspaceID: nil, keys: keys,
          relayHost: Self.relayHost, hostSetup: .checkout, pollInterval: .milliseconds(1)),
        api: RailwayAPI(transport: railway, tokens: Tokens()),
        directory: root.appendingPathComponent("hosts"), runner: StubRelay())
      let id = UUID()
      try driver.adopt(
        HostDescriptor(
          driver: "railway", id: id,
          railway: RailwayHostRecord(
            projectID: "prj-old", environmentID: "env-old", sandboxID: "sbx-old", hostKey: "",
            workspaceID: legacy ? nil : "ws-old")))
      let presence = await driver.presence(.remote(id))
      XCTAssertEqual(presence, .gone, "legacy: \(legacy)")
      XCTAssertEqual(record(driver, .remote(id))?.workspaceID, "ws-old", "legacy: \(legacy)")
      try await driver.destroy(.remote(id))
    }
    let lookups = railway.graphQLRequests.map(StubRailway.graphQLBody).filter {
      ($0["query"] as? String)?.contains("projects(") == true
    }
    XCTAssertLessThanOrEqual(lookups.count, 2, "the legacy record's workspace was asked again")
  }

  /// Value: protects=the Mac reaches its host with a key of its own, registered once on the
  /// account and shared by Release and Nightly; fails_when=a key is made or registered on every
  /// create, or one Railway already has is registered again; seam=create over StubRailway
  func testTheMacsKeyIsMadeOnceAndRegisteredOnlyWhenRailwayLacksIt() async throws {
    let railway = railway()
    let relay = StubRelay()
    _ = try await driver(railway, relay).create()

    XCTAssertEqual(relay.calls(to: "ssh-keygen").count, 1)
    let key = try XCTUnwrap(variables(railway, "sshPublicKeyCreate")?["input"] as? [String: Any])
    XCTAssertEqual(key["publicKey"] as? String, "ssh-ed25519 AAAAMacKey workroom")

    // Railway now knows it, as the other build's next create finds it.
    railway.answer(
      "sshPublicKeys",
      data: [
        "sshPublicKeys": StubRailway.lastPage([
          ["id": "key-1", "publicKey": "ssh-ed25519 AAAAMacKey other-comment"]
        ])
      ])
    let before = railway.graphQLRequests.count
    _ = try await driver(railway, relay).create()
    XCTAssertEqual(relay.calls(to: "ssh-keygen").count, 1, "the key was made again")
    let sent = railway.graphQLRequests.dropFirst(before).map(StubRailway.graphQLBody)
    XCTAssertFalse(
      sent.contains { ($0["query"] as? String)?.contains("sshPublicKeyCreate") == true },
      "a key Railway has was registered again")
  }

  /// Value: protects=the host is reached through Railway's relay with only the relay key Workroom
  /// ships trusted, from the very first login (ADR 0071's amendment, review 3 D6); fails_when=the
  /// destination, user, key or known_hosts drift, the relay's key is learned by a scan (trusting
  /// whatever answers the first time), or a pin or a record from the scanning builds beats the
  /// shipped key; seam=create's ssh through the runner, the written ssh_config and known_hosts
  func testTheRelayKeyIsTheOneWorkroomShips() async throws {
    XCTAssertEqual(RailwayHostDriver.relayHostKey, Self.relayKey, "the spike's key")
    // A scanning build's pin of another key, left in the folder.
    try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
    try (Self.otherKey + "\n").write(
      to: keys.appendingPathComponent("relay_host_key"), atomically: true, encoding: .utf8)
    let railway = railway()
    let relay = StubRelay()
    let driver = driver(railway, relay)
    let host = try await driver.create()
    XCTAssertEqual(relay.calls(to: "ssh-keyscan").count, 0, "the relay's key was scanned")
    XCTAssertEqual(record(driver, host)?.hostKey, Self.relayKey)

    let setup = try XCTUnwrap(relay.calls(to: "ssh").first)
    let config = try String(
      contentsOfFile: setup.args[setup.args.firstIndex(of: "-F")! + 1], encoding: .utf8)
    XCTAssertTrue(config.contains(#"HostName "\#(Self.relayHost)""#), config)
    XCTAssertTrue(config.contains(#"User "sbx:env-1:sbx-1""#), config)
    XCTAssertTrue(config.contains("StrictHostKeyChecking yes"), config)
    XCTAssertTrue(config.contains(keys.appendingPathComponent("id_ed25519").path), config)
    guard case .remote(let id) = host else { return XCTFail("\(host)") }
    let known = try String(
      contentsOf: root.appendingPathComponent("hosts/\(id.uuidString)/known_hosts"),
      encoding: .utf8)
    XCTAssertEqual(known, "\(Self.relayHost) \(Self.relayKey)\n")

    // A host a scanning build recorded with another key is reached with the shipped one.
    let adopted = UUID()
    let later = self.driver(railway, relay)
    try later.adopt(
      HostDescriptor(
        driver: "railway", id: adopted,
        railway: RailwayHostRecord(
          projectID: "prj-1", environmentID: "env-1", sandboxID: "sbx-1",
          hostKey: Self.otherKey)))
    _ = try later.attachCommand(
      to: .remote(adopted), session: UUID(), workingDirectory: "/root", restored: false)
    let rewritten = try String(
      contentsOf: root.appendingPathComponent("hosts/\(adopted.uuidString)/known_hosts"),
      encoding: .utf8)
    XCTAssertEqual(rewritten, "\(Self.relayHost) \(Self.relayKey)\n", "the record's key won")
  }

  /// Value: protects=a man in the middle never reaches a workroom (ADR 0071); fails_when=a changed
  /// relay key is retried, accepted, or fails without saying why, or leaves the sandbox billing;
  /// seam=create, and the pane's refusal check
  func testAChangedRelayKeyIsARefusalWithItsReason() async throws {
    let railway = railway()
    let relay = StubRelay()
    relay.ssh = [
      CommandResult(
        stdout: "",
        stderr: "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\n"
          + "Host key verification failed.\n", exitCode: 255, timedOut: false)
    ]
    do {
      _ = try await driver(railway, relay).create()
      XCTFail("a changed relay key was accepted")
    } catch HostDriverError.provisioning(let detail) {
      XCTAssertTrue(detail.contains("host key"), detail)
      XCTAssertTrue(detail.contains("changed"), detail)
      XCTAssertTrue(detail.contains("update Workroom"), detail)
    }
    XCTAssertEqual(relay.calls(to: "ssh").count, 1, "a refusal was retried")
    XCTAssertEqual(variables(railway, "sandboxDestroy")?["id"] as? String, "sbx-1")

    // A pane whose ssh met another key stops retrying.
    let driver = driver(self.railway(), StubRelay())
    let host = try await driver.create()
    guard case .remote(let id) = host else { return XCTFail("\(host)") }
    let session = UUID()
    _ = try driver.attachCommand(
      to: host, session: session, workingDirectory: "/root", restored: false)
    XCTAssertFalse(driver.hostRefusedLastAttach(of: session, on: host))
    try "Host key verification failed.\n".write(
      to: root.appendingPathComponent("hosts/\(id.uuidString)/attach-\(session.uuidString).log"),
      atomically: true, encoding: .utf8)
    XCTAssertTrue(driver.hostRefusedLastAttach(of: session, on: host))
  }

  /// Value: protects=no sandbox is left billing after a create that failed (user story 28);
  /// fails_when=a sandbox that never ran, or a failed setup, is kept; or a destroy that fails is
  /// not named as left behind; seam=create over StubRailway
  func testACreateThatFailsAfterTheSandboxExistsDestroysIt() async throws {
    let failed = railway(status: "FAILED")
    do {
      _ = try await driver(failed, StubRelay()).create()
      XCTFail("a failed sandbox became a host")
    } catch HostDriverError.provisioning {}
    XCTAssertEqual(variables(failed, "sandboxDestroy")?["id"] as? String, "sbx-1")

    let stuck = railway()
    stuck.answer("sandboxDestroy") { _ in
      RailwayHTTPResponse(
        status: 200, body: Data(#"{"errors":[{"message":"Railway is down"}]}"#.utf8))
    }
    let relay = StubRelay()
    relay.ssh = [CommandResult(stdout: "", stderr: "boom", exitCode: 1, timedOut: false)]
    do {
      _ = try await driver(stuck, relay).create()
      XCTFail("a failed setup became a host")
    } catch HostDriverError.leftBehind(_, let leftover, let host) {
      XCTAssertTrue(leftover.joined().contains("sbx-1"), "\(leftover)")
      XCTAssertNotNil(host)
    }
  }

  /// Value: protects=the daemon outlives the login that starts it, and a host with an empty
  /// machine id gets an identity of its own; fails_when=setup runs without its script, with sudo
  /// (the host is root, with no sudo or systemd), or the driver relies on a supervisor;
  /// seam=create's setup through the runner
  func testSetupGivesTheHostAnIdentityFileAndTheDaemonIsStartedFromALogin() async throws {
    let relay = StubRelay()
    let driver = driver(railway(), relay)
    let host = try await driver.create()
    guard case .remote(let id) = host else { return XCTFail("\(host)") }

    XCTAssertTrue(driver.startsDaemon)
    let setup = try XCTUnwrap(relay.calls(to: "ssh").first)
    let command = try XCTUnwrap(setup.args.last)
    XCTAssertTrue(command.hasPrefix("sh -s -- "), command)
    XCTAssertTrue(command.contains(id.uuidString.lowercased()), command)
    XCTAssertFalse(command.contains("sudo"), command)
    let script = String(decoding: try XCTUnwrap(setup.stdin), as: UTF8.self)
    XCTAssertTrue(script.contains("/etc/workroom-identity"), script)
    XCTAssertTrue(script.contains("/etc/machine-id"), script)
    XCTAssertEqual(driver.daemonSocket, "/root/.local/state/workroom/daemon/workroomd.sock")
  }

  // MARK: Presence

  /// Value: protects=a gone sandbox shows gone without a login, and a running one is never taken
  /// for asleep (ADR 0071); fails_when=status is read by ssh, or a status maps wrongly;
  /// seam=HostPresenceReporting over StubRailway
  func testPresenceComesFromTheSandboxsStatus() async throws {
    let railway = railway()
    let relay = StubRelay()
    let driver = driver(railway, relay)
    let host = try await driver.create()
    let logins = relay.calls(to: "ssh").count

    for (status, presence) in [
      ("RUNNING", HostPresence.awake), ("CREATING", .awake), ("DESTROYED", .gone),
      ("DESTROYING", .gone), ("FAILED", .gone),
    ] {
      railway.answer("sandbox", data: ["sandbox": ["id": "sbx-1", "status": status]])
      let read = await driver.presence(host)
      XCTAssertEqual(read, presence, status)
    }
    railway.answer("sandbox", data: ["sandbox": NSNull()])
    let missing = await driver.presence(host)
    XCTAssertEqual(missing, .gone, "a sandbox Railway doesn't know")
    railway.answer("sandbox") { _ in
      RailwayHTTPResponse(status: 502, body: Data("bad gateway".utf8))
    }
    let unknown = await driver.presence(host)
    XCTAssertNil(unknown, "Railway couldn't say")
    XCTAssertFalse(driver.hostsSleep, "a Railway host never sleeps")
    XCTAssertEqual(relay.calls(to: "ssh").count, logins, "presence logged in")
  }

  /// Value: protects=a sandbox Railway answers with no such sandbox for is called gone, and its
  /// delete completed, only when the sign-in can see this Mac's workspace: another account (or a
  /// sign-in that lost the workspace) reads every sandbox as missing, and its workroom would be
  /// removed while the sandbox bills on (review 3, C4); fails_when=a null read under an account
  /// that can't see the workspace, with no workspace recorded, or with the workspaces unreadable,
  /// reads as gone or completes a delete; seam=HostPresenceReporting and destroy over StubRailway
  func testANullSandboxIsGoneOnlyWhenTheSignInSeesThisMacsWorkspace() async throws {
    let railway = railway()
    let driver = driver(railway, StubRelay())
    let host = try await driver.create()
    guard case .remote(let id) = host else { return XCTFail("\(host)") }
    let descriptor = HostDescriptor(
      driver: "railway", id: id,
      railway: RailwayHostRecord(
        projectID: "prj-1", environmentID: "env-1", sandboxID: "sbx-1", hostKey: Self.relayKey))
    railway.answer("sandbox", data: ["sandbox": NSNull()])
    railway.answer("sandboxDestroy") { _ in
      RailwayHTTPResponse(
        status: 200, body: Data(#"{"errors":[{"message":"Sandbox not found"}]}"#.utf8))
    }

    // Another account: it sees a workspace, but not this Mac's.
    railway.answer(
      "me", data: ["me": ["workspaces": [["id": "ws-other", "name": "Theirs", "plan": "PRO"]]]])
    var presence = await driver.presence(host)
    XCTAssertEqual(presence, .signedOut, "another account's null read")
    do {
      try await driver.destroy(host)
      XCTFail("another account's null read completed the delete")
    } catch {}

    // Railway couldn't list the workspaces: unknown, never gone.
    railway.answer("me") { _ in RailwayHTTPResponse(status: 502, body: Data("bad".utf8)) }
    presence = await driver.presence(host)
    XCTAssertNil(presence, "an unconfirmed null read")
    do {
      try await driver.destroy(host)
      XCTFail("an unconfirmed null read completed the delete")
    } catch {}

    // No workspace recorded for this Mac: nothing to confirm against.
    let unplaced = self.driver(railway, StubRelay(), workspaceID: nil)
    try unplaced.adopt(descriptor)
    railway.answer(
      "me", data: ["me": ["workspaces": [["id": "ws-1", "name": "Mine", "plan": "PRO"]]]])
    presence = await unplaced.presence(host)
    XCTAssertNil(presence, "a null read with no workspace to confirm")

    // This Mac's workspace is seen: the null read is gone, and the delete completes.
    try driver.adopt(descriptor)
    presence = await driver.presence(host)
    XCTAssertEqual(presence, .gone)
    try await driver.destroy(host)
  }

  /// Value: protects=a revoked or expired sign-in reads as signed out, so the workroom offers
  /// Sign in (#629); fails_when=it reads as gone (the only action would be removing it) or asleep;
  /// seam=HostPresenceReporting
  func testASignedOutRailwayReadsAsSignedOut() async throws {
    let tokens = Tokens()
    let driver = driver(railway(), StubRelay(), tokens: tokens)
    let host = try await driver.create()
    tokens.signOut()
    let presence = await driver.presence(host)
    XCTAssertEqual(presence, .signedOut)
  }

  // MARK: Delete and relaunch

  /// `driver`'s host `host` adopted again from its record, as a delete that failed leaves it.
  private func readopt(_ driver: RailwayHostDriver, _ host: HostID) throws {
    guard case .remote(let id) = host else { return XCTFail("\(host)") }
    try driver.adopt(
      HostDescriptor(
        driver: "railway", id: id,
        railway: RailwayHostRecord(
          projectID: "prj-1", environmentID: "env-1", sandboxID: "sbx-1", hostKey: "",
          workspaceID: "ws-1")))
  }

  /// Value: protects=a destroy Railway answers with a null sandbox and no errors is confirmed by
  /// the sandbox's status before the host is let go, so a record is never forgotten while its
  /// sandbox bills on (review 4, X5); fails_when=a null answer counts as destroyed with the
  /// sandbox still running; seam=ProvisioningHostDriver.destroy over StubRailway
  func testANullDestroyAnswerIsConfirmedByTheSandboxsStatus() async throws {
    let railway = railway()
    let driver = driver(railway, StubRelay())
    let host = try await driver.create()
    railway.answer("sandboxDestroy", data: ["sandboxDestroy": NSNull()])
    railway.answer("sandbox", data: ["sandbox": ["id": "sbx-1", "status": "RUNNING"]])
    do {
      try await driver.destroy(host)
      XCTFail("a null destroy answer let a running sandbox go")
    } catch {}

    railway.answer("sandbox", data: ["sandbox": ["id": "sbx-1", "status": "DESTROYED"]])
    try readopt(driver, host)
    try await driver.destroy(host)
  }

  /// Value: protects=a destroy Railway refused is taken for done only when the sandbox reads as
  /// destroyed, or as missing with the workspace seen: a failed or still-destroying sandbox may
  /// bill on, so its record stays to be deleted again (review 4, X1); fails_when=FAILED or
  /// DESTROYING after a refused destroy completes the delete; seam=ProvisioningHostDriver.destroy
  /// over StubRailway
  func testARefusedDestroyIsConfirmedOnlyByADestroyedOrMissingSandbox() async throws {
    let railway = railway()
    let driver = driver(railway, StubRelay())
    let host = try await driver.create()
    railway.answer("sandboxDestroy") { _ in
      RailwayHTTPResponse(
        status: 200, body: Data(#"{"errors":[{"message":"Sandbox is busy"}]}"#.utf8))
    }
    for status in ["FAILED", "DESTROYING"] {
      railway.answer("sandbox", data: ["sandbox": ["id": "sbx-1", "status": status]])
      do {
        try await driver.destroy(host)
        XCTFail("a refused destroy of a \(status) sandbox completed the delete")
      } catch {}
      try readopt(driver, host)
    }
    railway.answer("sandbox", data: ["sandbox": ["id": "sbx-1", "status": "DESTROYED"]])
    try await driver.destroy(host)
  }

  /// Value: protects=deleting the workroom stops the bill (user story 27); fails_when=the sandbox
  /// is kept, or one already gone fails the delete; seam=ProvisioningHostDriver.destroy
  func testDeletingTheWorkroomDestroysTheSandbox() async throws {
    let railway = railway()
    let driver = driver(railway, StubRelay())
    let host = try await driver.create()
    var descriptor = HostDescriptor(driver: "railway")
    driver.record(host, in: &descriptor)
    guard case .remote(let id) = host else { return XCTFail("\(host)") }
    descriptor.id = id

    try await driver.destroy(host)
    let destroyed = try XCTUnwrap(variables(railway, "sandboxDestroy"))
    XCTAssertEqual(destroyed["id"] as? String, "sbx-1")
    XCTAssertEqual(destroyed["environmentId"] as? String, "env-1")

    // Destroyed from the dashboard already: Railway refuses, and says it is gone.
    try driver.adopt(descriptor)
    railway.answer("sandboxDestroy") { _ in
      RailwayHTTPResponse(
        status: 200, body: Data(#"{"errors":[{"message":"Sandbox not found"}]}"#.utf8))
    }
    railway.answer("sandbox", data: ["sandbox": ["id": "sbx-1", "status": "DESTROYED"]])
    try await driver.destroy(host)

    // Still running, and Railway won't destroy it: the delete fails, so it can be tried again.
    railway.answer("sandbox", data: ["sandbox": ["id": "sbx-1", "status": "RUNNING"]])
    try driver.adopt(descriptor)
    do {
      try await driver.destroy(host)
      XCTFail("a sandbox still running was taken for destroyed")
    } catch {}
  }

  /// Value: protects=a delete whose sandbox Railway no longer has at all completes (review #5);
  /// fails_when=Railway's successful "no such sandbox" (a null sandbox) reads as a failed read, so
  /// the delete fails for good; seam=ProvisioningHostDriver.destroy over StubRailway
  func testDeletingASandboxRailwayNoLongerHasCompletes() async throws {
    let railway = railway()
    let driver = driver(railway, StubRelay())
    let host = try await driver.create()
    railway.answer("sandboxDestroy") { _ in
      RailwayHTTPResponse(
        status: 200, body: Data(#"{"errors":[{"message":"Sandbox not found"}]}"#.utf8))
    }
    railway.answer("sandbox", data: ["sandbox": NSNull()])
    try await driver.destroy(host)

    // Railway couldn't say at all: the delete fails, to be tried again.
    try driver.adopt(
      HostDescriptor(
        driver: "railway", id: { if case .remote(let id) = host { id } else { UUID() } }(),
        railway: RailwayHostRecord(
          projectID: "prj-1", environmentID: "env-1", sandboxID: "sbx-1", hostKey: "k")))
    railway.answer("sandbox") { _ in RailwayHTTPResponse(status: 502, body: Data("bad".utf8)) }
    do {
      try await driver.destroy(host)
      XCTFail("a sandbox Railway couldn't read was taken for destroyed")
    } catch {}
  }

  /// Value: protects=a new sandbox Railway briefly doesn't list yet still becomes a host, and one
  /// that stays unknown fails the create (review #5); fails_when=the first null status fails the
  /// create, or a sandbox that never appears is waited on forever; seam=create over StubRailway
  func testACreateRidesOutABriefNullStatus() async throws {
    let railway = railway()
    let reads = Mutex(0)
    railway.answer("sandbox") { _ in
      let read = reads.withLock {
        $0 += 1
        return $0
      }
      let sandbox: Any = read <= 2 ? NSNull() : ["id": "sbx-1", "status": "RUNNING"]
      return RailwayHTTPResponse(
        status: 200,
        body: try JSONSerialization.data(withJSONObject: ["data": ["sandbox": sandbox]]))
    }
    _ = try await driver(railway, StubRelay()).create()

    let never = self.railway(status: nil)
    do {
      _ = try await driver(never, StubRelay()).create()
      XCTFail("a sandbox Railway never listed became a host")
    } catch HostDriverError.provisioning(let said) {
      XCTAssertTrue(said.contains("gone"), said)
    }
  }

  /// Value: protects=a workroom reached again after a relaunch, from config alone; fails_when=a
  /// fresh driver can't attach to, read or delete a recorded host; seam=HostRecording.adopt, then
  /// HostTerminalDriver and HostPresenceReporting
  func testAFreshDriverReachesARecordedHost() async throws {
    let railway = railway()
    let made = driver(railway, StubRelay())
    let host = try await made.create()
    var descriptor = HostDescriptor(driver: "railway")
    made.record(host, in: &descriptor)
    guard case .remote(let id) = host else { return XCTFail("\(host)") }
    descriptor.id = id

    let fresh = driver(railway, StubRelay())
    XCTAssertThrowsError(
      try fresh.attachCommand(to: host, session: UUID(), workingDirectory: "/", restored: false))
    try fresh.adopt(descriptor)
    let presence = await fresh.presence(host)
    XCTAssertEqual(presence, .awake)
    _ = try fresh.attachCommand(to: host, session: UUID(), workingDirectory: "/", restored: false)
    try await fresh.destroy(host)
    XCTAssertEqual(variables(railway, "sandboxDestroy")?["id"] as? String, "sbx-1")
  }

  /// Value: protects=a pane shows only its session and every key reaches the program: no host
  /// terminal (`-T`), so no relay banner and no Ctrl+\ then d detach, and never the relay's
  /// durable-session resume (ADR 0074); fails_when=the attach asks for a terminal or names a
  /// durable session; seam=HostTerminalDriver.attachCommand
  func testAPaneAttachesWithoutAHostTerminalOrADurableSession() async throws {
    let driver = driver(railway(), StubRelay())
    let host = try await driver.create()
    let attach = try driver.attachCommand(
      to: host, session: UUID(), workingDirectory: "/root/app", restored: false)
    XCTAssertTrue(attach.contains("'-T'"), attach)
    XCTAssertTrue(attach.contains("'--dial'"), attach)
    XCTAssertFalse(attach.contains("RAILWAY_DURABLE"), attach)
    XCTAssertFalse(attach.contains("'-t'"), attach)
    XCTAssertTrue(attach.contains("relay --socket"), attach)
  }
}

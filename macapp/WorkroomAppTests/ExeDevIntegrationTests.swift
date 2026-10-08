import XCTest

@testable import Workroom

/// `ExeDevHostDriver` on real exe.dev VMs (#259): the parity cases boxd runs
/// (`ProviderParityTestCase`), and exe.dev's own failure at each lobby step. These make and remove
/// real VMs in the account the user's ssh key signs in to, so they run only when asked for, with
/// the sandbox off:
///
///   TEST_RUNNER_WR_EXEDEV_TESTS=1 \
///     make app-test APP_TEST_FLAGS=-only-testing:WorkroomAppTests/ExeDevIntegrationTests
///
/// Every VM a test makes carries its own prefix, and `tearDown` removes whatever is left by it.
final class ExeDevIntegrationTests: ProviderParityTestCase {
  private var directory: URL!
  private var prefix: String!

  override func setUp() async throws {
    try await super.setUp()
    guard ProcessInfo.processInfo.environment["WR_EXEDEV_TESTS"] == "1" else {
      throw XCTSkip("set TEST_RUNNER_WR_EXEDEV_TESTS=1 to run these on exe.dev")
    }
    guard PersistentSessionPaths.linuxAgentURL(architecture: "x86_64") != nil else {
      throw XCTSkip("this build bundles no Linux agent")
    }
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-exedev-\(UUID().uuidString.prefix(8))")
    // Short: exe.dev took a 45-character name in the spike, and a host's is `<prefix>-<uuid>`.
    prefix = "wrt\(UUID().uuidString.prefix(5).lowercased())"
  }

  override func tearDown() async throws {
    for connection in connections { await connection.close() }
    connections.removeAll()
    if prefix != nil {
      for name in (try? leftovers()) ?? [] { _ = try? lobby(["rm", name]) }
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
    try await super.tearDown()
  }

  // MARK: Helpers

  private func driver(runner: any StatusCommandRunning = StatusCommandRunner())
    -> ExeDevHostDriver
  {
    ExeDevHostDriver(configuration: .init(prefix: prefix), directory: directory, runner: runner)
  }

  private func provider(_ driver: ExeDevHostDriver? = nil, key: RemoteHosts.DriverKey? = nil)
    -> LiveProvider
  {
    LiveProvider(
      driver: driver ?? self.driver(), key: key ?? .exeDev(account: nil),
      user: ExeDevHostDriver.user,
      // exe.dev's own sshd, which its gateway reaches the VM through (spike).
      sshHostKey: "/exe.dev/etc/ssh/ssh_host_ed25519_key.pub", name: name,
      onBox: { host, line in try self.onBox(host, line) },
      restart: { host in try self.lobby(["restart", self.name(host)]) },
      leftovers: { try self.leftovers() })
  }

  /// exe.dev's lobby through the user's own ssh, not the driver, so a check is never the thing
  /// under test. Its stdout; a failure throws with what it said.
  @discardableResult
  private func lobby(_ arguments: [String]) throws -> String {
    let (status, output) = try ssh(["exe.dev"] + arguments + ["--json"])
    guard status == 0 else { throw HostDriverError.provisioning(output) }
    return output
  }

  private func ssh(_ arguments: [String]) throws -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = ["-o", "BatchMode=yes"] + arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  /// This test's VMs, by name.
  private func leftovers() throws -> [String] {
    let listed = try JSONSerialization.jsonObject(with: Data(try lobby(["ls"]).utf8))
    let rows = (listed as? [String: Any])?["vms"] as? [[String: Any]] ?? []
    return rows.compactMap { $0["vm_name"] as? String }.filter { $0.hasPrefix(prefix + "-") }
      .sorted()
  }

  private func name(_ host: HostID) -> String {
    guard case .remote(let id) = host else { return "" }
    return "\(prefix!)-\(id.uuidString.lowercased())"
  }

  /// One shell line on the VM over plain ssh with the config the driver wrote for it, not over the
  /// Mac's link to the agent: the user's own `known_hosts` has no entry for a new VM's name. Its
  /// output, then `exit=<status>`.
  private func onBox(_ host: HostID, _ line: String) throws -> String {
    guard case .remote(let id) = host else { throw HostDriverError.unknownHost(host) }
    let config = directory.appendingPathComponent(id.uuidString).appendingPathComponent(
      "ssh_config")
    let (_, output) = try ssh(
      ["-F", config.path, ContainerHostDriver.alias, "\(line); echo exit=$?"])
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: The parity cases

  func testInstancesDerivedFromOneBaseCarryItsDiskButMintTheirOwnIdentity() async throws {
    try await instancesCarryTheBaseDiskButNotItsIdentity(provider())
  }

  func testADerivedWorkroomServesAsSoonAsItsDeriveReturns() async throws {
    try await aDerivedWorkroomServesAsSoonAsItsDeriveReturns(provider())
  }

  @MainActor
  func testWorkroomsDerivedOnExeDevPushWithTheMacDisconnectedAndSurviveARestart() async throws {
    try await workroomsPushWithTheMacDisconnectedAndSurviveARestart(provider())
  }

  @MainActor
  func testAWorkroomThatFailsAfterItsDeriveLeavesNoVMAndNoGrant() async throws {
    try await aWorkroomThatFailsAfterItsDeriveLeavesNothing(provider())
  }

  @MainActor
  func testARemoteWorkroomIsMadeAndTakenDownOnExeDevAsTheAppDoesIt() async throws {
    let driver = driver()
    let account = try await driver.signedIn()
    try await aRemoteWorkroomIsMadeAndTakenDownAsTheAppDoesIt(
      provider(driver, key: .exeDev(account: account)))
  }

  // MARK: exe.dev's own steps

  /// The lobby, except that the command named in `failing` fails once. Named with a `+`, it runs
  /// and THEN fails, as an ssh cut off after exe.dev took the request does.
  private final class FailingLobby: StatusCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var failing: String?
    private let real = StatusCommandRunner()

    func fail(_ step: String) { lock.withLock { failing = step } }
    var pending: Bool { lock.withLock { failing != nil } }

    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
      let command = args.count > 3 ? args[3] : ""
      let step = lock.withLock { () -> String? in
        guard let failing, failing == command || failing == command + "+" else { return nil }
        self.failing = nil
        return failing
      }
      let injected = CommandResult(
        stdout: #"{"error":"injected failure"}"#, stderr: "", exitCode: 1, timedOut: false)
      guard let step else {
        return await real.run(executable, args, in: directory, timeout: timeout)
      }
      if step.hasSuffix("+") {
        _ = await real.run(executable, args, in: directory, timeout: timeout)
      }
      return injected
    }
  }

  /// AC 5, for the provider's steps: a derive that fails at each lobby step, or after it ran (`+`:
  /// the copy exists and the lobby said otherwise), leaves no VM but the base.
  func testADeriveThatFailsAtEachStepLeavesNoVM() async throws {
    let lobby = FailingLobby()
    let driver = driver(runner: lobby)
    let base = try await driver.create()

    for step in ["ls", "cp", "cp+"] {
      lobby.fail(step)
      do {
        _ = try await driver.deriveFromBase(base)
        XCTFail("a derive that failed at \(step) succeeded")
      } catch HostDriverError.provisioning(let detail) {
        XCTAssertTrue(detail.contains("injected failure"), "\(step): \(detail)")
      }
      XCTAssertFalse(lobby.pending, "the derive never reached \(step)")
      XCTAssertEqual(try leftovers(), [name(base)], "a derive that failed at \(step) left a VM")
    }
    try await driver.destroy(base)
    XCTAssertEqual(try leftovers(), [])
  }

  /// Deriving from a workroom, not its base, is refused before anything is copied: a workroom's
  /// disk holds its own enrolment.
  func testAWorkroomIsNeverDerivedFrom() async throws {
    let driver = driver()
    let base = try await driver.create()
    let instance = try await driver.deriveFromBase(base)
    do {
      _ = try await driver.deriveFromBase(instance)
      XCTFail("derived from a workroom")
    } catch HostDriverError.invalidConfiguration(let detail) {
      XCTAssertEqual(detail, "a workroom instance cannot be derived from")
    }
    XCTAssertEqual(try leftovers(), [name(base), name(instance)].sorted())
    for host in [instance, base] { try await driver.destroy(host) }
  }
}

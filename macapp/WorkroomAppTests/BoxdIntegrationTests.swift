import CryptoKit
import XCTest

@testable import Workroom

/// `BoxdHostDriver` on real boxd machines (#256): bases, workrooms derived from them through the
/// portable path, and what each failure leaves. These make and remove real machines on the
/// signed-in boxd account, so they run only when asked for, with the sandbox off (the CLI's gRPC
/// does not go through the sandbox's proxy):
///
///   TEST_RUNNER_WR_BOXD_TESTS=1 \
///     make app-test APP_TEST_FLAGS=-only-testing:WorkroomAppTests/BoxdIntegrationTests
///
/// `TEST_RUNNER_WR_BOXD_CLI` names the CLI if it is not `~/.local/bin/boxd`. Every machine and
/// snapshot a test makes carries its own prefix, and `tearDown` removes whatever is left by it.
final class BoxdIntegrationTests: ProviderParityTestCase {
  private var directory: URL!
  private var prefix: String!
  private var cli: URL!

  override func setUp() async throws {
    try await super.setUp()
    let environment = ProcessInfo.processInfo.environment
    guard environment["WR_BOXD_TESTS"] == "1" else {
      throw XCTSkip("set TEST_RUNNER_WR_BOXD_TESTS=1 to run these on boxd")
    }
    guard PersistentSessionPaths.linuxAgentURL(architecture: "x86_64") != nil else {
      throw XCTSkip("this build bundles no Linux agent")
    }
    cli = URL(
      fileURLWithPath: environment["WR_BOXD_CLI"]
        ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/boxd").path)
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-boxd-\(UUID().uuidString.prefix(8))")
    prefix = "wrtest-\(UUID().uuidString.prefix(8).lowercased())"
  }

  override func tearDown() async throws {
    for connection in connections { await connection.close() }
    connections.removeAll()
    if cli != nil, prefix != nil {
      for name in (try? leftovers("machine")) ?? [] {
        _ = try? boxd(["machine", "remove", name, "-y"])
      }
      for name in (try? leftovers("snapshots")) ?? [] {
        _ = try? boxd(["snapshots", "remove", name, "-y"])
      }
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
    try await super.tearDown()
  }

  // MARK: Helpers

  private func driver(cli override: URL? = nil) -> BoxdHostDriver {
    BoxdHostDriver(
      configuration: .init(cli: override ?? cli, prefix: prefix), directory: directory)
  }

  /// The real CLI, run from here rather than through the driver, so a check is never the thing
  /// under test. Its stdout; a failure throws with its stderr.
  @discardableResult
  private func boxd(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = cli
    process.arguments = arguments + ["--json"]
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let said = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw HostDriverError.provisioning(String(decoding: said, as: UTF8.self))
    }
    return String(decoding: data, as: UTF8.self)
  }

  /// This test's machines (`machine`) or snapshots (`snapshots`), by name.
  private func leftovers(_ kind: String) throws -> [String] {
    let listed = try boxd([kind, "list"])
    let rows = try JSONSerialization.jsonObject(with: Data(listed.utf8)) as? [[String: Any]] ?? []
    return rows.compactMap { $0["name"] as? String }.filter { $0.hasPrefix(prefix + "-") }.sorted()
  }

  private func name(_ host: HostID) -> String {
    guard case .remote(let id) = host else { return "" }
    return "\(prefix!)-\(id.uuidString.lowercased())"
  }

  /// boxd, as the parity cases need it: its machines and snapshots are both leftovers.
  private func provider(cli override: URL? = nil) -> LiveProvider {
    LiveProvider(
      driver: driver(cli: override), key: .boxd(org: nil, account: nil), user: BoxdHostDriver.user,
      sshHostKey: "/etc/ssh/ssh_host_ed25519_key.pub", name: name,
      onBox: { host, line in try self.onBox(host, line) },
      restart: { host in
        try self.boxd(["machine", "stop", self.name(host)])
        try self.boxd(["machine", "start", self.name(host)])
      },
      leftovers: { try self.leftovers("machine") + self.leftovers("snapshots") },
      providerHelperCheck: { host in
        // boxd's helper is still in system config, and the agent's comes after an empty entry
        // that resets the list, so the password git is given is the broker's.
        XCTAssertTrue(
          try self.onBox(host, "git config --system --get credential.https://github.com.helper")
            .contains("boxd"),
          "boxd's own helper is gone, so this shows nothing about which one wins")
      })
  }

  /// The signed-in account's key, for a workroom made the way the app does it.
  private func appKey() throws -> RemoteHosts.DriverKey {
    let account =
      try JSONSerialization.jsonObject(with: Data(try boxd(["auth"]).utf8)) as? [String: Any]
    return .boxd(
      org: account?["active_org"] as? String, account: account?["user_id"] as? String)
  }

  /// One shell line run through boxd's own exec, the provider's control plane, rather than over
  /// the Mac's link: as the ssh user. Its output, then `exit=<status>`.
  private func onBox(_ host: HostID, _ line: String) throws -> String {
    let process = Process()
    process.executableURL = cli
    process.arguments = ["machine", "exec", name(host), "--", "\(line); echo exit=$?"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n")
      .filter { !$0.contains("new version of boxd") && !$0.contains("downloads/install.sh") }
      .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: The driver

  /// AC 3, for the machine (`ProviderParityTestCase`). On boxd the instance's own kernel is the
  /// derive's reboot: every fresh boxd machine shares one boot_id (measured).
  func testInstancesDerivedFromOneBaseCarryItsDiskButMintTheirOwnIdentity() async throws {
    try await instancesCarryTheBaseDiskButNotItsIdentity(provider())
  }

  func testADerivedWorkroomServesAsSoonAsItsDeriveReturns() async throws {
    try await aDerivedWorkroomServesAsSoonAsItsDeriveReturns(provider())
  }

  /// AC 5, for the provider's steps: a derive that fails at each CLI step, or after it ran (`+`:
  /// the machine or snapshot exists and the CLI said otherwise), leaves no machine or snapshot.
  func testADeriveThatFailsAtEachStepLeavesNoMachineOrSnapshot() async throws {
    let (script, failing) = try failingCLI()
    let driver = driver(cli: script)
    let base = try await driver.create()

    for step in [
      "snapshots save", "snapshots save+", "machine new", "machine new+", "snapshots remove",
      "machine reboot",
    ] {
      try step.write(to: failing, atomically: true, encoding: .utf8)
      do {
        _ = try await driver.deriveFromBase(base)
        XCTFail("a derive that failed at \(step) succeeded")
      } catch HostDriverError.provisioning(let detail) {
        XCTAssertTrue(detail.contains("injected failure"), "\(step): \(detail)")
      }
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: failing.path), "the derive never reached \(step)")
      XCTAssertEqual(
        try leftovers("machine"), [name(base)], "a derive that failed at \(step) left a machine")
      XCTAssertEqual(
        try leftovers("snapshots"), [], "a derive that failed at \(step) left a snapshot")
    }
    try await driver.destroy(base)
  }

  /// The CLI, except that the command (`machine new`, `snapshots save`, …) named in `failing`
  /// fails once, and the file goes. Named with a `+`, the command runs and THEN fails, as a CLI
  /// killed after the API took the request does. Once, so the rollback's own `remove` goes
  /// through.
  private func failingCLI() throws -> (cli: URL, failing: URL) {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let failing = directory.appendingPathComponent("failing")
    let script = directory.appendingPathComponent("boxd")
    try """
    #!/bin/sh
    step=$(cat \(PosixShell.quoted(failing.path)) 2>/dev/null)
    if [ "$step" = "$1 $2" ]; then
      rm -f \(PosixShell.quoted(failing.path)); echo "error: injected failure" >&2; exit 1
    fi
    if [ "$step" = "$1 $2+" ]; then
      rm -f \(PosixShell.quoted(failing.path))
      \(PosixShell.quoted(cli.path)) "$@" >/dev/null; echo "error: injected failure" >&2; exit 1
    fi
    exec \(PosixShell.quoted(cli.path)) "$@"

    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return (script, failing)
  }

  // MARK: Workrooms, through the derivation sequence (`ProviderParityTestCase`)

  /// boxd also installs a system credential helper; the agent's must win over it.
  @MainActor
  func testWorkroomsDerivedOnBoxdPushWithTheMacDisconnectedAndSurviveAStop() async throws {
    try await workroomsPushWithTheMacDisconnectedAndSurviveARestart(provider())
  }

  @MainActor
  func testAWorkroomThatFailsAfterItsDeriveLeavesNoMachineAndNoGrant() async throws {
    try await aWorkroomThatFailsAfterItsDeriveLeavesNothing(provider())
  }

  // MARK: In the app (#356)

  @MainActor
  func testARemoteWorkroomIsMadeAndTakenDownOnBoxdAsTheAppDoesIt() async throws {
    let base = provider()
    let app = LiveProvider(
      driver: base.driver, key: try appKey(), user: base.user, sshHostKey: base.sshHostKey,
      name: base.name, onBox: base.onBox, restart: base.restart, leftovers: base.leftovers)
    try await aRemoteWorkroomIsMadeAndTakenDownAsTheAppDoesIt(app)
  }

  // MARK: Sleep (#257, #356)

  /// boxd's own record of whether a machine is asleep, from its control plane, which never
  /// reaches the machine and so never wakes it.
  private func status(_ host: HostID) throws -> String {
    let got = try JSONSerialization.jsonObject(
      with: Data(try boxd(["machine", "get", name(host)]).utf8))
    return (got as? [String: Any])?["status"] as? String ?? "?"
  }

  private func asleep(_ host: HostID) -> Bool {
    BoxdHostDriver.asleepStatuses.contains((try? status(host)) ?? "")
  }

  /// Suspend and hibernate after `seconds` idle on the network.
  private func idleTimers(_ host: HostID, _ seconds: Int) throws {
    for setting in ["auto-suspend.timeout", "auto-hibernate.timeout"] {
      try boxd(["machine", "config", "set", name(host), setting, String(seconds)])
    }
  }

  /// A job of `seconds` that burns a core and uses no network, writing one line a second to
  /// `~/ticks`, detached so it outlives the exec. A box that sleeps stops its clock, and the ticks.
  private func startJob(_ driver: any HostDriver, _ host: HostID, seconds: Int) async throws {
    try await onHost(
      driver, host,
      "rm -f ~/ticks; nohup sh -c 'i=0; while [ $i -lt \(seconds) ]; do i=$((i+1)); echo $i >> ~/ticks;"
        + " t=$(date +%s); while [ $(date +%s) -eq $t ]; do :; done; done' > /dev/null 2>&1 &")
  }

  /// The ticks the job logged. Reading them wakes the box.
  private func ticks(_ driver: any HostDriver, _ host: HostID) async throws -> Int {
    Int(try await onHost(driver, host, "wc -l < ~/ticks")) ?? 0
  }

  /// Polls boxd every 20 s until `host` is asleep or `limit` passes; when it fell asleep, measured
  /// from `since`, or nil.
  private func sleeps(_ host: HostID, since: ContinuousClock.Instant, within limit: Duration)
    async throws -> Duration?
  {
    while ContinuousClock.now - since < limit {
      if asleep(host) { return ContinuousClock.now - since }
      try await Task.sleep(for: .seconds(20))
    }
    return nil
  }

  /// #257's acceptance, rerunnable (#356; it was a TODO). Two machines with 120 s timers run the same 6-minute job with no
  /// network use and no client attached. The control, with no agent, sleeps mid-job, which is
  /// what lets the other result mean anything; the agent's machine logs every tick, then sleeps
  /// once the job has ended. About 10 minutes.
  func testTheHeartbeatKeepsABusyBoxAwakeAndABoxWithoutOneSleeps() async throws {
    let driver = driver()
    let control = HostID.remote(UUID())
    try boxd([
      "machine", "new", name(control), "--auto-suspend-timeout=120", "--auto-hibernate-timeout=120",
    ])
    let kept = try await driver.create()
    try idleTimers(kept, 120)
    // Connected once, to push the agent, then let go: no client is attached for the run.
    let pushed = try await AgentBootstrap.connect(
      host: kept, driver: driver, socket: driver.agentSocket, handOff: false)
    await pushed.close()
    let start = ContinuousClock.now
    try await startJob(driver, control, seconds: 360)
    try await startJob(driver, kept, seconds: 360)

    let controlSlept = try await sleeps(control, since: start, within: .seconds(330))
    XCTAssertNotNil(controlSlept, "the control never slept mid-job, so the run proves nothing")
    let keptSlept = try await sleeps(kept, since: start, within: .seconds(600))
    XCTAssertNotNil(keptSlept, "the agent's machine never slept after its job")
    if let keptSlept { XCTAssertGreaterThan(keptSlept, .seconds(360), "it slept under its job") }
    let controlTicks = try await ticks(driver, control)
    let keptTicks = try await ticks(driver, kept)
    XCTAssertLessThan(controlTicks, 360)
    XCTAssertEqual(keptTicks, 360, "the agent's machine missed ticks")
  }
}

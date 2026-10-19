import AgentConnection
import HostDrivers
import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import Workroom

final class RemoteProvisioningTests: XCTestCase {
  /// The clone token reaches git as configuration in its environment, an `Authorization` header
  /// for github.com only, and nowhere a process list, a remote URL or a file would show it. An
  /// ssh-form origin is rewritten so the header reaches it.
  func testTheCloneTokenReachesGitOnlyAsAGitHubHeaderInItsEnvironment() throws {
    let environment = RemoteProvisioning.cloneEnvironment(token: "ghs_secret")

    XCTAssertEqual(environment["GIT_CONFIG_COUNT"], "2")
    XCTAssertEqual(environment["GIT_CONFIG_KEY_0"], "http.https://github.com/.extraHeader")
    let value = try XCTUnwrap(environment["GIT_CONFIG_VALUE_0"])
    XCTAssertTrue(value.hasPrefix("Authorization: Basic "))
    let credentials = try XCTUnwrap(
      Data(base64Encoded: String(value.dropFirst("Authorization: Basic ".count))))
    XCTAssertEqual(String(decoding: credentials, as: UTF8.self), "x-access-token:ghs_secret")
    XCTAssertFalse(environment.values.contains { $0.contains("ghs_secret") })
    XCTAssertEqual(environment["GIT_CONFIG_KEY_1"], "url.https://github.com/.insteadOf")
    XCTAssertEqual(environment["GIT_CONFIG_VALUE_1"], "git@github.com:")
  }
}

/// `WORKROOM_HOST`, the word a script branches on to know where it runs.
final class RemoteProvisioningHostKindTests: XCTestCase {
  /// Value: protects=the documented WORKROOM_HOST word for each kind of host (docker, apple, boxd,
  /// exedev); fails_when=a kind's word changes or two kinds swap; why_new=tests pass a literal
  /// hostKind; seam=none; no_claim=the word reaching a script
  func testEachKindOfHostHasItsDocumentedWord() {
    XCTAssertEqual(RemoteProvisioning.hostKind(.init(runtime: .docker)), "docker")
    XCTAssertEqual(
      RemoteProvisioning.hostKind(.init(runtime: .docker, context: "colima")), "docker")
    XCTAssertEqual(RemoteProvisioning.hostKind(.init(runtime: .apple)), "apple")
    XCTAssertEqual(RemoteProvisioning.hostKind(.boxd(org: nil, account: nil)), "boxd")
    XCTAssertEqual(RemoteProvisioning.hostKind(.exeDev(account: nil)), "exedev")
  }
}

/// Which credentials a workroom's clone takes: a local container's, the Mac's own GitHub token
/// through the relay (#309); a remote provider's, whatever the provider gave its host.
final class RemoteProvisioningCredentialsTests: XCTestCase {
  /// A connection the sequence reaches and then loses, so the git it runs fails at once.
  private static let lostConnection: @Sendable (HostID) async throws -> AgentVCSConnection = {
    host in
    let fake = try FakeAgent(version: 4)
    defer { fake.stop() }
    return try await AgentVCSConnection.connect(host: host, socketPath: fake.socketPath)
  }

  private func environment(
    gitHubToken: (@Sendable () async throws -> String)?, credentialHint: String? = nil,
    driver: any HostDriver = CountingDriver(),
    connect: @escaping @Sendable (HostID) async throws -> AgentVCSConnection = lostConnection
  ) -> RemoteProvisioning.Environment {
    RemoteProvisioning.Environment(
      driver: driver, agentSocket: RemoteWorkrooms.agentSocket, gitHubToken: gitHubToken,
      credentialHint: credentialHint, connect: connect)
  }

  /// Every git command a host's agent is asked to run succeeds.
  private static let gitSucceeds =
    #"{"stdout":"","stderr":"","exit_code":0,"timed_out":false,"signaled":false}"#

  private static func connecting(to fake: FakeAgent)
    -> @Sendable (HostID) async throws
    -> AgentVCSConnection
  {
    { host in try await AgentVCSConnection.connect(host: host, socketPath: fake.socketPath) }
  }

  private func provision(
    _ environment: RemoteProvisioning.Environment, steps: StepLog = StepLog()
  ) async throws {
    let report: @Sendable (ProvisioningProgress.Step) -> Void = { steps.add($0) }
    try await ProvisioningProgress.$reportStep.withValue(report) {
      _ = try await RemoteProvisioning.provision(
        cloneURL: "u", path: "/p", branch: "b", in: environment)
    }
  }

  /// A container workroom needs the Mac's token before its machine, which can take minutes, not
  /// after.
  func testAContainerWithoutGhMakesNoMachine() async throws {
    let driver = CountingDriver()
    do {
      try await provision(
        environment(gitHubToken: { throw RemoteWorkrooms.Failure.signedOut }, driver: driver))
      XCTFail("expected signedOut")
    } catch RemoteWorkrooms.Failure.signedOut {}
    XCTAssertEqual(driver.creates, 0, "a machine was made first")
  }

  // Value: protects=a create's row says it is cloning, then checking out; fails_when=provision
  // stops reporting a step; why_new=BoxdHostDriverTests stop at the driver's machine/setup steps;
  // nothing reaches these; seam=none
  /// The clone fails on the lost connection, and the machine goes with it.
  func testAFailedCloneReportsItsStepAndRemovesTheMachine() async throws {
    let driver = CountingDriver()
    let steps = StepLog()
    _ = try? await provision(environment(gitHubToken: { "gho_mac" }, driver: driver), steps: steps)
    XCTAssertEqual(steps.take(), [.connect, .clone])
    XCTAssertEqual(driver.creates, 1)
    XCTAssertEqual(driver.destroys, 1, "the failed create left its machine")
  }

  // Value: protects=a container workroom ends relayed, clones and switches with the Mac's token,
  // and records only its host; fails_when=relayed is false or the token stops reaching git;
  // why_new=the other tests stop at the lost clone; seam=none
  /// A container workroom takes the Mac's token: relayed, and git told to start from origin's
  /// default branch.
  func testAContainerWorkroomClonesWithTheMacsTokenAndEndsRelayed() async throws {
    let fake = try FakeAgent(version: 4, execResult: Self.gitSucceeds)
    defer { fake.stop() }
    let driver = CountingDriver()
    let checkpoints = CheckpointLog()

    let instance = try await RemoteProvisioning.provision(
      cloneURL: "git@github.com:o/r.git", path: "/p", branch: "wr-b",
      in: environment(
        gitHubToken: { "gho_mac" }, driver: driver, connect: Self.connecting(to: fake))
    ) { host in checkpoints.add(host) }
    await instance.connection.close()

    XCTAssertTrue(instance.relayed)
    XCTAssertEqual(checkpoints.all, [instance.host])
    XCTAssertEqual(driver.destroys, 0)

    let requests = try execs(of: fake)
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(
      requests[0]["args"] as? [String],
      ["clone", "--quiet", "--origin", "origin", "--", "git@github.com:o/r.git", "/p"])
    XCTAssertEqual(
      requests[1]["args"] as? [String],
      ["switch", "--quiet", "--no-track", "--create", "wr-b", "refs/remotes/origin/HEAD"])
    for request in requests {
      let env = try XCTUnwrap(request["env"] as? [String: String])
      for (key, value) in RemoteProvisioning.cloneEnvironment(token: "gho_mac") {
        XCTAssertEqual(env[key], value, key)
      }
    }
  }

  /// The create's log shows each git command under its own step, and never the token git was
  /// given (#483, AC 5).
  /// Value: protects=the clone and checkout rows show `$ git …` and git's output, and no line
  /// carries the Mac's token or the extraHeader; fails_when=git's commands go unlogged, land under
  /// the wrong step, or the clone environment is logged; no_claim=the drivers' own command logs
  /// (HostDrivers' ProvisioningLogTests); a FakeAgent stands in for the host's git
  func testTheCreateLogShowsGitCommandsAndNeverTheToken() async throws {
    let fake = try FakeAgent(
      version: 4,
      execResult:
        #"{"stdout":"","stderr":"Cloning into 'p'...","exit_code":0,"timed_out":false,"signaled":false}"#
    )
    defer { fake.stop() }
    let lines = LineLog()
    let sink: @Sendable (ProvisioningProgress.Step, String) -> Void = { lines.add($0, $1) }

    let instance = try await ProvisioningProgress.$log.withValue(sink) {
      try await RemoteProvisioning.provision(
        cloneURL: "git@github.com:o/r.git", path: "/p", branch: "wr-b",
        in: environment(gitHubToken: { "gho_mac" }, connect: Self.connecting(to: fake)))
    }
    await instance.connection.close()

    let all = lines.all
    XCTAssertEqual(
      all.filter { $0.0 == .clone }.map(\.1),
      ["$ git clone --quiet --origin origin -- git@github.com:o/r.git /p", "Cloning into 'p'..."])
    XCTAssertEqual(
      all.filter { $0.0 == .checkout }.first?.1,
      "$ git switch --quiet --no-track --create wr-b refs/remotes/origin/HEAD")
    // The header and its encoded token; the clone URL itself is no secret.
    let secrets =
      ["gho_mac", "extraHeader", "Authorization", "GIT_CONFIG"]
      + [Data("x-access-token:gho_mac".utf8).base64EncodedString()]
    for (_, line) in all {
      for secret in secrets { XCTAssertFalse(line.contains(secret), line) }
    }
  }

  // Value: protects=a remote provider's workroom gets no credential from Workroom and is not
  // relayed; fails_when=the Mac's token or the relay leaks onto a provider's host; why_new=no
  // other test provisions a remote provider's host; seam=none
  /// A remote provider's host clones with the provider's own credentials: git is given none.
  func testARemoteProvidersWorkroomClonesWithNothingFromTheMac() async throws {
    let fake = try FakeAgent(version: 4, execResult: Self.gitSucceeds)
    defer { fake.stop() }

    let instance = try await RemoteProvisioning.provision(
      cloneURL: "https://github.com/o/r.git", path: "/p", branch: "wr-b",
      in: environment(gitHubToken: nil, connect: Self.connecting(to: fake)))
    await instance.connection.close()

    XCTAssertFalse(instance.relayed)
    for request in try execs(of: fake) {
      let env = request["env"] as? [String: String] ?? [:]
      XCTAssertFalse(env.keys.contains { $0.hasPrefix("GIT_CONFIG") }, "\(env)")
    }
  }

  // Value: protects=a clone the provider refused says how to give the host GitHub access, and the
  // machine goes; fails_when=the hint is dropped or the rollback skipped; why_new=there is no
  // preflight, so the clone's failure is where the user learns it; seam=none
  /// A clone that fails says git's own words, then the provider's fix, and removes the machine.
  func testAFailedCloneOnAProviderSaysHowToGiveItGitHubAccess() async throws {
    let fake = try FakeAgent(
      version: 4,
      execResult:
        #"{"stdout":"","stderr":"fatal: could not read Username","exit_code":128,"timed_out":false,"signaled":false}"#
    )
    defer { fake.stop() }
    let driver = CountingDriver()
    do {
      _ = try await RemoteProvisioning.provision(
        cloneURL: "https://github.com/o/r.git", path: "/p", branch: "b",
        in: environment(
          gitHubToken: nil, credentialHint: "Connect GitHub.", driver: driver,
          connect: Self.connecting(to: fake)))
      XCTFail("the clone succeeded")
    } catch RemoteProvisioning.Failure.git(let command, let detail) {
      XCTAssertEqual(command, "clone")
      XCTAssertEqual(detail, "fatal: could not read Username\n\nConnect GitHub.")
    }
    XCTAssertEqual(driver.destroys, 1, "the failed create left its machine")
  }

  // Value: protects=a host that exists is recorded before anything else runs on it, and a record
  // that fails undoes the create without connecting; fails_when=the first checkpoint moves outside
  // the rollback, or after connect; why_new=nothing else fails the host's own record; seam=none
  /// The host is recorded the moment it exists: a record that fails removes it, before any agent is
  /// reached.
  func testAHostThatCannotBeRecordedIsRemovedBeforeAnythingRunsOnIt() async throws {
    let driver = CountingDriver()
    let connects = StepLog()
    struct NoRecord: Error {}
    do {
      _ = try await RemoteProvisioning.provision(
        cloneURL: "u", path: "/p", branch: "b",
        in: environment(
          gitHubToken: { "gho_mac" }, driver: driver,
          connect: { _ in
            connects.add(.setup)
            throw HostDriverError.provisioning("connected")
          })
      ) { _ in throw NoRecord() }
      XCTFail("a create whose host could not be recorded succeeded")
    } catch is NoRecord {}
    XCTAssertEqual(driver.destroys, 1, "the unrecorded host was left running")
    XCTAssertEqual(connects.take(), [], "an unrecorded host was used")
  }

  private func execs(of fake: FakeAgent) throws -> [[String: Any]] {
    try fake.receivedExecs.map {
      try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
  }
}

private final class CheckpointLog: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [HostID] = []
  var all: [HostID] { lock.withLock { seen } }
  func add(_ host: HostID) { lock.withLock { seen.append(host) } }
}

/// Makes a host for every create, and counts what it makes and takes down.
private final class CountingDriver: HostDriver, @unchecked Sendable {
  private let lock = NSLock()
  private var made = 0
  private var removed = 0
  var creates: Int { lock.withLock { made } }
  var destroys: Int { lock.withLock { removed } }

  func create() async throws -> HostID {
    lock.withLock { made += 1 }
    return .remote(UUID())
  }
  func destroy(_ host: HostID) async throws { lock.withLock { removed += 1 } }
  func openStream(to host: HostID) async throws -> HostStream {
    throw HostDriverError.notImplemented("openStream")
  }
  func exec(_ command: String, on host: HostID) async throws -> HostStream {
    throw HostDriverError.notImplemented("exec")
  }
}

private final class StepLog: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [ProvisioningProgress.Step] = []
  func add(_ step: ProvisioningProgress.Step) { lock.withLock { seen.append(step) } }
  func take() -> [ProvisioningProgress.Step] {
    lock.withLock {
      defer { seen = [] }
      return seen
    }
  }
}

private final class LineLog: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [(ProvisioningProgress.Step, String)] = []
  func add(_ step: ProvisioningProgress.Step, _ line: String) {
    lock.withLock { seen.append((step, line)) }
  }
  var all: [(ProvisioningProgress.Step, String)] { lock.withLock { seen } }
}

/// Copying the root's included files into a remote workroom's checkout (#367): the CLI's archive,
/// streamed into tar on the host. The "host" here is a local shell, so the extraction is real tar.
final class RemoteIncludeTests: XCTestCase {
  /// A driver whose host is this Mac's shell; `prefix` runs first (a PATH with no tar, say).
  private struct ShellHost: HostDriver {
    var prefix = ""
    var execFails = false
    func create() async throws -> HostID { .local }
    func destroy(_ host: HostID) async throws {}
    func openStream(to host: HostID) async throws -> HostStream {
      throw HostDriverError.notImplemented("stream")
    }
    func exec(_ command: String, on host: HostID) async throws -> HostStream {
      if execFails { throw HostDriverError.provisioning("the host is gone") }
      return try HostStream.spawn(
        URL(fileURLWithPath: "/bin/sh"), ["-c", prefix + command], environment: [:],
        handshakeTimeout: 5, purpose: .exchange)
    }
  }

  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("remote-include-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  /// An archive closure that tars `files` (path: mode) from a root of its own into the URL it gets.
  private func archive(
    _ files: [String: Int], warnings: [String] = []
  ) throws -> @Sendable (URL) async throws -> IncludeArchive {
    let root = scratch.appendingPathComponent("root")
    for (path, mode) in files {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(path.utf8).write(to: url)
      try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
    let paths = files.keys.sorted()
    return { output in
      let tar = Process()
      tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
      tar.arguments = ["-cf", output.path, "-C", root.path] + paths
      try tar.run()
      tar.waitUntilExit()
      return IncludeArchive(
        paths: paths, bytes: Int64(paths.map(\.utf8.count).reduce(0, +)), warnings: warnings)
    }
  }

  private func checkout() throws -> URL {
    let url = scratch.appendingPathComponent("checkout")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Value: protects=the included files land in the host's checkout at their paths with their
  /// modes, and the log names each; fails_when=the archive isn't streamed into tar, the mode is
  /// lost, or the log is missing; no_claim=GNU tar on Linux (see the ssh-fixture test)
  func testTheIncludedFilesLandInTheCheckoutWithTheirModes() async throws {
    let checkout = try checkout()
    let result = await RemoteProvisioning.copyIncluded(
      into: checkout.path, on: .local, driver: ShellHost(),
      archive: try archive([".env": 0o600, "secrets/a.json": 0o664]))
    guard case .copied(let log) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(Array(log.prefix(2)), ["Copied .env", "Copied secrets/a.json"])
    for (path, mode) in [".env": 0o600, "secrets/a.json": 0o664] {
      let url = checkout.appendingPathComponent(path)
      XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), path)
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, mode, path)
    }
  }

  /// Value: protects=a file the checkout already has is kept; fails_when=tar overwrites it;
  /// no_claim=none beyond protects
  func testAFileTheCheckoutHasIsKept() async throws {
    let checkout = try checkout()
    try Data("mine".utf8).write(to: checkout.appendingPathComponent(".env"))
    _ = await RemoteProvisioning.copyIncluded(
      into: checkout.path, on: .local, driver: ShellHost(), archive: try archive([".env": 0o644]))
    XCTAssertEqual(
      try String(contentsOf: checkout.appendingPathComponent(".env"), encoding: .utf8), "mine")
  }

  /// Value: protects=every way the copy can fail ends as a warning saying why, never a throw that
  /// would undo the create (Q4); fails_when=a failure is swallowed or escapes; no_claim=the
  /// warnings' full wording
  func testEachFailureIsAWarningSayingWhy() async throws {
    let checkout = try checkout()
    let noTar = await RemoteProvisioning.copyIncluded(
      into: checkout.path, on: .local, driver: ShellHost(prefix: "PATH=/nonexistent; "),
      archive: try archive([".env": 0o644]))
    guard case .warning(let text, _) = noTar else { return XCTFail("\(noTar)") }
    XCTAssertTrue(text.contains("tar is not installed"), text)

    let gone = await RemoteProvisioning.copyIncluded(
      into: checkout.path, on: .local, driver: ShellHost(execFails: true),
      archive: try archive([".env": 0o644]))
    guard case .warning(let goneText, _) = gone else { return XCTFail("\(gone)") }
    XCTAssertTrue(goneText.contains("the host is gone"), goneText)

    let unarchived = await RemoteProvisioning.copyIncluded(
      into: checkout.path, on: .local, driver: ShellHost()
    ) { _ in throw WorkroomCLIError.cli(kind: "Boom", message: "no archive") }
    guard case .warning(let archiveText, _) = unarchived else { return XCTFail("\(unarchived)") }
    XCTAssertTrue(archiveText.contains("no archive"), archiveText)

    let unreadable = await RemoteProvisioning.copyIncluded(
      into: checkout.path, on: .local, driver: ShellHost(),
      archive: try archive(["ok.env": 0o644], warnings: ["bad.key: permission denied"]))
    guard case .warning(let unreadableText, let log) = unreadable else {
      return XCTFail("\(unreadable)")
    }
    XCTAssertTrue(unreadableText.contains("bad.key"), unreadableText)
    XCTAssertEqual(log.first, "Copied ok.env")
  }

  /// Value: protects=an include file that matches nothing ends skipped, and nothing runs on the
  /// host; fails_when=it ends copied or warns; no_claim=none beyond protects
  func testNothingToCopyIsSkipped() async throws {
    let result = await RemoteProvisioning.copyIncluded(
      into: try checkout().path, on: .local, driver: ShellHost(execFails: true)
    ) { _ in IncludeArchive(paths: [], bytes: 0, warnings: []) }
    XCTAssertEqual(result, .skipped("No matching files", log: []))
  }

  /// Value: protects=a symlink the include file matched is named as skipped, and when only symlinks
  /// matched the step says so rather than that nothing did; fails_when=the archive's skipped list is
  /// dropped or the reason reads "No matching files"; no_claim=the CLI side (cmd tests)
  func testSkippedSymlinksAreNamed() async throws {
    let only = await RemoteProvisioning.copyIncluded(
      into: try checkout().path, on: .local, driver: ShellHost(execFails: true)
    ) { _ in IncludeArchive(paths: [], bytes: 0, warnings: [], skipped: [".env"]) }
    XCTAssertEqual(
      only, .skipped("Only symlinks matched: .env", log: ["Skipped .env: it's a symlink"]))

    let make = try archive(["ok.key": 0o600])
    let some = await RemoteProvisioning.copyIncluded(
      into: try checkout().path, on: .local, driver: ShellHost(),
      archive: { output in
        var made = try await make(output)
        made.skipped = [".env"]
        return made
      })
    guard case .copied(let log) = some else { return XCTFail("\(some)") }
    XCTAssertEqual(log.first, "Skipped .env: it's a symlink")
    XCTAssertTrue(log.contains("Copied ok.key"), "\(log)")
  }
}

/// A workroom's setup and teardown scripts on a remote host (`RemoteProvisioning.runScript`): the
/// "host" is this Mac's shell, and the agent is this build's own, so `run-script` really runs.
final class RemoteScriptTests: XCTestCase {
  private struct ShellHost: HostDriver {
    var execFails = false
    /// The status the host's `test -e` gives instead of its own: ssh's 255 for a dropped link.
    var checkExits: Int32?
    func create() async throws -> HostID { .local }
    func destroy(_ host: HostID) async throws {}
    func openStream(to host: HostID) async throws -> HostStream {
      throw HostDriverError.notImplemented("stream")
    }
    func exec(_ command: String, on host: HostID) async throws -> HostStream {
      if execFails { throw HostDriverError.provisioning("the host is gone") }
      let line =
        command.hasPrefix("test -e ") && checkExits != nil
        ? "echo 'Connection closed by remote host' >&2; exit \(checkExits ?? 0)" : command
      return try HostStream.spawn(
        URL(fileURLWithPath: "/bin/sh"), ["-c", line], environment: [:],
        handshakeTimeout: 5, purpose: .exchange)
    }
  }

  private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    private var started = 0
    var lines: [String] { lock.withLock { all } }
    var starts: Int { lock.withLock { started } }
    func add(_ line: String) { lock.withLock { all.append(line) } }
    func start() { lock.withLock { started += 1 } }
  }

  private static let contract = URL(fileURLWithPath: String(describing: #filePath))
    .deletingLastPathComponent()  // WorkroomAppTests
    .deletingLastPathComponent()  // macapp
    .deletingLastPathComponent()  // repository root
    .appendingPathComponent("testdata/script-env")

  private var scratch: URL!
  private var agent: String!

  override func setUpWithError() throws {
    agent = try XCTUnwrap(PersistentSessionPaths.binaryURL(for: .rustAgent), "no wr-agent").path
    // Real paths: the script compares `pwd -P` with them, and /var is a symlink on macOS.
    let made = FileManager.default.temporaryDirectory
      .appendingPathComponent("remote-script-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: made.appendingPathComponent("checkout/scripts"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: made.appendingPathComponent("root/scripts"), withIntermediateDirectories: true)
    // `realpath`, not `resolvingSymlinksInPath`, which turns /private/var back into /var.
    let resolved = try XCTUnwrap(realpath(made.path, nil))
    defer { free(resolved) }
    scratch = URL(fileURLWithPath: String(cString: resolved))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  private var checkout: String { scratch.appendingPathComponent("checkout").path }

  @discardableResult
  private func write(_ body: String, to path: String, mode: Int = 0o755) throws -> URL {
    let url = scratch.appendingPathComponent(path)
    try Data(body.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    return url
  }

  private var rootScript: URL { scratch.appendingPathComponent("root/scripts/workroom_setup") }

  private func run(
    _ script: RemoteProvisioning.Script = .setup, driver: ShellHost = ShellHost(),
    lines: Lines = Lines(), judge: @escaping RemoteProvisioning.ScriptJudge = approveAll
  ) async -> RemoteProvisioning.ScriptRun {
    await RemoteProvisioning.runScript(
      script, workroom: "contract", at: checkout, hostKind: "boxd", rootScript: rootScript,
      agentBinary: agent, on: .local, driver: driver, judge: judge, onStart: { lines.start() },
      onLine: { lines.add($0) })
  }

  /// A Mac that has approved every script.
  static let approveAll: RemoteProvisioning.ScriptJudge = { text in judged(text, trusted: true) }

  static func judged(_ text: Data, trusted: Bool) -> ScriptTrust {
    ScriptTrust(
      name: "workroom_setup", origin: "stdin", sha256: "",
      text: String(decoding: text, as: UTF8.self),
      trusted: trusted, exempt: false)
  }

  /// A Mac that has approved `approved` alone, recording each judgement.
  private final class Approving: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Data] = []
    let approved: Data
    init(_ approved: String) { self.approved = Data(approved.utf8) }
    var judged: [Data] { lock.withLock { seen } }
    var judge: RemoteProvisioning.ScriptJudge {
      { text in
        self.lock.withLock { self.seen.append(text) }
        return RemoteScriptTests.judged(text, trusted: text == self.approved)
      }
    }
  }

  /// Value: protects=the checkout's copy is judged by its bytes on the host and, when this Mac has
  /// not approved them, never runs (#363): bytes that differ from the approved ones at the moment
  /// they would run are refused; fails_when=the script runs unjudged, or the bytes judged are not
  /// the host's; no_claim=the CLI's judgement itself (the Go tests)
  func testAnUnapprovedCheckoutScriptNeverRuns() async throws {
    let marker = scratch.appendingPathComponent("ran").path
    let body = "#!/bin/sh\ntouch \(marker)\n"
    try write(body, to: "checkout/scripts/workroom_setup")
    let mac = Approving("#!/bin/sh\necho the approved one\n")

    let result = await run(judge: mac.judge)

    XCTAssertEqual(result, .notTrusted(Self.judged(Data(body.utf8), trusted: false)))
    XCTAssertEqual(mac.judged, [Data(body.utf8)])
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "the script ran")
  }

  /// Value: protects=the root's copy is judged before it is copied up, and an unapproved one is
  /// neither copied nor run; fails_when=it is uploaded or run first; no_claim=the approved copy's
  /// run (testTheRootsCopyRunsWhenTheCheckoutHasNone)
  func testAnUnapprovedRootScriptIsNeitherCopiedNorRun() async throws {
    try write("#!/bin/sh\nexit 0\n", to: "root/scripts/workroom_setup")
    let mac = Approving("#!/bin/sh\necho the approved one\n")

    let result = await run(judge: mac.judge)

    guard case .notTrusted = result else { return XCTFail("\(result)") }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: checkout + "/.git/workroom/workroom_setup"),
      "the root's copy went up")
  }

  /// Value: protects=a judge that can't answer (the CLI failing) fails the script rather than
  /// letting it run; fails_when=an error is taken for approval; no_claim=none
  func testAJudgeThatFailsStopsTheScript() async throws {
    let marker = scratch.appendingPathComponent("ran").path
    try write("#!/bin/sh\ntouch \(marker)\n", to: "checkout/scripts/workroom_setup")

    let result = await run(judge: { _ in throw WorkroomCLIError.timedOut })

    guard case .failed = result else { return XCTFail("\(result)") }
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "the script ran")
  }

  /// Value: protects=the remote contract a script sees (cwd, WORKROOM_* set as the app sets them,
  /// no root path, no probe flag), checked against the fixture the Go and Rust tests share;
  /// fails_when=the app passes a different variable or value; no_claim=a Linux host's shell (the
  /// host is this Mac's)
  func testTheCheckoutsScriptSeesTheRemoteContract() async throws {
    try FileManager.default.copyItem(
      at: Self.contract.appendingPathComponent("workroom_script"),
      to: scratch.appendingPathComponent("checkout/scripts/workroom_setup"))
    let lines = Lines()
    let result = await run(lines: lines)
    XCTAssertEqual(result, .passed)
    XCTAssertEqual(lines.starts, 1)
    let want = try String(
      contentsOf: Self.contract.appendingPathComponent("remote.txt"), encoding: .utf8
    ).replacingOccurrences(of: "{DIR}", with: checkout)
    XCTAssertEqual(lines.lines, want.split(separator: "\n").map(String.init))
  }

  /// Value: protects=the root's copy runs when the checkout has none, copied with its mode (C3);
  /// fails_when=the fallback is missing or the upload forces +x; no_claim=none beyond protects
  func testTheRootsCopyRunsWhenTheCheckoutHasNone() async throws {
    try write("#!/bin/sh\necho from the root\n", to: "root/scripts/workroom_setup")
    let lines = Lines()
    let result = await run(lines: lines)
    XCTAssertEqual(result, .passed)
    XCTAssertEqual(lines.lines, ["from the root"])
    let copy = checkout + "/.git/workroom/workroom_setup"
    let mode = try FileManager.default.attributesOfItem(atPath: copy)[.posixPermissions]
    XCTAssertEqual((mode as? NSNumber)?.intValue, 0o755)

    try write("#!/bin/sh\necho never\n", to: "root/scripts/workroom_setup", mode: 0o644)
    guard case .failed(let why) = await run() else { return XCTFail("a non-executable copy ran") }
    XCTAssertEqual(why, "setup script failed: \(copy) could not be started")
  }

  /// Value: protects=no script anywhere runs nothing and starts no row; fails_when=the row starts
  /// or a failure is reported; no_claim=none beyond protects
  func testNoScriptAnywhereIsAbsent() async {
    let lines = Lines()
    let result = await run(.teardown, lines: lines)
    XCTAssertEqual(result, .absent)
    XCTAssertEqual(lines.starts, 0)
  }

  /// Value: protects=a failing script and an unreachable host are failures worded as the CLI's;
  /// fails_when=either passes or loses its reason; no_claim=none beyond protects
  func testFailuresAreWordedAsTheCLIs() async throws {
    try write("#!/bin/sh\necho dropping\nexit 3\n", to: "checkout/scripts/workroom_teardown")
    let lines = Lines()
    guard case .failed(let why) = await run(.teardown, lines: lines) else {
      return XCTFail("a failing script passed")
    }
    XCTAssertEqual(
      why,
      "teardown script failed: \(checkout)/scripts/workroom_teardown returned a non-zero exit code")
    XCTAssertEqual(lines.lines, ["dropping"])

    guard case .failed(let gone) = await run(.teardown, driver: ShellHost(execFails: true)) else {
      return XCTFail("an unreachable host passed")
    }
    XCTAssertTrue(gone.hasPrefix("teardown script failed: "), gone)
    XCTAssertTrue(gone.contains("the host is gone"), gone)
  }

  /// Value: protects=a host that can't answer whether the script exists (ssh's 255) fails the
  /// teardown instead of reading as "no script", which would destroy the host without it;
  /// fails_when=any non-zero check reads as absent; no_claim=a real ssh drop (a fake exit stands in)
  func testAHostThatCannotBeCheckedFailsRatherThanSkipping() async throws {
    try write("#!/bin/sh\nexit 0\n", to: "checkout/scripts/workroom_teardown")
    let lines = Lines()
    let result = await run(.teardown, driver: ShellHost(checkExits: 255), lines: lines)
    guard case .failed(let why) = result else { return XCTFail("\(result)") }
    XCTAssertTrue(why.contains("couldn't check the host"), why)
    XCTAssertTrue(why.contains("exit 255"), why)
    XCTAssertEqual(lines.starts, 0, "the script ran")
  }

  /// Value: protects=a script's own 124, 126 and 255 are worded as its exit, not as the agent's
  /// timeout or a script that couldn't start, while 255 also names a dropped link; fails_when=the
  /// app reads a status alone as the agent's report; no_claim=a real timeout (the Rust and fixture
  /// tests cover that)
  func testAScriptsOwnExitIsNotTakenForTheAgentsReport() async throws {
    let path = "\(checkout)/scripts/workroom_setup"
    for (code, want) in [
      (124, "\(path) returned a non-zero exit code"),
      (126, "\(path) returned a non-zero exit code"),
      (255, "\(path) returned exit code 255, or the connection to the host dropped while it ran"),
    ] {
      try write("#!/bin/sh\nexit \(code)\n", to: "checkout/scripts/workroom_setup")
      let result = await run()
      XCTAssertEqual(result, .failed("setup script failed: \(want)"), "exit \(code)")
    }
  }

  /// Value: protects=a script that leaves a process printing in the background, holding its output
  /// open, fails once its time is up, as the local CLI call's timeout ends one; fails_when=the
  /// exchange waits for the output to close, which never happens; no_claim=a silent link (the
  /// silence bound, HostStream's tests)
  func testABackgroundedPrinterCannotHoldTheScriptOpen() async throws {
    try write(
      "#!/bin/sh\n(while :; do echo tick; sleep 0.2; done) &\nexit 0\n",
      to: "checkout/scripts/workroom_setup")
    let result = await RemoteProvisioning.runScript(
      .setup, workroom: "contract", at: checkout, hostKind: "boxd", rootScript: rootScript,
      agentBinary: agent, on: .local, driver: ShellHost(), judge: Self.approveAll,
      onLine: { _ in }, timeout: 1, slack: 2)
    let path = "\(checkout)/scripts/workroom_setup"
    XCTAssertEqual(
      result,
      .failed(
        "setup script failed: \(path) still held its output open after 1 s"
          + " (a process it started in the background, perhaps)"))
  }
}

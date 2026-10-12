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
    let report: @Sendable (RemoteProvisioning.Step) -> Void = { steps.add($0) }
    try await RemoteProvisioning.$reportStep.withValue(report) {
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
    XCTAssertEqual(steps.take(), [.clone])
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
  private var seen: [RemoteProvisioning.Step] = []
  func add(_ step: RemoteProvisioning.Step) { lock.withLock { seen.append(step) } }
  func take() -> [RemoteProvisioning.Step] {
    lock.withLock {
      defer { seen = [] }
      return seen
    }
  }
}

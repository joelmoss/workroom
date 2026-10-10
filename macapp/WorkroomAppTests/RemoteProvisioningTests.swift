import CryptoKit
import XCTest

@testable import Workroom

final class RemoteProvisioningTests: XCTestCase {
  /// The clone token reaches git as configuration in its environment, an `Authorization` header
  /// for github.com only, and nowhere a process list, a remote URL or a file would show it.
  func testTheCloneTokenReachesGitOnlyAsAGitHubHeaderInItsEnvironment() throws {
    let environment = RemoteProvisioning.cloneEnvironment(token: "ghs_secret")

    XCTAssertEqual(environment["GIT_CONFIG_COUNT"], "1")
    XCTAssertEqual(environment["GIT_CONFIG_KEY_0"], "http.https://github.com/.extraHeader")
    let value = try XCTUnwrap(environment["GIT_CONFIG_VALUE_0"])
    XCTAssertTrue(value.hasPrefix("Authorization: Basic "))
    let credentials = try XCTUnwrap(
      Data(base64Encoded: String(value.dropFirst("Authorization: Basic ".count))))
    XCTAssertEqual(String(decoding: credentials, as: UTF8.self), "x-access-token:ghs_secret")
    XCTAssertFalse(environment.values.contains { $0.contains("ghs_secret") })
  }
}

/// Which credentials a workroom's clone takes (#309): the agent's own, once it enrols with the
/// broker, or the Mac's own GitHub token through the relay.
final class RemoteProvisioningCredentialsTests: XCTestCase {
  private let repository = "o/r"

  /// Signed out, a grant is left for a later delete with the one thing that cancels it: Codaset,
  /// never GitHub.
  func testASignedOutTeardownSaysOnlyCodasetCancelsTheGrant() async throws {
    do {
      try await RemoteProvisioning.tearDown(
        host: nil, grantID: "g", workroom: nil,
        in: environment(client: false, gitHubToken: nil))
      XCTFail("a grant was cancelled signed out")
    } catch RemoteProvisioning.Failure.rollbackIncomplete(_, _, let grant, let cleanup) {
      XCTAssertEqual(grant, "g")
      XCTAssertEqual(
        cleanup,
        [
          "cancelling grant g: Sign in to Codaset in Settings → Remote workrooms to cancel its grant."
        ])
    }
  }

  /// A connection the sequence reaches and then loses, so the git it runs fails at once.
  private static let lostConnection: @Sendable (HostID) async throws -> AgentVCSConnection = {
    host in
    let fake = try FakeAgent(version: 4)
    defer { fake.stop() }
    return try await AgentVCSConnection.connect(host: host, socketPath: fake.socketPath)
  }

  private func environment(
    client: Bool, gitHubToken: (@Sendable () async throws -> String)?,
    driver: any HostDriver = CountingDriver()
  ) -> RemoteProvisioning.Environment {
    RemoteProvisioning.Environment(
      driver: driver, agentSocket: RemoteWorkrooms.agentSocket,
      client: client
        ? BrokerClient(
          baseURL: URL(string: "https://codaset.localhost")!,
          key: .software(P256.Signing.PrivateKey()), session: BrokerStub.session)
        : nil,
      gitHubToken: gitHubToken,
      agentBroker: .init(url: { client, _, _ in client.baseURL }, release: { _ in }),
      connect: Self.lostConnection)
  }

  private func provision(
    _ environment: RemoteProvisioning.Environment, steps: StepLog = StepLog()
  ) async throws {
    let report: @Sendable (RemoteProvisioning.Step) -> Void = { steps.add($0) }
    try await RemoteProvisioning.$reportStep.withValue(report) {
      _ = try await RemoteProvisioning.provision(
        repository: repository, cloneURL: "u", path: "/p", workroom: UUID(), branch: "b",
        in: environment)
    }
  }

  private static let appNotInstalled = BrokerStub.Answer(
    status: 409, body: #"{"error":"app_not_installed","message":"x"}"#)

  /// Signed out, a workroom needs the Mac's token before its machine, which can take minutes, not
  /// after.
  func testSignedOutWithoutGhMakesNoMachine() async throws {
    let driver = CountingDriver()
    do {
      try await provision(environment(client: false, gitHubToken: nil, driver: driver))
      XCTFail("expected signedOut")
    } catch RemoteWorkrooms.Failure.signedOut {}
    XCTAssertEqual(driver.creates, 0, "a machine was made first")
  }

  // Value: protects=a create's row says it is enrolling, cloning, then checking out, per path taken;
  // fails_when=provision stops reporting a step, or a relayed workroom reports an enrol it skips;
  // why_new=BoxdHostDriverTests stop at the driver's machine/setup steps; nothing reaches these; seam=none
  /// Signed out, the Mac's token clones and nothing enrols. The clone then fails on the lost
  /// connection, and the machine goes with it.
  func testSignedOutAWorkroomIsRelayedAndNeverEnrols() async throws {
    let driver = CountingDriver()
    let steps = StepLog()
    _ = try? await provision(
      environment(client: false, gitHubToken: { "gho_mac" }, driver: driver), steps: steps)
    XCTAssertEqual(steps.take(), [.clone])
    XCTAssertEqual(driver.creates, 1)
    XCTAssertEqual(driver.destroys, 1, "the failed create left its machine")
  }

  /// The repository's owner hasn't installed the Codaset App: the broker refuses the grant before
  /// it makes one, and the Mac's own token clones instead.
  func testAnUninstalledAppFallsBackToTheMacsToken() async throws {
    BrokerStub.reset([Self.appNotInstalled])
    let steps = StepLog()
    _ = try? await provision(
      environment(client: true, gitHubToken: { "gho_mac" }), steps: steps)
    XCTAssertEqual(steps.take(), [.enrol, .clone])
  }

  /// Without `gh` either, the App's install is what the user needs to hear about, and the machine
  /// goes.
  func testAnUninstalledAppWithoutGhIsTheRefusal() async throws {
    BrokerStub.reset([Self.appNotInstalled])
    let driver = CountingDriver()
    let steps = StepLog()
    do {
      try await provision(
        environment(
          client: true, gitHubToken: { throw RemoteWorkrooms.Failure.signedOut }, driver: driver),
        steps: steps)
      XCTFail("expected the refusal")
    } catch BrokerError.refused(let refusal) {
      XCTAssertEqual(refusal.code, "app_not_installed")
    }
    XCTAssertEqual(steps.take(), [.enrol], "it cloned")
    XCTAssertEqual(driver.destroys, 1, "the failed create left its machine")
  }

  /// A remote provider's machine has no Mac token to fall back to (OQ20): the refusal stands.
  func testARemoteHostWithAnUninstalledAppIsTheRefusal() async throws {
    BrokerStub.reset([Self.appNotInstalled])
    do {
      try await provision(environment(client: true, gitHubToken: nil))
      XCTFail("expected the refusal")
    } catch BrokerError.refused(let refusal) {
      XCTAssertEqual(refusal.code, "app_not_installed")
    }
  }
}

extension RemoteProvisioningCredentialsTests {
  /// The fallback to the Mac's token is said to someone signed in, whose workroom relays anyway.
  func testOnlyASignedInWorkroomThatRelaysSaysItFellBack() {
    XCTAssertTrue(AppStore.fellBackToGitHub(signedIn: true, relayed: true))
    XCTAssertFalse(AppStore.fellBackToGitHub(signedIn: false, relayed: true))
    XCTAssertFalse(AppStore.fellBackToGitHub(signedIn: true, relayed: false))
  }
}

/// Makes a host for every create, and counts what it makes and takes down.
private final class CountingDriver: HostDriver, @unchecked Sendable {
  private let lock = NSLock()
  private var made = 0
  private var removed = 0
  var creates: Int { lock.withLock { made } }
  var destroys: Int { lock.withLock { removed } }
  let traits = HostDriverTraits(transport: .sshStdio, durableDisk: false, maxLifetime: nil)

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

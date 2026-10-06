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

  /// One operation at a time on a base, and different bases at once.
  func testOperationsOnOneBaseTakeTurnsAndOnDifferentBasesOverlap() async throws {
    final class Probe: @unchecked Sendable {
      private let lock = NSLock()
      private var running: [UUID: Int] = [:]
      private(set) var most: [UUID: Int] = [:]
      var together = 0
      private var now = 0
      func enter(_ base: UUID) {
        lock.withLock {
          running[base, default: 0] += 1
          most[base] = max(most[base] ?? 0, running[base]!)
          now += 1
          together = max(together, now)
        }
      }
      func leave(_ base: UUID) {
        lock.withLock {
          running[base]! -= 1
          now -= 1
        }
      }
      var peaks: [UUID: Int] { lock.withLock { most } }
      var overlap: Int { lock.withLock { together } }
    }
    let probe = Probe()
    let (first, second) = (UUID(), UUID())
    let locks = BaseLocks()

    try await withThrowingTaskGroup(of: Void.self) { group in
      for base in [first, first, first, second, second, second] {
        group.addTask {
          try await locks.exclusively(on: base) {
            probe.enter(base)
            try await Task.sleep(for: .milliseconds(50))
            probe.leave(base)
          }
        }
      }
      try await group.waitForAll()
    }

    XCTAssertEqual(probe.peaks[first], 1, "two operations on one base overlapped")
    XCTAssertEqual(probe.peaks[second], 1, "two operations on one base overlapped")
    XCTAssertEqual(probe.overlap, 2, "different bases did not run at once")
  }
}

/// Which credentials a base's clone and a workroom's derive take (#309): the broker's clone token,
/// or the Mac's own GitHub token through the relay.
final class RemoteProvisioningCredentialsTests: XCTestCase {
  private let repository = "o/r"

  private func environment(
    client: Bool, gitHubToken: (@Sendable () async throws -> String)?,
    driver: any HostDriver = RefusingDriver(), revoked: Revoked = Revoked()
  ) -> RemoteProvisioning.Environment {
    RemoteProvisioning.Environment(
      driver: driver, agentSocket: RemoteWorkrooms.agentSocket,
      client: client
        ? BrokerClient(
          baseURL: URL(string: "https://codaset.localhost")!,
          key: .software(P256.Signing.PrivateKey()), session: BrokerStub.session)
        : nil,
      gitHubToken: gitHubToken, revoke: { _ in revoked.add() })
  }

  private static let appNotInstalled = BrokerStub.Answer(
    status: 409, body: #"{"error":"app_not_installed","message":"x"}"#)

  func testTheBrokersTokenClonesAndIsRevoked() async throws {
    BrokerStub.reset([.init(body: #"{"token":"ghs_broker","expires_at":"x"}"#)])
    let revoked = Revoked()
    let heard = Heard()
    let relayed = try await RemoteProvisioning.withCloneToken(
      repository, relayed: nil,
      in: environment(client: true, gitHubToken: { "gho_mac" }, revoked: revoked)
    ) { heard.set($0) }
    XCTAssertFalse(relayed)
    XCTAssertEqual(heard.get(), RemoteProvisioning.cloneEnvironment(token: "ghs_broker"))
    XCTAssertEqual(revoked.count, 1)
  }

  /// The repository's owner hasn't installed the Codaset App: the Mac's own token clones, and the
  /// base is relayed. It is the user's, so it is never revoked.
  func testAnUninstalledAppFallsBackToTheMacsToken() async throws {
    BrokerStub.reset([Self.appNotInstalled])
    let revoked = Revoked()
    let heard = Heard()
    let relayed = try await RemoteProvisioning.withCloneToken(
      repository, relayed: nil,
      in: environment(client: true, gitHubToken: { "gho_mac" }, revoked: revoked)
    ) { heard.set($0) }
    XCTAssertTrue(relayed)
    XCTAssertEqual(heard.get(), RemoteProvisioning.cloneEnvironment(token: "gho_mac"))
    XCTAssertEqual(revoked.count, 0)
  }

  /// Without `gh` either, the App's install is what the user needs to hear about.
  func testAnUninstalledAppWithoutGhIsTheRefusal() async throws {
    BrokerStub.reset([Self.appNotInstalled])
    do {
      try await RemoteProvisioning.withCloneToken(
        repository, relayed: nil,
        in: environment(client: true, gitHubToken: { throw RemoteWorkrooms.Failure.signedOut })
      ) { _ in XCTFail("cloned") }
      XCTFail("expected the refusal")
    } catch BrokerError.refused(let refusal) {
      XCTAssertEqual(refusal.code, "app_not_installed")
    }
  }

  /// An existing broker base doesn't fall back: its workrooms enrol.
  func testABrokerBaseKeepsItsRefusal() async throws {
    BrokerStub.reset([Self.appNotInstalled])
    do {
      try await RemoteProvisioning.withCloneToken(
        repository, relayed: false, in: environment(client: true, gitHubToken: { "gho_mac" })
      ) { _ in XCTFail("cloned") }
      XCTFail("expected the refusal")
    } catch BrokerError.refused(let refusal) {
      XCTAssertEqual(refusal.code, "app_not_installed")
    }
  }

  func testSignedOutOfCodasetANewBaseIsRelayed() async throws {
    let heard = Heard()
    let relayed = try await RemoteProvisioning.withCloneToken(
      repository, relayed: nil, in: environment(client: false, gitHubToken: { "gho_mac" })
    ) { heard.set($0) }
    XCTAssertTrue(relayed)
    XCTAssertEqual(heard.get(), RemoteProvisioning.cloneEnvironment(token: "gho_mac"))
  }

  func testSignedOutOfCodasetABrokerBaseIsSignedOut() async throws {
    do {
      try await RemoteProvisioning.withCloneToken(
        repository, relayed: false, in: environment(client: false, gitHubToken: { "gho_mac" })
      ) { _ in XCTFail("cloned") }
      XCTFail("expected signedOut")
    } catch RemoteWorkrooms.Failure.signedOut {}
  }

  /// A workroom of a broker base needs the broker before its base is copied, which can take many
  /// minutes, not after.
  func testSignedOutOfCodasetADeriveFromABrokerBaseCopiesNothing() async throws {
    let driver = RefusingDriver()
    do {
      _ = try await RemoteProvisioning.derive(
        from: .init(host: UUID(), repository: repository, cloneURL: "u", path: "/p"),
        workroom: UUID(), branch: "b",
        in: environment(client: false, gitHubToken: { "gho_mac" }, driver: driver))
      XCTFail("expected signedOut")
    } catch RemoteWorkrooms.Failure.signedOut {}
    XCTAssertEqual(driver.derives, 0, "the base was copied first")
  }

  /// A relayed base's workroom needs the Mac's token, also before the copy.
  func testWithoutGhADeriveFromARelayedBaseCopiesNothing() async throws {
    let driver = RefusingDriver()
    do {
      _ = try await RemoteProvisioning.derive(
        from: .init(host: UUID(), repository: repository, cloneURL: "u", path: "/p", relayed: true),
        workroom: UUID(), branch: "b",
        in: environment(
          client: true, gitHubToken: { throw RemoteWorkrooms.Failure.signedOut }, driver: driver))
      XCTFail("expected signedOut")
    } catch RemoteWorkrooms.Failure.signedOut {}
    XCTAssertEqual(driver.derives, 0, "the base was copied first")
  }

  // Value: protects=a boxd create's row says it is cloning, then enrolling, then checking out, per path taken;
  // fails_when=buildBase or derive stops reporting its step, or a relayed workroom reports an enrol it skips;
  // why_new=BoxdHostDriverTests stop at the driver's machine/setup steps; nothing reaches these three; seam=none
  /// The steps a create's project row shows come from the sequence itself (#356): a base is
  /// cloned, a broker workroom enrols and then checks out, and a relayed one only checks out.
  func testTheSequenceReportsItsCloneEnrolAndCheckoutSteps() async throws {
    BrokerStub.reset([])
    // A connection the sequence reaches and then loses, so the git it runs fails at once.
    let connect: @Sendable (HostID) async throws -> AgentVCSConnection = { host in
      let fake = try FakeAgent(version: 4, status: true)
      defer { fake.stop() }
      return try await AgentVCSConnection.connect(host: host, socketPath: fake.socketPath)
    }
    let steps = StepLog()
    let report: @Sendable (RemoteProvisioning.Step) -> Void = { steps.add($0) }
    let repository = repository
    func environment(client: Bool) -> RemoteProvisioning.Environment {
      RemoteProvisioning.Environment(
        driver: MakingDriver(), agentSocket: RemoteWorkrooms.agentSocket,
        client: client
          ? BrokerClient(
            baseURL: URL(string: "https://codaset.localhost")!,
            key: .software(P256.Signing.PrivateKey()), session: BrokerStub.session)
          : nil,
        gitHubToken: { "gho_mac" }, connect: connect, revoke: { _ in })
    }
    func base(relayed: Bool) -> RemoteProvisioning.Base {
      .init(host: UUID(), repository: repository, cloneURL: "u", path: "/p", relayed: relayed)
    }

    await RemoteProvisioning.$reportStep.withValue(report) {
      _ = try? await RemoteProvisioning.buildBase(
        repository: repository, cloneURL: "u", path: "/p", in: environment(client: false),
        record: { _ in })
    }
    XCTAssertEqual(steps.take(), [.clone])

    await RemoteProvisioning.$reportStep.withValue(report) {
      _ = try? await RemoteProvisioning.derive(
        from: base(relayed: false), workroom: UUID(), branch: "b", in: environment(client: true))
    }
    XCTAssertEqual(steps.take(), [.enrol])

    await RemoteProvisioning.$reportStep.withValue(report) {
      _ = try? await RemoteProvisioning.derive(
        from: base(relayed: true), workroom: UUID(), branch: "b", in: environment(client: true))
    }
    XCTAssertEqual(steps.take(), [.checkout])
  }
}

extension RemoteProvisioningCredentialsTests {
  /// The fallback to the Mac's token is said once, to someone signed in, when the base is made.
  func testOnlyASignedInFirstBaseThatRelaysSaysItFellBack() {
    let relayed = HostDescriptor(id: UUID(), credentials: "relay")
    let broker = HostDescriptor(id: UUID())
    XCTAssertTrue(AppStore.fellBackToGitHub(signedIn: true, hadBase: false, made: relayed))
    XCTAssertFalse(AppStore.fellBackToGitHub(signedIn: false, hadBase: false, made: relayed))
    XCTAssertFalse(AppStore.fellBackToGitHub(signedIn: true, hadBase: true, made: relayed))
    XCTAssertFalse(AppStore.fellBackToGitHub(signedIn: true, hadBase: false, made: broker))
    XCTAssertFalse(AppStore.fellBackToGitHub(signedIn: true, hadBase: false, made: nil))
  }
}

private final class Revoked: @unchecked Sendable {
  private let lock = NSLock()
  private var revokes = 0
  func add() { lock.withLock { revokes += 1 } }
  var count: Int { lock.withLock { revokes } }
}

private final class Heard: @unchecked Sendable {
  private let lock = NSLock()
  private var environment: [String: String]?
  func set(_ environment: [String: String]) { lock.withLock { self.environment = environment } }
  func get() -> [String: String]? { lock.withLock { environment } }
}

/// Counts derives, and refuses everything.
private final class RefusingDriver: HostDriver, @unchecked Sendable {
  private let lock = NSLock()
  private var derived = 0
  var derives: Int { lock.withLock { derived } }
  let traits = HostDriverTraits(
    transport: .sshStdio, deriveSpeed: nil, deriveCarriesLiveProcesses: false,
    durableDisk: false, maxLifetime: nil, keepAwakeHoldsCredential: false,
    sleepsWhenIdle: false)

  func create() async throws -> HostID { throw HostDriverError.notImplemented("create") }
  func deriveFromBase(_ base: HostID) async throws -> HostID {
    lock.withLock { derived += 1 }
    throw HostDriverError.notImplemented("derive")
  }
  func destroy(_ host: HostID) async throws { throw HostDriverError.notImplemented("destroy") }
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

/// Makes a host for every create and derive, and takes it down again.
private struct MakingDriver: HostDriver {
  let traits = HostDriverTraits(
    transport: .sshStdio, deriveSpeed: nil, deriveCarriesLiveProcesses: false,
    durableDisk: false, maxLifetime: nil, keepAwakeHoldsCredential: false,
    sleepsWhenIdle: false)

  func create() async throws -> HostID { .remote(UUID()) }
  func deriveFromBase(_ base: HostID) async throws -> HostID { .remote(UUID()) }
  func destroy(_ host: HostID) async throws {}
  func openStream(to host: HostID) async throws -> HostStream {
    throw HostDriverError.notImplemented("openStream")
  }
  func exec(_ command: String, on host: HostID) async throws -> HostStream {
    throw HostDriverError.notImplemented("exec")
  }
}

import CryptoKit
import XCTest

@testable import Workroom

/// The loopback + PKCE sign-in end to end: a real listener on 127.0.0.1, the "browser" played by
/// the test, the broker by `BrokerStub`.
final class BrokerSignInTests: XCTestCase {
  private let base = URL(string: "https://codaset.localhost")!
  private var directory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "broker-sign-in-\(UUID().uuidString.prefix(8))")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func credentials() -> BrokerCredentials {
    final class Box: @unchecked Sendable { var data: Data? }
    let box = Box()
    return BrokerCredentials(
      directory: directory,
      secrets: .init(read: { box.data }, write: { box.data = $0 }, delete: { box.data = nil }))
  }

  /// Refuses redirects, so the test sees the listener's 302 rather than following it to Codaset.
  private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? { nil }
  }

  /// What the browser saw: the sign-in URL it was opened on, and where the loopback sent it.
  private final class Browser: @unchecked Sendable {
    let lock = NSLock()
    var opened: URL?
    var redirectedTo: String?
    let done = XCTestExpectation(description: "the browser was answered")
    /// Connections opened and left idle ahead of the redirect, as a local process could.
    var idleAhead = 0

    /// Plays Codaset's redirect back to the loopback, after a stray favicon request.
    func open(_ url: URL, code: String, attempt: String) {
      lock.withLock { opened = url }
      let port =
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "port" }?.value ?? ""
      let session = URLSession(
        configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
      let idle = (0..<idleAhead).compactMap { _ in
        LoopbackSocket.connect(port: UInt16(port) ?? 0, timeout: 2)
      }
      Task {
        defer { for socket in idle { Darwin.close(socket) } }
        _ = try? await session.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        let callback = URL(
          string: "http://127.0.0.1:\(port)/callback?code=\(code)&attempt=\(attempt)")!
        if let (_, response) = try? await session.data(from: callback) {
          let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location")
          lock.withLock { redirectedTo = location }
        }
        done.fulfill()
      }
    }
  }

  private func signIn(_ browser: Browser, code: String = "the-code", attempt: String = "att-1")
    -> BrokerSignIn
  {
    BrokerSignIn(
      baseURL: base, credentials: credentials(),
      openBrowser: { browser.open($0, code: code, attempt: attempt) },
      session: BrokerStub.session, makeKey: { .software(P256.Signing.PrivateKey()) }, timeout: 20)
  }

  func testASuccessfulSignInRedeemsWithPKCEStoresTheKeyAndCompletesBeforeAnswering() async throws {
    BrokerStub.reset([
      .init(status: 201, body: #"{"device_id":"dev-1","login":"octo","email":"o@example.com"}"#),
      .init(body: #"{"state":"completed"}"#),
    ])
    let browser = Browser()
    let flow = signIn(browser)

    let account = try await flow.run(deviceName: "Joel's Mac")
    await fulfillment(of: [browser.done], timeout: 10)

    XCTAssertEqual(account, BrokerAccount(deviceID: "dev-1", login: "octo", email: "o@example.com"))
    let opened = try XCTUnwrap(browser.opened)
    let items = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let item = { (name: String) in items.first { $0.name == name }?.value }
    XCTAssertEqual(opened.path, "/workroom/sign-in")
    XCTAssertEqual(item("flow"), "mac")
    XCTAssertEqual(item("device_name"), "Joel's Mac")

    let requests = BrokerStub.requests
    XCTAssertEqual(
      requests.map { $0.request.url?.path },
      [
        "/broker/devices", "/broker/sign-in-attempts/att-1/complete",
      ])
    let verifier = try XCTUnwrap(requests[0].json["code_verifier"] as? String)
    XCTAssertEqual(requests[0].json["code"] as? String, "the-code")
    XCTAssertEqual(
      Data(SHA256.hash(data: Data(verifier.utf8))).base64URL, item("code_challenge"),
      "the verifier matches the challenge the browser carried")
    XCTAssertTrue(proofVerifies(requests[0].proof))
    XCTAssertEqual(
      jwtPart(requests[0].proof, 0)["jwk"] as? [String: String],
      jwtPart(requests[1].proof, 0)["jwk"] as? [String: String],
      "complete is signed with the key the redemption registered")

    XCTAssertEqual(browser.redirectedTo, "https://codaset.localhost/workroom/sign-in/att-1")
    XCTAssertEqual(flow.credentials.load()?.account, account)
  }

  /// Idle connections queued ahead of the browser's don't hold the redirect back. Read one at a
  /// time, each cost up to 5 s, so the 128 the accept queue holds outlasted the whole sign-in; here
  /// 8 of them outlast its 20 s.
  func testIdleConnectionsAheadOfTheRedirectDoNotHoldItBack() async throws {
    BrokerStub.reset([
      .init(status: 201, body: #"{"device_id":"d","login":"l","email":"e"}"#),
      .init(body: #"{"state":"completed"}"#),
    ])
    let browser = Browser()
    browser.idleAhead = 8
    let flow = signIn(browser)
    let started = ContinuousClock.now

    _ = try await flow.run(deviceName: "Mac")
    await fulfillment(of: [browser.done], timeout: 10)

    XCTAssertLessThan(ContinuousClock.now - started, .seconds(4))
    XCTAssertEqual(browser.redirectedTo, "https://codaset.localhost/workroom/sign-in/att-1")
  }

  /// More idle connections ahead of the redirect than the listener reads at once
  /// (`LoopbackListener.maxPending`) don't crowd it out: the oldest are dropped, not the browser's.
  func testAFloodLargerThanTheReadingCapAheadOfTheRedirectDoesNotCrowdItOut() async throws {
    BrokerStub.reset([
      .init(status: 201, body: #"{"device_id":"d","login":"l","email":"e"}"#),
      .init(body: #"{"state":"completed"}"#),
    ])
    let browser = Browser()
    browser.idleAhead = LoopbackListener.maxPending + 8
    let flow = signIn(browser)
    let started = ContinuousClock.now

    _ = try await flow.run(deviceName: "Mac")
    await fulfillment(of: [browser.done], timeout: 10)

    XCTAssertLessThan(ContinuousClock.now - started, .seconds(4))
    XCTAssertEqual(browser.redirectedTo, "https://codaset.localhost/workroom/sign-in/att-1")
  }

  /// An accept on the sign-in listener with nothing queued returns at once: the case of a `poll`
  /// that saw a connection which is gone by the `accept`. Blocking there would hold the loop that
  /// reads every waiting connection and watches the deadline.
  func testAnAcceptWithNothingQueuedReturnsAtOnce() throws {
    let listener = try LoopbackListener()
    defer { listener.close() }
    let descriptor = try XCTUnwrap(Self.listeningDescriptor(port: listener.port))
    final class Outcome: @unchecked Sendable {
      var accepted: Int32 = 0
      var error: Int32 = 0
    }
    let outcome = Outcome()
    let returned = DispatchSemaphore(value: 0)
    let thread = Thread {
      outcome.accepted = accept(descriptor, nil, nil)
      outcome.error = errno
      returned.signal()
    }
    // The test's own class, so waiting on it is no priority inversion.
    thread.qualityOfService = .userInteractive
    thread.start()
    guard returned.wait(timeout: .now() + 1) == .success else {
      // Blocked. A connection lets it go, so the listener is not closed under a blocked accept.
      let socket = LoopbackSocket.connect(port: listener.port, timeout: 2)
      if returned.wait(timeout: .now() + 2) == .success { Darwin.close(outcome.accepted) }
      if let socket { Darwin.close(socket) }
      return XCTFail("accept blocked with nothing queued")
    }
    XCTAssertEqual(outcome.accepted, -1)
    XCTAssertEqual(outcome.error, EWOULDBLOCK)
  }

  /// The descriptor in this process listening on `port`, found as `lsof` would: the listener keeps
  /// its own private. A socket bound to that port with no peer is the listener (macOS has no
  /// `SO_ACCEPTCONN` to ask).
  private static func listeningDescriptor(port: UInt16) -> Int32? {
    for descriptor in Int32(0)..<Int32(getdtablesize()) {
      var address = sockaddr_in()
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          getsockname(descriptor, $0, &length)
        }
      }
      guard named == 0, address.sin_family == sa_family_t(AF_INET),
        UInt16(bigEndian: address.sin_port) == port
      else { continue }
      var peer = sockaddr_in()
      var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
      let connected = withUnsafeMutablePointer(to: &peer) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          getpeername(descriptor, $0, &peerLength)
        }
      }
      if connected != 0, errno == ENOTCONN { return descriptor }
    }
    return nil
  }

  func testAFailedRedemptionStillSendsTheBrowserToTheResultPageAndStoresNothing() async throws {
    BrokerStub.reset([
      .init(
        status: 401,
        body: #"{"error":"invalid_code","message":"The sign-in code is unknown, used or expired"}"#)
    ])
    let browser = Browser()
    let flow = signIn(browser)

    do {
      _ = try await flow.run(deviceName: "Mac")
      XCTFail("expected a refusal")
    } catch BrokerError.refused(let refusal) {
      XCTAssertEqual(refusal.code, "invalid_code")
    }
    await fulfillment(of: [browser.done], timeout: 10)

    XCTAssertEqual(browser.redirectedTo, "https://codaset.localhost/workroom/sign-in/att-1")
    XCTAssertNil(flow.credentials.load())
  }

  func testARefusedCompleteForgetsTheKeySoTheMacAgreesWithThePage() async throws {
    BrokerStub.reset([
      .init(status: 201, body: #"{"device_id":"d","login":"l","email":"e"}"#),
      .init(status: 404, body: #"{"error":"not_found","message":"Unknown sign-in attempt"}"#),
    ])
    let browser = Browser()
    let flow = signIn(browser)

    do {
      _ = try await flow.run(deviceName: "Mac")
      XCTFail("expected a failure")
    } catch BrokerError.refused(let refusal) {
      XCTAssertEqual(refusal.code, "not_found")
    }
    await fulfillment(of: [browser.done], timeout: 10)

    XCTAssertEqual(browser.redirectedTo, "https://codaset.localhost/workroom/sign-in/att-1")
    XCTAssertNil(flow.credentials.load())
  }

  /// A "complete" whose answer is lost may still have completed the attempt, and the key works
  /// either way, so the Mac stays signed in rather than contradicting a page that says so.
  func testALostCompleteAnswerKeepsTheKey() async throws {
    BrokerStub.reset([.init(status: 201, body: #"{"device_id":"d","login":"l","email":"e"}"#)])
    BrokerStub.failNext = true
    let browser = Browser()
    let flow = signIn(browser)

    let account = try await flow.run(deviceName: "Mac")
    await fulfillment(of: [browser.done], timeout: 10)

    XCTAssertEqual(flow.credentials.load()?.account, account)
  }

  /// Cancel pressed while "complete" is in flight: not signed in, whatever the broker recorded.
  func testCancellingDuringCompleteLeavesTheMacSignedOut() async throws {
    BrokerStub.reset([.init(status: 201, body: #"{"device_id":"d","login":"l","email":"e"}"#)])
    BrokerStub.hangWhenEmpty = true
    let browser = Browser()
    let flow = signIn(browser)
    let task = Task { try await flow.run(deviceName: "Mac") }
    while BrokerStub.requests.count < 2 { try await Task.sleep(for: .milliseconds(20)) }

    task.cancel()
    let result = await task.result
    await fulfillment(of: [browser.done], timeout: 10)

    XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
    XCTAssertNil(flow.credentials.load())
  }

  func testCancellingTheSignInStopsWaitingForTheBrowser() async throws {
    let flow = BrokerSignIn(
      baseURL: base, credentials: credentials(), openBrowser: { _ in },
      session: BrokerStub.session, timeout: 60)
    let task = Task { try await flow.run(deviceName: "Mac") }
    try await Task.sleep(for: .milliseconds(200))
    let started = ContinuousClock.now

    task.cancel()
    let result = await task.result

    XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    XCTAssertThrowsError(try result.get())
  }

  /// This test host is a Debug build: a sign-in against production never opens the browser.
  func testADebugSignInNeverOpensProduction() async throws {
    final class Opened: @unchecked Sendable { var url: URL? }
    let opened = Opened()
    let flow = BrokerSignIn(
      baseURL: BrokerEndpoint.production, credentials: credentials(),
      openBrowser: { opened.url = $0 }, session: BrokerStub.session, timeout: 5)

    do {
      _ = try await flow.run(deviceName: "Mac")
      XCTFail("expected the sign-in to be refused")
    } catch BrokerError.transport(let detail) {
      XCTAssertTrue(detail.contains("https://codaset.dev"), detail)
    }
    XCTAssertNil(opened.url)
  }
}

final class AgentEnrolmentTests: XCTestCase {
  /// Runs every exec as a shell script that saves its stdin and answers as told.
  private final class StubDriver: HostDriver, @unchecked Sendable {
    let traits = HostDriverTraits(
      transport: .sshStdio, deriveSpeed: nil, deriveCarriesLiveProcesses: false,
      durableDisk: false, maxLifetime: nil)
    let stdinFile: URL
    let output: String
    let status: Int32
    /// Seconds the command runs before answering.
    let delay: Int
    private(set) var commands: [String] = []

    init(stdinFile: URL, output: String, status: Int32, delay: Int = 0) {
      self.stdinFile = stdinFile
      self.output = output
      self.status = status
      self.delay = delay
    }

    func create() async throws -> HostID { throw HostDriverError.notImplemented("create") }
    func deriveFromBase(_ base: HostID) async throws -> HostID {
      throw HostDriverError.notImplemented("derive")
    }
    func destroy(_ host: HostID) async throws { throw HostDriverError.notImplemented("destroy") }
    func openStream(to host: HostID) async throws -> HostStream {
      throw HostDriverError.notImplemented("openStream")
    }

    func exec(_ command: String, on host: HostID) async throws -> HostStream {
      commands.append(command)
      return try HostStream.spawn(
        URL(fileURLWithPath: "/bin/sh"),
        [
          "-c", "cat > \"$1\"; sleep \"$4\"; printf '%s' \"$2\" >&2; exit \"$3\"", "stub",
          stdinFile.path, output, String(status), String(delay),
        ],
        environment: [:], handshakeTimeout: 5, purpose: .exchange)
    }
  }

  /// The agent's broker route, recorded: what URL it was given and whether it was let go.
  private final class RecordingBroker: @unchecked Sendable {
    let url: URL
    let fails: Bool
    private let lock = NSLock()
    private var releasedFor: [UUID] = []
    init(url: URL = URL(string: "http://127.0.0.1:47001")!, fails: Bool = false) {
      self.url = url
      self.fails = fails
    }
    var released: [UUID] { lock.withLock { releasedFor } }
    var seam: AgentEnrolment.AgentBroker {
      AgentEnrolment.AgentBroker(
        url: { [self] _, _, _ in
          if fails { throw BrokerError.agent("no route to the broker") }
          return url
        },
        release: { [self] workroom in lock.withLock { releasedFor.append(workroom) } })
    }
  }

  private var broker = RecordingBroker()

  private let grant = BrokerStub.Answer(
    status: 201,
    body: #"{"grant_id":"g1","enrolment_code":"one-time","repository_id":1,"expires_at":"x"}"#)

  private func client() -> BrokerClient {
    BrokerClient(
      baseURL: URL(string: "https://codaset.localhost")!, key: .software(P256.Signing.PrivateKey()),
      session: BrokerStub.session)
  }

  private func stdinFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("enrol-\(UUID().uuidString)")
  }

  func testTheCodeGoesToTheAgentOnStdinNotInItsArguments() async throws {
    BrokerStub.reset([grant])
    let file = stdinFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let driver = StubDriver(stdinFile: file, output: "", status: 0)
    let workroom = UUID()

    let grantID = try await AgentEnrolment.enrol(
      client: client(), driver: driver, host: .remote(UUID()),
      agentBinary: "/run/workroom/wr-agent", workroomID: workroom, repository: "o/r",
      agentBroker: broker.seam)

    XCTAssertEqual(grantID, "g1")
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "one-time\n")
    let command = try XCTUnwrap(driver.commands.first)
    XCTAssertEqual(
      command,
      "'/run/workroom/wr-agent' enrol --workroom '\(workroom.uuidString.lowercased())' "
        + "--broker 'http://127.0.0.1:47001'")
    XCTAssertFalse(command.contains("one-time"))
  }

  func testAFailedEnrolmentReportsTheRefusalAndCancelsTheGrant() async throws {
    BrokerStub.reset([grant, .init(body: #"{"grant_id":"g1","state":"cancelled"}"#)])
    let file = stdinFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let driver = StubDriver(
      stdinFile: file,
      output: "error: The enrolment code has expired (invalid_code)\nrefusal: invalid_code\n",
      status: 1)

    do {
      _ = try await AgentEnrolment.enrol(
        client: client(), driver: driver, host: .remote(UUID()), agentBinary: "wr-agent",
        workroomID: UUID(), repository: "o/r", agentBroker: broker.seam)
      XCTFail("expected a refusal")
    } catch let error as BrokerError {
      guard case .agentRefused(let refusal) = error else { return XCTFail("\(error)") }
      XCTAssertEqual(refusal.code, "invalid_code")
      XCTAssertEqual(
        error.errorDescription, "The enrolment code has expired (invalid_code)",
        "the broker's own reason, not the sign-in wording")
    }
    let last = try XCTUnwrap(BrokerStub.requests.last)
    XCTAssertEqual(last.request.httpMethod, "DELETE")
    XCTAssertEqual(last.request.url?.path, "/broker/grants/g1")
  }

  func testAnAgentErrorWithoutARefusalIsTheAgentsAndStillCancelsTheGrant() async throws {
    BrokerStub.reset([grant, .init(body: #"{"grant_id":"g1","state":"cancelled"}"#)])
    let file = stdinFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let driver = StubDriver(stdinFile: file, output: "error: git config failed\n", status: 1)

    do {
      _ = try await AgentEnrolment.enrol(
        client: client(), driver: driver, host: .remote(UUID()), agentBinary: "wr-agent",
        workroomID: UUID(), repository: "o/r", agentBroker: broker.seam)
      XCTFail("expected a failure")
    } catch BrokerError.agent(let detail) {
      XCTAssertTrue(detail.contains("git config failed"), detail)
    }
    XCTAssertEqual(BrokerStub.requests.last?.request.httpMethod, "DELETE")
  }

  /// A failed enrolment whose grant cannot be cancelled either names that grant, so the caller
  /// can record it rather than lose it.
  func testAFailedEnrolmentWhoseCancelFailsNamesTheLiveGrant() async throws {
    BrokerStub.reset([grant, .init(status: 503, body: #"{"error":"github_unavailable"}"#)])
    let file = stdinFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let driver = StubDriver(stdinFile: file, output: "error: git config failed\n", status: 1)

    do {
      _ = try await AgentEnrolment.enrol(
        client: client(), driver: driver, host: .remote(UUID()), agentBinary: "wr-agent",
        workroomID: UUID(), repository: "o/r", agentBroker: broker.seam)
      XCTFail("expected a failure")
    } catch let live as AgentEnrolment.GrantStillLive {
      XCTAssertEqual(live.grantID, "g1")
      guard case BrokerError.agent(let detail) = live.cause else { return XCTFail("\(live.cause)") }
      XCTAssertTrue(detail.contains("git config failed"), detail)
    }
  }

  /// A cancelled enrolment still cancels its grant: the agent may have enrolled already.
  func testACancelledEnrolmentStillCancelsItsGrant() async throws {
    BrokerStub.reset([grant, .init(body: #"{"grant_id":"g1","state":"cancelled"}"#)])
    let file = stdinFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let driver = StubDriver(stdinFile: file, output: "", status: 0, delay: 30)
    let client = client()
    let task = Task {
      try await AgentEnrolment.enrol(
        client: client, driver: driver, host: .remote(UUID()), agentBinary: "wr-agent",
        workroomID: UUID(), repository: "o/r", agentBroker: broker.seam)
    }
    try await Task.sleep(for: .milliseconds(500))

    task.cancel()
    _ = await task.result

    XCTAssertEqual(BrokerStub.requests.last?.request.httpMethod, "DELETE")
    XCTAssertEqual(BrokerStub.requests.last?.request.url?.path, "/broker/grants/g1")
  }

  /// The agent's route to the broker (a reverse forward in a Debug build) goes with the grant.
  func testAFailedEnrolmentLetsGoOfTheAgentsBrokerRoute() async throws {
    BrokerStub.reset([grant, .init(body: #"{"grant_id":"g1","state":"cancelled"}"#)])
    let file = stdinFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let driver = StubDriver(stdinFile: file, output: "error: no\n", status: 1)
    let workroom = UUID()

    _ = try? await AgentEnrolment.enrol(
      client: client(), driver: driver, host: .remote(UUID()), agentBinary: "wr-agent",
      workroomID: workroom, repository: "o/r", agentBroker: broker.seam)

    XCTAssertEqual(broker.released, [workroom])
  }

  func testARefusedGrantLetsGoOfTheRouteAndRunsNothing() async throws {
    BrokerStub.reset([.init(status: 403, body: #"{"error":"no_push_access"}"#)])
    let file = stdinFile()
    let driver = StubDriver(stdinFile: file, output: "", status: 0)
    let workroom = UUID()

    _ = try? await AgentEnrolment.enrol(
      client: client(), driver: driver, host: .remote(UUID()), agentBinary: "wr-agent",
      workroomID: workroom, repository: "o/r", agentBroker: broker.seam)

    XCTAssertEqual(broker.released, [workroom])
    XCTAssertTrue(driver.commands.isEmpty)
  }

  /// An agent that could never reach the broker must not cost a grant.
  func testNoRouteToTheBrokerAsksForNoGrant() async throws {
    BrokerStub.reset([grant])
    broker = RecordingBroker(fails: true)
    let driver = StubDriver(stdinFile: stdinFile(), output: "", status: 0)

    do {
      _ = try await AgentEnrolment.enrol(
        client: client(), driver: driver, host: .remote(UUID()), agentBinary: "wr-agent",
        workroomID: UUID(), repository: "o/r", agentBroker: broker.seam)
      XCTFail("expected the route to fail the enrolment")
    } catch BrokerError.agent(let detail) {
      XCTAssertEqual(detail, "no route to the broker")
    }
    XCTAssertTrue(BrokerStub.requests.isEmpty, "no grant was asked for")
    XCTAssertTrue(driver.commands.isEmpty)
    XCTAssertEqual(broker.released.count, 1, "the half-made route is let go")
  }
}

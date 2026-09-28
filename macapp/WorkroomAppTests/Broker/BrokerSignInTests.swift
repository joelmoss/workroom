import CryptoKit
import XCTest

@testable import Workroom

/// The loopback + PKCE sign-in end to end: a real listener on 127.0.0.1, the "browser" played by
/// the test, the broker by `BrokerStub`.
final class BrokerSignInTests: XCTestCase {
  private let base = URL(string: "https://codaset.test")!
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

    /// Plays Codaset's redirect back to the loopback, after a stray favicon request.
    func open(_ url: URL, code: String, attempt: String) {
      lock.withLock { opened = url }
      let port =
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "port" }?.value ?? ""
      let session = URLSession(
        configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
      Task {
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

    XCTAssertEqual(browser.redirectedTo, "https://codaset.test/workroom/sign-in/att-1")
    XCTAssertEqual(flow.credentials.load()?.account, account)
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

    XCTAssertEqual(browser.redirectedTo, "https://codaset.test/workroom/sign-in/att-1")
    XCTAssertNil(flow.credentials.load())
  }

  func testAFailedCompleteForgetsTheKeySoTheMacAgreesWithThePage() async throws {
    BrokerStub.reset([
      .init(status: 201, body: #"{"device_id":"d","login":"l","email":"e"}"#),
      .init(status: 503, body: #"{"error":"replay_store_unavailable"}"#),
    ])
    let browser = Browser()
    let flow = signIn(browser)

    do {
      _ = try await flow.run(deviceName: "Mac")
      XCTFail("expected a failure")
    } catch BrokerError.refused(let refusal) {
      XCTAssertEqual(refusal.status, 503)
    }
    await fulfillment(of: [browser.done], timeout: 10)

    XCTAssertEqual(browser.redirectedTo, "https://codaset.test/workroom/sign-in/att-1")
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
    private(set) var commands: [String] = []

    init(stdinFile: URL, output: String, status: Int32) {
      self.stdinFile = stdinFile
      self.output = output
      self.status = status
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
          "-c", "cat > \"$1\"; printf '%s' \"$2\" >&2; exit \"$3\"", "stub", stdinFile.path, output,
          String(status),
        ],
        environment: [:], handshakeTimeout: 5)
    }
  }

  private let grant = BrokerStub.Answer(
    status: 201,
    body: #"{"grant_id":"g1","enrolment_code":"one-time","repository_id":1,"expires_at":"x"}"#)

  private func client() -> BrokerClient {
    BrokerClient(
      baseURL: URL(string: "https://codaset.test")!, key: .software(P256.Signing.PrivateKey()),
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
      agentBinary: "/run/workroom/wr-agent", workroomID: workroom, repository: "o/r")

    XCTAssertEqual(grantID, "g1")
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "one-time\n")
    let command = try XCTUnwrap(driver.commands.first)
    XCTAssertEqual(
      command,
      "'/run/workroom/wr-agent' enrol --workroom '\(workroom.uuidString.lowercased())' "
        + "--broker 'https://codaset.test'")
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
        workroomID: UUID(), repository: "o/r")
      XCTFail("expected a refusal")
    } catch BrokerError.refused(let refusal) {
      XCTAssertEqual(refusal.code, "invalid_code")
    }
    let last = try XCTUnwrap(BrokerStub.requests.last)
    XCTAssertEqual(last.request.httpMethod, "DELETE")
    XCTAssertEqual(last.request.url?.path, "/broker/grants/g1")
  }
}

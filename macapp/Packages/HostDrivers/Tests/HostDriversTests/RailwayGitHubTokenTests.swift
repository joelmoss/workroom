import Foundation
import Synchronization
import WorkroomDomain
import WorkroomSystem
import XCTest

@testable import HostDrivers

/// A Railway host's git with the user's `gh` token (ADR 0072, #631): written over stdin at create,
/// answered by a credential helper with every GitHub remote form rewritten to https, and rewritten
/// on a connect when the Mac's token changed. Railway is stubbed at HTTP (`StubRailway`) and ssh
/// through the command runner (`StubRelay`); the token is always a fake.
final class RailwayGitHubTokenTests: XCTestCase {
  typealias StubRelay = RailwayHostDriverTests.StubRelay

  /// Not a real token: no test reads the Mac's `gh`.
  static let token = "gho_FAKE_test_token_0631"

  /// The Mac's `gh` token, which a test can change or sign out.
  private final class MacToken: Sendable {
    private let value: Mutex<String?>
    init(_ value: String? = RailwayGitHubTokenTests.token) { self.value = Mutex(value) }
    func set(_ token: String?) { value.withLock { $0 = token } }
    @Sendable func read() async throws -> String {
      guard let token = value.withLock({ $0 }) else {
        throw HostDriverError.provisioning("gh has no GitHub sign-in on this Mac")
      }
      return token
    }
  }

  private final class Tokens: RailwayAccessTokenProviding, Sendable {
    func accessToken() async throws -> String { "at-1" }
    func accessTokenRejected(_ token: String) async {}
  }

  private var root: URL!

  override func setUp() {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-railway-gh-\(UUID().uuidString)")
    let root = root!
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
  }

  private func railway() -> StubRailway {
    let railway = StubRailway()
    railway.answer("sshPublicKeys", data: ["sshPublicKeys": ["edges": []]])
    railway.answer("sshPublicKeyCreate", data: ["sshPublicKeyCreate": ["id": "key-1"]])
    railway.answer(
      "sandboxCreate", data: ["sandboxCreate": ["id": "sbx-1", "status": "CREATING"]])
    railway.answer("sandbox", data: ["sandbox": ["id": "sbx-1", "status": "RUNNING"]])
    railway.answer(
      "sandboxDestroy", data: ["sandboxDestroy": ["id": "sbx-1", "status": "DESTROYING"]])
    return railway
  }

  private func driver(
    _ railway: StubRailway, _ relay: StubRelay, token: MacToken = MacToken()
  ) -> RailwayHostDriver {
    RailwayHostDriver(
      configuration: .init(
        environmentID: "env-1", projectID: "prj-1", keys: root.appendingPathComponent("railway"),
        relayHost: RailwayHostDriverTests.relayHost, hostSetup: .checkout,
        pollInterval: .milliseconds(1), gitHubToken: token.read),
      api: RailwayAPI(transport: railway, tokens: Tokens()),
      directory: root.appendingPathComponent("hosts"), runner: relay)
  }

  /// The ssh logins that carried the token: their stdin is it.
  private func tokenLogins(_ relay: StubRelay) -> [StubRelay.Call] {
    relay.calls(to: "ssh").filter {
      $0.stdin.map { String(decoding: $0, as: UTF8.self) } == Self.token
    }
  }

  private func assertTokenOnlyOnStdin(
    _ relay: StubRelay, _ railway: StubRailway, file: StaticString = #filePath, line: UInt = #line
  ) {
    for call in relay.calls {
      XCTAssertFalse(
        call.args.joined(separator: " ").contains(Self.token), "the token was in argv",
        file: file, line: line)
    }
    for request in railway.requests {
      let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
      XCTAssertFalse(
        body.contains(Self.token), "the token was sent to Railway", file: file, line: line)
    }
  }

  // MARK: Create

  /// Value: protects=a Railway host pushes in the user's name, and the token never sits in
  /// Railway's variable store or a process list (ADR 0072); fails_when=the token goes in argv, in
  /// a sandbox variable or any GraphQL call, or isn't written at create;
  /// seam=ProvisioningHostDriver.create over StubRailway and the runner
  func testACreateWritesTheMacsTokenToTheHostOverStdin() async throws {
    let railway = railway()
    let relay = StubRelay()
    _ = try await driver(railway, relay).create()

    let login = try XCTUnwrap(tokenLogins(relay).first, "no login carried the token")
    let command = try XCTUnwrap(login.args.last)
    XCTAssertTrue(command.contains(RailwayHostDriver.gitHubTokenPath), command)
    XCTAssertEqual(tokenLogins(relay).count, 1)
    assertTokenOnlyOnStdin(relay, railway)
  }

  /// Value: protects=a Mac signed out of gh bills no sandbox it would have to destroy;
  /// fails_when=the token is read after the sandbox is made; seam=create over StubRailway
  func testACreateOnAMacSignedOutOfGHFailsBeforeASandboxIsMade() async throws {
    let railway = railway()
    do {
      _ = try await driver(railway, StubRelay(), token: MacToken(nil)).create()
      XCTFail("a create went on without a gh token")
    } catch HostDriverError.provisioning(let detail) {
      XCTAssertTrue(detail.contains("gh"), detail)
    }
    XCTAssertFalse(
      railway.graphQLRequests.map(StubRailway.graphQLBody).contains {
        ($0["query"] as? String)?.contains("sandboxCreate") == true
      }, "a sandbox was made")
  }

  // MARK: Connect

  /// Value: protects=a token the user rotated or revoked doesn't live on in a host (ADR 0072);
  /// fails_when=a connect doesn't carry the Mac's current token to the host, puts it in argv, or a
  /// driver after a relaunch can't reach the host to do it; seam=GitHubTokenCarrying on a driver
  /// that adopted the host's record
  func testAConnectCarriesTheMacsCurrentTokenToAnAdoptedHost() async throws {
    let railway = railway()
    let made = driver(railway, StubRelay())
    let host = try await made.create()
    var descriptor = HostDescriptor(driver: "railway")
    made.record(host, in: &descriptor)
    guard case .remote(let id) = host else { return XCTFail("\(host)") }
    descriptor.id = id
    // A relaunch: the host's ssh files are gone with the old driver's state.
    try? FileManager.default.removeItem(at: root.appendingPathComponent("hosts"))

    let relay = StubRelay()
    let fresh = driver(railway, relay, token: MacToken("gho_FAKE_rotated"))
    try fresh.adopt(descriptor)
    let carrying: any GitHubTokenCarrying = fresh
    try await carrying.refreshGitHubToken(on: host)

    let login = try XCTUnwrap(relay.calls(to: "ssh").last)
    XCTAssertEqual(login.stdin.map { String(decoding: $0, as: UTF8.self) }, "gho_FAKE_rotated")
    XCTAssertEqual(
      login.args.last,
      RailwayHostDriver.gitHubTokenCommand(path: RailwayHostDriver.gitHubTokenPath))
    let config = login.args[login.args.firstIndex(of: "-F")! + 1]
    XCTAssertTrue(FileManager.default.fileExists(atPath: config), "no ssh_config to log in with")
    XCTAssertFalse(login.args.joined(separator: " ").contains("gho_FAKE_rotated"))

    // A host the relay refuses says so, without the token.
    relay.ssh = [
      CommandResult(stdout: "", stderr: "Permission denied", exitCode: 255, timedOut: false)
    ]
    do {
      try await carrying.refreshGitHubToken(on: host)
      XCTFail("a refused write passed")
    } catch {
      XCTAssertFalse("\(error)".contains("gho_FAKE_rotated"), "\(error)")
    }
  }

  // MARK: On the host

  /// Runs `command` under this Mac's /bin/sh, as the host's shell runs it, with `stdin`.
  private func shell(
    _ command: String, stdin: String, environment: [String: String] = [:]
  ) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(environment) { $1 }
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    try process.run()
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  /// Value: protects=the token file is readable only by its owner, and a connect rewrites it only
  /// when the Mac's token changed (ADR 0072); fails_when=the file is made group- or
  /// world-readable, the same token is rewritten, a changed one is kept, or the token is printed;
  /// seam=the token write's host command, run by a real shell
  func testTheTokenWriteMakesAnOwnerOnlyFileAndRewritesItOnlyWhenItDiffers() throws {
    let file = root.appendingPathComponent("state/gh-token")
    let command = RailwayHostDriver.gitHubTokenCommand(path: file.path)

    let first = try shell(command, stdin: Self.token)
    XCTAssertEqual(first.status, 0, first.output)
    XCTAssertEqual(first.output, "rewritten\n")
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), Self.token + "\n")
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
    XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600)

    let same = try shell(command, stdin: Self.token)
    XCTAssertEqual(same.output, "unchanged\n")

    let rotated = try shell(command, stdin: "gho_FAKE_rotated")
    XCTAssertEqual(rotated.output, "rewritten\n")
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "gho_FAKE_rotated\n")
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
        as? NSNumber)?.intValue, 0o600)

    let empty = try shell(command, stdin: "")
    XCTAssertNotEqual(empty.status, 0, "an empty token replaced the file")
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "gho_FAKE_rotated\n")
  }

  /// Value: protects=a host clones and pushes any GitHub remote form with the user's token, and
  /// only github.com gets it (ADR 0072); fails_when=a remote form isn't rewritten to https, the
  /// helper answers another host or without the token, or a second run doubles the config;
  /// seam=railway-github.sh, run against a throwaway system git config
  func testTheGitSetupAnswersGitHubFromTheTokenFileForEveryRemoteForm() throws {
    let script = try HostSetup.checkout.script("railway-github")
    let token = root.appendingPathComponent("gh-token")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try (Self.token + "\n").write(to: token, atomically: true, encoding: .utf8)
    let system = root.appendingPathComponent("system.gitconfig")
    let environment = [
      "GIT_CONFIG_SYSTEM": system.path,
      "GIT_CONFIG_GLOBAL": root.appendingPathComponent("global.gitconfig").path,
      "HOME": root.path, "GIT_TERMINAL_PROMPT": "0",
    ]
    for _ in 1...2 {
      let run = try shell(
        "sh -s -- \(PosixShell.quoted(token.path))", stdin: script, environment: environment)
      XCTAssertEqual(run.status, 0, run.output)
    }

    for remote in [
      "git@github.com:o/r.git", "ssh://git@github.com/o/r.git", "https://github.com/o/r.git",
    ] {
      let url = try shell("git ls-remote --get-url \(remote)", stdin: "", environment: environment)
      XCTAssertEqual(url.output, "https://github.com/o/r.git\n", remote)
    }
    let rewrites = try shell(
      "git config --system --get-all url.https://github.com/.insteadOf", stdin: "",
      environment: environment)
    XCTAssertEqual(rewrites.output, "git@github.com:\nssh://git@github.com/\n")

    let github = try shell(
      "git credential fill", stdin: "protocol=https\nhost=github.com\n\n",
      environment: environment)
    XCTAssertTrue(github.output.contains("password=\(Self.token)\n"), github.output)
    XCTAssertTrue(github.output.contains("username=x-access-token\n"), github.output)
    let other = try shell(
      "git credential fill", stdin: "protocol=https\nhost=gitlab.com\n\n",
      environment: environment)
    XCTAssertFalse(other.output.contains(Self.token), "another host got the token")
  }
}

import XCTest

@testable import Workroom

/// The Mac's end of a local container workroom's git credential relay (#309): who is answered, for
/// what, and with what.
final class CredentialRelayTests: XCTestCase {
  private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String] = []
    var all: [String] { lock.withLock { requests } }
    func add(_ request: String) { lock.withLock { requests.append(request) } }
  }

  /// A known secret asking for github.com over https gets gh's username and password, and nothing
  /// else gh said; gh is asked for github.com only, whatever else the request carried.
  func testAKnownWorkroomIsAnsweredWithGhsCredentialOnly() throws {
    let asked = Asked()
    let relay = CredentialRelay(answer: { request in
      asked.add(request)
      return "protocol=https\nhost=github.com\nusername=joel\npassword=gho_x\nextra=1\n"
    })
    let secret = try relay.secret(for: UUID())
    XCTAssertEqual(
      relay.respond(to: "\(secret)\nprotocol=https\nhost=github.com\npath=o/r.git\n\n"),
      "username=joel\npassword=gho_x\n")
    XCTAssertEqual(asked.all, ["protocol=https\nhost=github.com\n\n"])
  }

  /// An unknown secret, another host, or plain http is answered with an error, and gh is never
  /// asked: another user of this Mac can reach the listener too.
  func testAnythingElseIsRefusedWithoutAskingGh() throws {
    let asked = Asked()
    let relay = CredentialRelay(answer: { request in
      asked.add(request)
      return "username=joel\npassword=gho_x\n"
    })
    let secret = try relay.secret(for: UUID())
    for request in [
      "guess\nprotocol=https\nhost=github.com\n\n",
      "\nprotocol=https\nhost=github.com\n\n",
      "\(secret)\nprotocol=https\nhost=gitlab.com\n\n",
      "\(secret)\nprotocol=http\nhost=github.com\n\n",
    ] {
      XCTAssertTrue(relay.respond(to: request).hasPrefix("error="), request)
    }
    XCTAssertEqual(asked.all, [])
  }

  /// gh with no sign-in, or one that fails, says so in an `error=` line the agent hands git.
  func testAGhWithoutASignInIsAnErrorLine() throws {
    let empty = CredentialRelay(answer: { _ in "protocol=https\nhost=github.com\n" })
    let secret = try empty.secret(for: UUID())
    XCTAssertEqual(
      empty.respond(to: "\(secret)\nprotocol=https\nhost=github.com\n\n"),
      "error=gh has no GitHub sign-in on this Mac: run `gh auth login`\n")
    let failing = CredentialRelay(answer: { _ in
      throw HostDriverError.provisioning("gh\nbroke")
    })
    let reply = failing.respond(
      to: "\(try failing.secret(for: UUID()))\nprotocol=https\nhost=github.com\n\n")
    XCTAssertTrue(reply.hasPrefix("error=") && !reply.dropLast().contains("\n"), reply)
  }

  /// A workroom's secret is its own and stays the same for the launch; its port is the same on
  /// every launch, below Linux's ephemeral range.
  func testSecretsAreOwnAndStablePortsBelowTheEphemeralRange() throws {
    let relay = CredentialRelay(answer: { _ in "" })
    let (one, two) = (UUID(), UUID())
    XCTAssertEqual(try relay.secret(for: one), try relay.secret(for: one))
    XCTAssertNotEqual(try relay.secret(for: one), try relay.secret(for: two))
    XCTAssertEqual(try relay.secret(for: one).count, 64)
    for _ in 0..<200 {
      let port = CredentialRelay.port(for: UUID())
      XCTAssertTrue((30_000..<32_000).contains(port), "\(port)")
    }
  }

  /// gh lists github.com in its hosts file when signed in there; the menu reads that, not gh.
  func testAGhSignInIsReadFromItsHostsFile() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("gh-\(UUID()).yml")
    defer { try? FileManager.default.removeItem(at: file) }
    XCTAssertFalse(CredentialRelay.hasGitHubSignIn(hosts: file))
    try "github.example.com:\n    user: x\n".write(to: file, atomically: true, encoding: .utf8)
    XCTAssertFalse(CredentialRelay.hasGitHubSignIn(hosts: file))
    try "github.com:\n    user: joel\n".write(to: file, atomically: true, encoding: .utf8)
    XCTAssertTrue(CredentialRelay.hasGitHubSignIn(hosts: file))
  }

  /// Secrets compare whole, and only equal ones match.
  func testSecretsCompareWhole() {
    XCTAssertTrue(CredentialRelay.same("abc", "abc"))
    XCTAssertFalse(CredentialRelay.same("abc", "abd"))
    XCTAssertFalse(CredentialRelay.same("abc", "ab"))
    XCTAssertFalse(CredentialRelay.same("", "a"))
  }

  /// A peer that sends junk and resets at once can't end the app (SIGPIPE), nor stop the listener:
  /// a real request after a run of them is still answered, over the loopback socket itself.
  func testResetPeersNeitherCrashNorStopTheListener() throws {
    let relay = CredentialRelay(answer: { _ in "username=u\npassword=p\n" })
    let secret = try relay.secret(for: UUID())
    let port = try relay.localPort()
    for _ in 0..<30 {
      guard let socket = LoopbackSocket.connect(port: port, timeout: 2) else {
        return XCTFail("connect \(errno)")
      }
      _ = "x\n\n".withCString { send(socket, $0, 3, 0) }
      var linger = linger(l_onoff: 1, l_linger: 0)
      setsockopt(socket, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
      Darwin.close(socket)
    }
    guard let socket = LoopbackSocket.connect(port: port, timeout: 2) else {
      return XCTFail("connect \(errno)")
    }
    defer { Darwin.close(socket) }
    let request = "\(secret)\nprotocol=https\nhost=github.com\n\n"
    _ = request.withCString { send(socket, $0, strlen($0), 0) }
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 256)
    while true {
      let count = recv(socket, &buffer, buffer.count, 0)
      guard count > 0 else { break }
      reply.append(buffer, count: count)
    }
    XCTAssertEqual(String(decoding: reply, as: UTF8.self), "username=u\npassword=p\n")
  }
}

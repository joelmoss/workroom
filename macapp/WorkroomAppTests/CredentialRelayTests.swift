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
  func testAKnownWorkroomIsAnsweredWithGhsCredentialOnly() {
    let asked = Asked()
    let relay = CredentialRelay(answer: { request in
      asked.add(request)
      return "protocol=https\nhost=github.com\nusername=joel\npassword=gho_x\nextra=1\n"
    })
    let secret = relay.secret(for: UUID())
    XCTAssertEqual(
      relay.respond(to: "\(secret)\nprotocol=https\nhost=github.com\npath=o/r.git\n\n"),
      "username=joel\npassword=gho_x\n")
    XCTAssertEqual(asked.all, ["protocol=https\nhost=github.com\n\n"])
  }

  /// An unknown secret, another host, or plain http is answered with an error, and gh is never
  /// asked: another user of this Mac can reach the listener too.
  func testAnythingElseIsRefusedWithoutAskingGh() {
    let asked = Asked()
    let relay = CredentialRelay(answer: { request in
      asked.add(request)
      return "username=joel\npassword=gho_x\n"
    })
    let secret = relay.secret(for: UUID())
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
  func testAGhWithoutASignInIsAnErrorLine() {
    let empty = CredentialRelay(answer: { _ in "protocol=https\nhost=github.com\n" })
    let secret = empty.secret(for: UUID())
    XCTAssertEqual(
      empty.respond(to: "\(secret)\nprotocol=https\nhost=github.com\n\n"),
      "error=gh has no GitHub sign-in on this Mac: run `gh auth login`\n")
    let failing = CredentialRelay(answer: { _ in
      throw HostDriverError.provisioning("gh\nbroke")
    })
    let reply = failing.respond(
      to: "\(failing.secret(for: UUID()))\nprotocol=https\nhost=github.com\n\n")
    XCTAssertTrue(reply.hasPrefix("error=") && !reply.dropLast().contains("\n"), reply)
  }

  /// A workroom's secret is its own and stays the same for the launch; its port is the same on
  /// every launch, below Linux's ephemeral range.
  func testSecretsAreOwnAndStablePortsBelowTheEphemeralRange() {
    let relay = CredentialRelay(answer: { _ in "" })
    let (one, two) = (UUID(), UUID())
    XCTAssertEqual(relay.secret(for: one), relay.secret(for: one))
    XCTAssertNotEqual(relay.secret(for: one), relay.secret(for: two))
    XCTAssertEqual(relay.secret(for: one).count, 64)
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
}

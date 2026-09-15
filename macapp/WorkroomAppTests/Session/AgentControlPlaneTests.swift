import Darwin
import XCTest

@testable import Workroom
@testable import WorkroomSessionProtocol

/// `AgentControlClient` against a real `wr-agent serve`.
///
/// The agent has its own integration tests in Rust and they are cheaper to run, so these cover only
/// what those structurally cannot: the boundary between two languages. The greeting, the envelope
/// and the descriptor list are each **encoded in Rust and decoded by hand in Swift**, and a
/// disagreement about a field width or a byte order would pass every test on either side alone
/// while presenting to a user as a permanently empty sidebar.
///
/// Note what is deliberately absent. The app never sends an `Attach` frame — it hands libghostty an
/// attach command to run as the pane's shell — so attach, resize, input and exit are the Rust
/// suite's to cover, and duplicating them here would test a path nothing ships.
final class AgentControlPlaneTests: XCTestCase {
  func testGreetingAndEnvelopeRoundTripAgainstAFreshAgent() throws {
    let harness = try AgentHarness.start()
    defer { harness.stop() }

    let client = AgentControlClient(socketPath: harness.socketPath)
    // An empty list is a real answer, not a failure to connect: reaching it means the greeting was
    // exchanged, the version was accepted, and a zero-count descriptor list decoded.
    XCTAssertEqual(client.list().count, 0)
    XCTAssertTrue(client.killAll(), "killAll on an empty agent still acknowledges")
  }

  /// The payoff. Rust's `encode_descriptor_list` and Swift's `SessionDescriptor.decodeList` were
  /// written separately against the same prose description of a wire format.
  func testASessionTheAgentHoldsIsDecodableByTheApp() throws {
    let harness = try AgentHarness.start()
    defer { harness.stop() }

    let client = AgentControlClient(socketPath: harness.socketPath)
    let identifier = UUID()
    try harness.startSession(identifier: identifier)

    XCTAssertTrue(
      harness.wait { client.list().count == 1 },
      "the attach never produced a session the app could see")

    let listed = try XCTUnwrap(client.list().first)
    XCTAssertEqual(listed.identifier.uuid, identifier, "the identifier survived the round trip")
    XCTAssertGreaterThan(listed.shellProcessID, 1, "and so did the shell's pid")
    XCTAssertTrue(listed.isAttached, "a session with a live client reports as attached")

    // `info` is served by filtering `list`, so this also pins that an identifier decoded from the
    // wire compares equal to the one the app minted — a byte-order slip would fail here and
    // nowhere else.
    XCTAssertNotNil(client.info(identifier: listed.identifier))
    XCTAssertNil(
      client.info(identifier: SessionIdentifier(UUID())),
      "an identifier nothing holds finds nothing")
  }

  func testKillAndKillAllReachTheAgentsSessions() throws {
    let harness = try AgentHarness.start()
    defer { harness.stop() }

    let client = AgentControlClient(socketPath: harness.socketPath)
    let first = UUID()
    let second = UUID()
    try harness.startSession(identifier: first)
    try harness.startSession(identifier: second)
    XCTAssertTrue(
      harness.wait { client.list().count == 2 }, "both sessions should be listed")

    XCTAssertTrue(client.kill(identifier: SessionIdentifier(first)))
    XCTAssertTrue(
      harness.wait { client.list().count == 1 }, "kill should remove exactly one")
    XCTAssertEqual(client.list().first?.identifier.uuid, second)

    XCTAssertTrue(client.killAll())
    XCTAssertTrue(harness.wait { client.list().isEmpty }, "killAll should empty the agent")
  }

  /// `decodeHello` throws `notAnAgent` rather than returning nil specifically so that a peer which
  /// is not an agent fails at its second byte instead of waiting out the two-second timeout. A
  /// login banner or an MOTD on a remote stream is the case that motivates it, and it is reachable
  /// locally with any socket that greets first.
  func testAPeerThatIsNotAnAgentIsRejectedPromptly() throws {
    signal(SIGPIPE, SIG_IGN)
    let directory = URL(
      fileURLWithPath: "/tmp/wra-banner-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let socketPath = directory.appendingPathComponent("b.sock").path

    let listener = try UnixSocketListener.listen(at: socketPath)
    defer { close(listener) }
    let greeter = Thread {
      let accepted = accept(listener, nil, nil)
      guard accepted >= 0 else { return }
      let banner = Array("Welcome to ubuntu 24.04 LTS\n".utf8)
      _ = banner.withUnsafeBytes { Darwin.send(accepted, $0.baseAddress, $0.count, 0) }
      // Hold the connection open: giving up must come from recognising the banner, not from the
      // peer hanging up, or this would pass against the timeout it exists to avoid.
      Thread.sleep(forTimeInterval: 3)
      close(accepted)
    }
    greeter.start()

    let started = Date()
    let client = AgentControlClient(socketPath: socketPath)
    XCTAssertTrue(client.list().isEmpty)
    XCTAssertLessThan(
      Date().timeIntervalSince(started), 1.5,
      "a banner must be recognised as not-an-agent, not waited out")
  }

}

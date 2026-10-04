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
    let home = try directory()
    let file = home.appendingPathComponent(".config/gh/hosts.yml")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    XCTAssertFalse(CredentialRelay.hasGitHubSignIn(environment: [:], home: home))
    try "github.example.com:\n    user: x\n".write(to: file, atomically: true, encoding: .utf8)
    XCTAssertFalse(CredentialRelay.hasGitHubSignIn(environment: [:], home: home))
    try "github.com:\n    user: joel\n".write(to: file, atomically: true, encoding: .utf8)
    XCTAssertTrue(CredentialRelay.hasGitHubSignIn(environment: [:], home: home))
  }

  /// gh's sign-in is found where gh looks in this app's environment: a token, then
  /// `GH_CONFIG_DIR`, then `XDG_CONFIG_HOME`, in gh's order.
  func testAGhSignInIsFoundWhereGhLooks() throws {
    let home = try directory()
    let signedIn = "github.com:\n    user: joel\n"
    let config = home.appendingPathComponent("config-dir")
    let xdg = home.appendingPathComponent("xdg")
    for directory in [config, xdg.appendingPathComponent("gh")] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try signedIn.write(
        to: directory.appendingPathComponent("hosts.yml"), atomically: true, encoding: .utf8)
    }
    XCTAssertTrue(CredentialRelay.hasGitHubSignIn(environment: ["GH_TOKEN": "x"], home: home))
    XCTAssertTrue(CredentialRelay.hasGitHubSignIn(environment: ["GITHUB_TOKEN": "x"], home: home))
    XCTAssertFalse(CredentialRelay.hasGitHubSignIn(environment: ["GH_TOKEN": ""], home: home))
    XCTAssertTrue(
      CredentialRelay.hasGitHubSignIn(environment: ["GH_CONFIG_DIR": config.path], home: home))
    XCTAssertTrue(
      CredentialRelay.hasGitHubSignIn(environment: ["XDG_CONFIG_HOME": xdg.path], home: home))
    // GH_CONFIG_DIR wins, even over a signed-in XDG config.
    XCTAssertFalse(
      CredentialRelay.hasGitHubSignIn(
        environment: [
          "GH_CONFIG_DIR": home.appendingPathComponent("empty").path,
          "XDG_CONFIG_HOME": xdg.path,
        ],
        home: home))
  }

  private func directory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "gh-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
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
      // Connected once, not retried: the relay's accept queue holds a burst like this (#322). A
      // retry here hid that queue being too short.
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

  /// Everything `socket` is sent before it closes.
  private func reply(_ socket: Int32) -> String {
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 256)
    while true {
      let count = recv(socket, &buffer, buffer.count, 0)
      guard count > 0 else { break }
      reply.append(buffer, count: count)
    }
    return String(decoding: reply, as: UTF8.self)
  }

  /// A request past `maxRequest` with no end in sight is dropped unanswered, and gh never asked.
  func testAnOversizedRequestIsDroppedUnanswered() throws {
    let asked = Asked()
    let relay = CredentialRelay(answer: { request in
      asked.add(request)
      return "username=u\npassword=p\n"
    })
    let secret = try relay.secret(for: UUID())
    let port = try relay.localPort()
    guard let socket = LoopbackSocket.connect(port: port, timeout: 2) else {
      return XCTFail("connect \(errno)")
    }
    defer { Darwin.close(socket) }
    // The relay may close before it has read all of this: an EPIPE, not a signal that ends the run,
    // since `LoopbackSocket.connect` sets `SO_NOSIGPIPE`.
    let request =
      "\(secret)\nprotocol=https\nhost=github.com\n"
      + String(repeating: "x", count: CredentialRelay.maxRequest) + "\n\n"
    _ = request.withCString { send(socket, $0, strlen($0), 0) }
    XCTAssertEqual(reply(socket), "")
    XCTAssertEqual(asked.all, [])
  }

  /// Idle connections that never say a secret, more than there are answering slots, don't keep a
  /// workroom's request from being answered: anyone who can reach the listener could open them.
  func testIdleStrangersDoNotBlockAKnownWorkroom() throws {
    let relay = CredentialRelay(answer: { _ in "username=u\npassword=p\n" })
    let secret = try relay.secret(for: UUID())
    let port = try relay.localPort()
    var held: [Int32] = []
    defer { for socket in held { Darwin.close(socket) } }
    for _ in 0..<(CredentialRelay.maxConcurrent + 4) {
      guard let socket = LoopbackSocket.connect(port: port, timeout: 2) else {
        return XCTFail("connect \(errno)")
      }
      held.append(socket)
    }
    Thread.sleep(forTimeInterval: 0.3)
    guard let socket = LoopbackSocket.connect(port: port, timeout: 2) else {
      return XCTFail("connect \(errno)")
    }
    defer { Darwin.close(socket) }
    let request = "\(secret)\nprotocol=https\nhost=github.com\n\n"
    _ = request.withCString { send(socket, $0, strlen($0), 0) }
    XCTAssertEqual(reply(socket), "username=u\npassword=p\n")
  }

  /// A connection whose peer has already reset when it is taken gives its reading permit back
  /// (#322 review). Setting `SO_NOSIGPIPE` on it fails (EINVAL), and that path returned before the
  /// release, so each such peer leaked a permit; past `maxReading` of them every request was
  /// closed unread, a workroom's included, for the rest of the launch.
  func testAPeerThatResetBeforeItIsTakenGivesItsPermitBack() throws {
    let relay = CredentialRelay(answer: { _ in "username=u\npassword=p\n" })
    let secret = try relay.secret(for: UUID())
    let port = try relay.localPort()
    let side = try XCTUnwrap(LoopbackSocket.listen(backlog: 128))
    defer { Darwin.close(side.descriptor) }
    for _ in 0..<(CredentialRelay.maxReading * 2) {
      let client = try XCTUnwrap(LoopbackSocket.connect(port: side.port, timeout: 2))
      let accepted = Darwin.accept(side.descriptor, nil, nil)
      XCTAssertGreaterThanOrEqual(accepted, 0)
      var linger = linger(l_onoff: 1, l_linger: 0)
      setsockopt(client, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
      Darwin.close(client)
      Thread.sleep(forTimeInterval: 0.005)
      relay.take(accepted)
    }
    Thread.sleep(forTimeInterval: 0.2)
    let socket = try XCTUnwrap(LoopbackSocket.connect(port: port, timeout: 2))
    defer { Darwin.close(socket) }
    let request = "\(secret)\nprotocol=https\nhost=github.com\n\n"
    _ = request.withCString { send(socket, $0, strlen($0), 0) }
    XCTAssertEqual(reply(socket), "username=u\npassword=p\n", "the reading permits leaked")
  }

  /// The relay's accept queue holds a burst while its accept thread is behind, as it is on a busy
  /// Mac (#322). On loopback macOS resets a connection once the queue is full, so a short queue
  /// turned a real workroom's request away; at the old 8, the burst here was reset about halfway
  /// (`ECONNRESET`). Nothing accepts here, standing in for a thread that is behind.
  func testTheRelaysAcceptQueueHoldsABurstWhileNothingIsAccepted() throws {
    let made = try XCTUnwrap(LoopbackSocket.listen(backlog: CredentialRelay.backlog))
    defer { Darwin.close(made.descriptor) }
    var held: [Int32] = []
    defer { for socket in held { Darwin.close(socket) } }
    for index in 0..<40 {
      guard let socket = LoopbackSocket.connect(port: made.port, timeout: 2) else {
        return XCTFail("connection \(index) of 40: errno \(errno)")
      }
      held.append(socket)
    }
  }

  /// A client socket can't end the process when its peer resets: `LoopbackSocket.connect` sets
  /// `SO_NOSIGPIPE`. Without it, a test writing to a relay that had reset it crashed the whole
  /// test run with SIGPIPE (#322).
  func testALoopbackClientNeverRaisesSIGPIPE() throws {
    let made = try XCTUnwrap(LoopbackSocket.listen(backlog: 1))
    defer { Darwin.close(made.descriptor) }
    let socket = try XCTUnwrap(LoopbackSocket.connect(port: made.port, timeout: 2))
    defer { Darwin.close(socket) }
    var value: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    XCTAssertEqual(getsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &value, &length), 0)
    XCTAssertNotEqual(value, 0)
  }

  /// Past `maxReading` connections at once, one more is closed at once rather than read; the idle
  /// ones are dropped after `requestDeadline`, and a real request is answered again.
  func testConnectionsPastTheReadingCapAreTurnedAway() throws {
    let relay = CredentialRelay(answer: { _ in "username=u\npassword=p\n" })
    let secret = try relay.secret(for: UUID())
    let port = try relay.localPort()
    var held: [Int32] = []
    defer { for socket in held { Darwin.close(socket) } }
    for _ in 0..<CredentialRelay.maxReading {
      guard let socket = LoopbackSocket.connect(port: port, timeout: 2) else {
        return XCTFail("connect \(errno)")
      }
      held.append(socket)
    }
    // Each idle one is being read, waiting for its request.
    Thread.sleep(forTimeInterval: 0.3)
    guard let extra = LoopbackSocket.connect(port: port, timeout: 2) else {
      return XCTFail("connect \(errno)")
    }
    let request = "\(secret)\nprotocol=https\nhost=github.com\n\n"
    _ = request.withCString { send(extra, $0, strlen($0), 0) }
    XCTAssertEqual(reply(extra), "", "a connection past the cap was read")
    Darwin.close(extra)

    Thread.sleep(forTimeInterval: CredentialRelay.requestDeadline + 0.5)
    guard let socket = LoopbackSocket.connect(port: port, timeout: 2) else {
      return XCTFail("connect \(errno)")
    }
    defer { Darwin.close(socket) }
    _ = request.withCString { send(socket, $0, strlen($0), 0) }
    XCTAssertEqual(reply(socket), "username=u\npassword=p\n")
  }

  /// A workroom that's gone takes its secret with it: what it was given answers nothing any more.
  @MainActor
  func testAClosedWorkroomsSecretIsRefused() throws {
    let relay = CredentialRelay(answer: { _ in "username=u\npassword=p\n" })
    let id = UUID()
    let secret = try relay.secret(for: id)
    let request = "\(secret)\nprotocol=https\nhost=github.com\n\n"
    XCTAssertEqual(relay.respond(to: request), "username=u\npassword=p\n")
    relay.close(id)
    XCTAssertTrue(relay.respond(to: request).hasPrefix("error="))
  }

  /// What gh prints and its exit status come back as they are, its input reaching it.
  func testGhsOutputAndStatusComeBack() throws {
    let ran = try CredentialRelay.run(
      URL(fileURLWithPath: "/bin/sh"), ["-c", "cat; printf done; exit 3"], input: "asked\n",
      environment: [:], name: "gh")
    XCTAssertEqual(ran.status, 3)
    XCTAssertEqual(ran.output, "asked\ndone")
  }

  /// gh is bounded however it ends: one that exits while something it started keeps its output
  /// open, and one that ignores SIGTERM, each give the slot back by the deadline.
  func testGhIsBoundedWhateverItDoes() throws {
    for script in ["(sleep 30) & exit 0", "trap '' TERM; sleep 30"] {
      let start = Date()
      XCTAssertThrowsError(
        try CredentialRelay.run(
          URL(fileURLWithPath: "/bin/sh"), ["-c", script], input: nil, environment: [:],
          name: "gh", deadline: 1),
        script)
      XCTAssertLessThan(Date().timeIntervalSince(start), 5, script)
    }
  }
}

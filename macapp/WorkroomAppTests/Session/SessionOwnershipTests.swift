import Darwin
import Foundation
import WorkroomSessionProtocol
import XCTest

@testable import Workroom

/// `PersistentSessionControlClient.ownership` — telling "the daemon says no" apart from "the daemon
/// never answered".
///
/// **Why this needed its own method.** `transact` returns nil for a connect failure, a write
/// failure, an EOF, its 2-second timeout AND a perfectly good reply that happens to name no
/// session. `info` therefore cannot distinguish them, and folding all of it into "not owned" is
/// what let a slow daemon route one of its own live sessions to the agent — which creates on first
/// attach, so it forked a second pty under the same id, orphaned the user's running shell where no
/// pane could reach it, and showed a fresh prompt as though nothing had been lost.
final class SessionOwnershipTests: XCTestCase {
  private var directory: URL!
  private var servers: [Int32] = []

  override func setUpWithError() throws {
    try super.setUpWithError()
    // Short path: a unix socket address is capped at 104 bytes, and the per-test temporary
    // directory blows that.
    directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("wr-own-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    for server in servers { close(server) }
    servers = []
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func identifier() -> SessionIdentifier {
    SessionIdentifier(uuidString: UUID().uuidString)!
  }

  /// A daemon that answers `info` with `reply`, or — when nil — accepts and then says nothing at
  /// all, which is the wedged daemon this whole distinction exists for.
  /// Each call gets its own socket: the fake accepts exactly one connection, so a test that makes
  /// two calls needs two of them, and reusing the path fails to bind with `EADDRINUSE`.
  private func fakeDaemon(reply: [SessionDescriptor]?) throws -> String {
    let socketPath = directory.appendingPathComponent("d\(servers.count).sock").path
    let listener = try Self.listen(at: socketPath)
    servers.append(listener)
    Thread.detachNewThread {
      let accepted = accept(listener, nil, nil)
      guard accepted >= 0 else { return }
      guard let reply else {
        // Held open past the client's 2s deadline WITHOUT replying. Closing instead would be an
        // EOF, which is a different failure and one the old code already handled the same way.
        Thread.sleep(forTimeInterval: 4)
        close(accepted)
        return
      }
      let frame = SessionFrame(
        kind: .sessions, payload: SessionDescriptor.encodeList(reply))
      let bytes = frame.encoded()
      _ = bytes.withUnsafeBytes { Darwin.send(accepted, $0.baseAddress, $0.count, 0) }
      Thread.sleep(forTimeInterval: 0.3)
      close(accepted)
    }
    return socketPath
  }

  /// The case the old `Bool` got wrong, and the reason for the whole change.
  ///
  /// A daemon that accepts the connection and then does not answer is indistinguishable from one
  /// that answered "no such session" if you only look at `info`. Asserting BOTH here is the point:
  /// the two calls must disagree, or `ownership` has bought nothing.
  func testASilentDaemonIsUnreachableNotNotOwned() throws {
    let socketPath = try fakeDaemon(reply: nil)
    let client = PersistentSessionControlClient(socketPath: socketPath)
    let id = identifier()

    XCTAssertNil(client.info(identifier: id), "info cannot tell this from an empty answer")

    let client2 = PersistentSessionControlClient(socketPath: try fakeDaemon(reply: nil))
    guard case .unreachable = client2.ownership(identifier: id) else {
      return XCTFail("a daemon that never answered must not report notOwned")
    }
  }

  /// The other half: a daemon that DOES answer, naming no session, is a definitive no. Without
  /// this, "always report unreachable" would pass the test above.
  func testADaemonThatAnswersWithNoSessionIsNotOwned() throws {
    let socketPath = try fakeDaemon(reply: [])
    let client = PersistentSessionControlClient(socketPath: socketPath)

    guard case .notOwned = client.ownership(identifier: identifier()) else {
      return XCTFail("an empty answer is an answer")
    }
  }

  func testADaemonThatNamesTheSessionOwnsIt() throws {
    let id = identifier()
    let descriptor = SessionDescriptor(
      identifier: id, shellProcessID: 4242, ttyDevice: 0, workingDirectory: "/tmp",
      isAttached: false)
    let client = PersistentSessionControlClient(
      socketPath: try fakeDaemon(reply: [descriptor]))

    guard case .owned = client.ownership(identifier: id) else {
      return XCTFail("the daemon named this session")
    }
  }

  /// No socket at the path at all — connect fails outright. Reported as unreachable rather than
  /// notOwned; `PersistentSessionService` maps the "there is no daemon socket file" case to
  /// notOwned itself, before it ever builds a client.
  func testAnAbsentDaemonIsUnreachable() {
    let client = PersistentSessionControlClient(
      socketPath: directory.appendingPathComponent("nothing.sock").path)

    guard case .unreachable = client.ownership(identifier: identifier()) else {
      return XCTFail("nothing is listening")
    }
  }

  private static func listen(at socketPath: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket()"])
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw NSError(
        domain: "test", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "socket path too long: \(socketPath)"])
    }
    withUnsafeMutableBytes(of: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self) { dest in
        for (index, byte) in pathBytes.enumerated() { dest[index] = CChar(bitPattern: byte) }
      }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { casted in
        Darwin.bind(descriptor, casted, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
      close(descriptor)
      throw NSError(
        domain: "test", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "bind/listen failed: \(errno)"])
    }
    return descriptor
  }
}

/// The routing rule itself, exhaustively.
///
/// Six combinations, all of them asserted, because the interesting one is a deliberate asymmetry
/// that reads like a bug unless you know why: an unanswered probe resolves to the DAEMON even
/// though the daemon is the backend being migrated away from.
final class SessionOwnerRuleTests: XCTestCase {
  func testADaemonThatOwnsTheSessionKeepsIt() {
    for preferred in SessionBackend.allCases {
      XCTAssertEqual(
        PersistentSessionService.owner(preferred: preferred, daemon: .owned), .swiftDaemon,
        "the daemon holds that pty and cannot hand it over, whatever new sessions do")
    }
  }

  /// The drain. Without this the migration never happens — every session would stay on the daemon.
  func testADefinitiveNoSendsTheSessionWhereNewOnesGo() {
    XCTAssertEqual(
      PersistentSessionService.owner(preferred: .rustAgent, daemon: .notOwned), .rustAgent)
    XCTAssertEqual(
      PersistentSessionService.owner(preferred: .swiftDaemon, daemon: .notOwned), .swiftDaemon)
  }

  /// The asymmetry, stated as a test so it cannot be "simplified" into matching `notOwned`.
  ///
  /// Guessing daemon when the answer was agent costs an error message — `workroom-session attach`
  /// reports no such session. Guessing agent when the answer was daemon costs the user their
  /// running shell: the agent creates on first attach, forking a second pty under the same id and
  /// orphaning the real one behind a pane that looks freshly opened.
  func testAnUnansweredProbeFailsTowardTheLoudDirection() {
    XCTAssertEqual(
      PersistentSessionService.owner(preferred: .rustAgent, daemon: .unreachable), .swiftDaemon,
      "an unanswered probe routed to the agent forks a second pty under the same id")
    XCTAssertEqual(
      PersistentSessionService.owner(preferred: .swiftDaemon, daemon: .unreachable), .swiftDaemon)
  }
}

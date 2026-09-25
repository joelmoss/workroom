import WorkroomSessionProtocol
import XCTest

@testable import Workroom

/// The app's side of hand-off (#230): what it gets back from a real agent. What the agent then does
/// with the request is `vcs/crates/wr-agent/tests/hand_off.rs`.
final class AgentHandOffTests: XCTestCase {
  /// The launch with nothing to hand off, end to end: the app runs the bundled binary's `hand-off`
  /// against a live agent that is already that binary, and the agent says so and carries on.
  func testAnAgentAlreadyRunningTheBundledBinaryIsLeftAlone() throws {
    let agent = try AgentHarness.start()
    defer { agent.stop() }
    let result = AgentHandOff.run(binary: try AgentHarness.binaryURL(), socket: agent.socketPath)
    XCTAssertEqual(result, "exit 0: current")
    let anyone = try XCTUnwrap(SessionIdentifier(bytes: Array(repeating: 1, count: 16)))
    XCTAssertEqual(
      AgentControlClient(socketPath: agent.socketPath).ownership(identifier: anyone), .notOwned,
      "the agent should still be answering")
  }

  /// No agent, no request: the first launch after a reboot has nothing to hand off.
  func testNoAgentIsNotAnError() throws {
    let result = AgentHandOff.run(
      binary: try AgentHarness.binaryURL(), socket: "/tmp/wra-none-\(UUID().uuidString.prefix(8))")
    XCTAssertEqual(result, "no agent running")
  }

  /// `AgentHandOff.run` shares its process runner (`SessionBackendProbe.run`) with the protocol
  /// probe, refactored in this change from a fixed `["protocol"]` invocation to a general one. A
  /// binary that never answers is killed and reported as a timeout rather than left to hang the
  /// 6s `AgentHandOff.timeout` forever — `exec sleep` so the timed-out process IS the sleep (no
  /// child of its own left holding the pipe once killed, the way a plain `sleep` inside `sh`
  /// would).
  func testARunnerThatNeverAnswersIsKilledAndReportedAsATimeout() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wra-hang-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("hangs")
    try "#!/bin/sh\nexec sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    XCTAssertThrowsError(
      try SessionBackendProbe.run(script, arguments: [], timeout: 0.3)
    ) { error in
      XCTAssertEqual(error as? SessionBackendProbe.ProbeError, .timedOut(0.3))
    }
  }
}

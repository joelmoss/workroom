import WorkroomSessionProtocol
import XCTest

@testable import Workroom

/// The app's side of hand-off (#230): when it asks, and what it gets back from a real agent. What
/// the agent then does with the request is `vcs/crates/wr-agent/tests/hand_off.rs`.
final class AgentHandOffTests: XCTestCase {
  /// Once a launch, at the first pane, and only when the agent is where panes go. A pane attached
  /// to an agent that is then replaced loses its connection, so a second ask would be a hazard.
  @MainActor
  func testTheHandOffIsAskedForOnceAtTheFirstPaneAndOnlyForTheAgent() {
    var asked = 0
    let service = PersistentSessionService(
      probe: { _ in .ready(version: "protocol 6") }, ownership: { _ in .notOwned },
      handOff: { asked += 1 })
    XCTAssertEqual(asked, 0, "nothing is asked before a pane needs the agent")
    for _ in 0..<3 { _ = service.backend }
    XCTAssertEqual(asked, 1)

    var askedOfNothing = 0
    let unhealthy = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "exited 127") }, ownership: { _ in .notOwned },
      handOff: { askedOfNothing += 1 })
    _ = unhealthy.backend
    XCTAssertEqual(askedOfNothing, 0, "an agent that cannot run is not handed anything")
  }

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
}

import DaemonConnection
import XCTest

@testable import Workroom

/// What program status (#358) says in tooltips and to VoiceOver.
final class ProgramStatusPresentationTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  private func blocked(
    _ kind: ProgramStatusKind, message: String = "", id: String = ""
  ) -> ProgramStatusRecord {
    ProgramStatusRecord(id: id, state: .blocked, kind: kind, message: message, episode: 1)
  }

  private func rollup(
    blocked: [ProgramStatusRecord] = [], error: ProgramStatusRecord? = nil,
    done: ProgramStatusRecord? = nil, stale: Bool = false, since: Date? = nil
  ) -> ProgramStatusRollup {
    ProgramStatusRollup(
      reporting: true, blocked: blocked, error: error, working: false, done: done, revision: 1,
      stale: stale, blockedSince: since ?? (blocked.isEmpty ? nil : now))
  }

  private func lines(
    _ indicator: PaneIndicator, _ rollup: ProgramStatusRollup?,
    host: ProgramStatusMonitor.HostState? = .live, hasSession: Bool = true
  ) -> [String] {
    ProgramStatusPresentation.tooltipLines(
      indicator: indicator, rollup: rollup, hostState: host, hasSession: hasSession, now: now)
  }

  func testAWaitingRequestSaysItsKindItsMessageAndWhoReportedIt() {
    XCTAssertEqual(
      lines(.blocked, rollup(blocked: [blocked(.permission, message: "Apply?")])),
      ["Waiting for your permission", "Apply?", "Reported by the program in this terminal"])
    XCTAssertEqual(
      lines(.blocked, rollup(blocked: [blocked(.question)]))[0], "Waiting for your answer")
    XCTAssertEqual(
      lines(.blocked, rollup(blocked: [blocked(.auth)]))[0], "Waiting for you to sign in")
    XCTAssertEqual(lines(.blocked, rollup(blocked: [blocked(.none)]))[0], "Waiting for your input")
  }

  func testSeveralRequestsAreCountedWithTheirKindsAndTheOldestsMessage() {
    let both = rollup(blocked: [
      blocked(.permission, message: "first", id: "a"),
      blocked(.question, message: "second", id: "b"),
    ])
    XCTAssertEqual(
      lines(.blocked, both).prefix(2), ["2 requests waiting: permission, question", "first"])
  }

  func testTheMessageIsOneLineCutAt120Characters() {
    XCTAssertEqual(ProgramStatusPresentation.oneLine("a\nb\r\nc"), "a b c")
    XCTAssertNil(ProgramStatusPresentation.oneLine("  \n "))
    let long = ProgramStatusPresentation.oneLine(String(repeating: "x", count: 200))
    XCTAssertEqual(long?.count, 120)
    XCTAssertEqual(long?.last, "…")
    XCTAssertEqual(ProgramStatusPresentation.oneLine(String(repeating: "x", count: 120))?.last, "x")
  }

  func testStaleAndStuckLinesEndTheWaitingTooltip() {
    let stale = lines(.blocked, rollup(blocked: [blocked(.permission)], stale: true))
    XCTAssertEqual(stale.last, "May be out of date: reconnecting…")

    let justUnder = now.addingTimeInterval(-599)
    XCTAssertFalse(
      lines(.blocked, rollup(blocked: [blocked(.permission)], since: justUnder)).contains(
        ProgramStatusPresentation.stuckLine))
    let tenMinutes = now.addingTimeInterval(-600)
    XCTAssertEqual(
      lines(.blocked, rollup(blocked: [blocked(.permission)], since: tenMinutes)).last,
      "Stuck? Right-click, then Clear status.")
    // Clear status can't reach an unreachable host, so the hint waits for the link.
    XCTAssertFalse(
      lines(.blocked, rollup(blocked: [blocked(.permission)], stale: true, since: tenMinutes))
        .contains(ProgramStatusPresentation.stuckLine))
  }

  func testAFinishedTurnSaysSoWithItsMessage() {
    let done = ProgramStatusRecord(id: "", state: .done, message: "All tests pass")
    XCTAssertEqual(
      lines(.done, rollup(done: done)),
      ["Turn finished", "All tests pass", "Reported by the program in this terminal"])
  }

  /// A command result (#473) says what the shell reported, and never speaks for the program.
  func testACommandResultSaysTheShellReportedItWithItsCommandLine() {
    let passed = ProgramStatusRecord(
      id: "shell command", state: .done, message: "npm test", exitCode: 0)
    let failed = ProgramStatusRecord(
      id: "shell command", state: .error, message: "npm test", exitCode: 1)
    XCTAssertEqual(
      lines(.done, rollup(done: passed)),
      ["Command finished", "npm test", "Reported by the shell in this terminal"])
    XCTAssertEqual(
      lines(.error, rollup(error: failed)),
      ["Command failed (exit 1)", "npm test", "Reported by the shell in this terminal"])
    let untitled = ProgramStatusRecord(id: "shell command", state: .error, exitCode: 2)
    XCTAssertEqual(
      lines(.error, rollup(error: untitled)),
      ["Command failed (exit 2)", "Reported by the shell in this terminal"])

    XCTAssertEqual(
      ProgramStatusPresentation.accessibilityValue(indicator: .done, rollup: rollup(done: passed)),
      "Command finished")
    XCTAssertEqual(
      ProgramStatusPresentation.accessibilityValue(
        indicator: .error, rollup: rollup(error: failed)),
      "Command failed (exit 1)")
    XCTAssertEqual(
      ProgramStatusPresentation.accessibilityParts(indicator: .done, rollup: rollup(done: passed)),
      ["command finished"])

    let program = ProgramStatusRecord(id: "", state: .error, message: "Crashed")
    XCTAssertEqual(
      lines(.error, rollup(error: program)),
      ["The program reported an error", "Crashed", "Reported by the program in this terminal"])
  }

  /// With nothing reported, the last line says why, from the pane's host; nothing at all for a pane
  /// with no session or a host nobody follows.
  func testNothingReportedSaysWhyFromTheHost() {
    XCTAssertEqual(lines(.none, nil, host: .live), ["Program status: not reported"])
    XCTAssertEqual(lines(.none, nil, host: .stale), ["Program status: not reported"])
    XCTAssertEqual(lines(.none, nil, host: .connecting), ["Program status: connecting…"])
    XCTAssertEqual(
      lines(.none, nil, host: .unavailable("old daemon")),
      ["Program status: unavailable on this host"])
    XCTAssertEqual(lines(.none, nil, host: nil), [])
    XCTAssertEqual(lines(.none, nil, hasSession: false), [])
    let cleared = ProgramStatusRollup(
      reporting: false, blocked: [], error: nil, working: false, done: nil, revision: 2,
      stale: false, blockedSince: nil)
    XCTAssertEqual(
      lines(.none, cleared), ["Program status: not reported"], "a cleared session reports nothing")
  }

  /// A reporting chip's value names its state; without a report the OSC 9;4 path's exact words stay,
  /// which `RunStatusUITests` and `GhosttyActionDispatchUITests` assert.
  func testTheChipValueKeepsTheOSC94Words() {
    let waiting = rollup(blocked: [blocked(.question)])
    func value(_ indicator: PaneIndicator, _ rollup: ProgramStatusRollup? = nil) -> String {
      ProgramStatusPresentation.accessibilityValue(indicator: indicator, rollup: rollup)
    }
    XCTAssertEqual(value(.blocked, waiting), "Waiting for your answer")
    XCTAssertEqual(value(.done), "Turn finished")
    XCTAssertEqual(value(.error), "Error")
    XCTAssertEqual(value(.running(failed: true)), "Error")
    XCTAssertEqual(value(.running(failed: false)), "Busy")
    XCTAssertEqual(value(.none), "Idle")
  }

  func testParentLabelsSayWaitingAndOutOfDate() {
    XCTAssertEqual(
      ProgramStatusPresentation.accessibilityParts(
        indicator: .blocked, rollup: rollup(blocked: [blocked(.permission)], stale: true)),
      ["waiting for your permission", "may be out of date"])
    XCTAssertEqual(
      ProgramStatusPresentation.accessibilityParts(indicator: .running(failed: false), rollup: nil),
      [])
    XCTAssertEqual(
      ProgramStatusPresentation.waitingLabel(count: 2, stale: false), "2 terminals need you")
    XCTAssertEqual(
      ProgramStatusPresentation.waitingLabel(count: 1, stale: true),
      "1 terminal needs you, may be out of date")
    XCTAssertEqual(
      ProgramStatusPresentation.waitingTooltip(count: 2), "2 terminals waiting for you")
  }
}

import Foundation
import XCTest

@testable import Workroom

/// The one thing about `GhosttySurfaceView.applyPersistentSession` that a behavioural test cannot
/// reach: that it does **not** consult the global `PersistentSessionService.isAvailable` before
/// attaching.
///
/// **Why this is a source-parsing test.** The obvious version drives the service and asserts
/// `attachCommand(forSession:)` is non-nil while `isAvailable` is false — which is true whatever
/// the view does, so reintroducing the guard leaves it green. That was measured, not assumed:
/// putting the guard back and re-running `PersistentSessionRoutingTests` produced 3 passes. A test
/// that cannot fail for the reason it was written is worse than no test, and this repo has paid for
/// that twice already (see the commit "cover the wiring, not just the writer" and the "verify the
/// premise" rule in `macapp/CLAUDE.md`).
///
/// `applyPersistentSession` is private, builds a `ghostty_surface_config_s`, and lives on an
/// `NSView` subclass that XCUITest cannot query, so the call site itself is the only observable.
/// `DefaultsIsolationTests.testEveryShippedKeyDeclaresTheAppSuite` already parses source to enforce
/// a rule the type system cannot, which is the same trade: a cheap, blunt check that actually fires.
///
/// What it costs: it is sensitive to how the guard is spelled, not to what it means. A future
/// author could route the same value through a differently-named helper and slip past. It catches
/// the realistic regression — someone "restoring" the availability check — and nothing subtler.
final class PersistentSessionAttachGateTests: XCTestCase {
  /// Walks up from this file rather than reading a bundle resource: the app sources are not in the
  /// test bundle, and `#filePath` is stable across every configuration this suite runs in.
  private static var surfaceViewSource: String {
    get throws {
      let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Session/
        .deletingLastPathComponent()  // WorkroomAppTests/
        .deletingLastPathComponent()  // macapp/
        .appendingPathComponent("WorkroomApp/Core/GhosttySurfaceView.swift")
      return try String(contentsOf: url, encoding: .utf8)
    }
  }

  /// The body of `applyPersistentSession`, from its declaration to the next declaration at the same
  /// indentation.
  ///
  /// Matching `"\n  private func"` was wrong: the next declaration is `func
  /// reattachPersistentSession()`, which is not private, so the extracted "body" ran on past the end
  /// of the function it was supposed to bound. Matching any `func` at two-space indentation is what
  /// the comment always claimed.
  private static func applyPersistentSessionBody(in source: String) throws -> String {
    guard let start = source.range(of: "private func applyPersistentSession") else {
      throw XCTSkip("applyPersistentSession has been renamed; update this test deliberately")
    }
    let rest = source[start.upperBound...]
    guard
      let end = rest.range(
        of: "\n  (?:private |fileprivate |internal )?(?:static )?func ",
        options: .regularExpression)
    else { return String(rest) }
    return String(rest[rest.startIndex..<end.lowerBound])
  }

  func testTheAttachGuardDoesNotConsultGlobalAvailability() throws {
    let body = try Self.applyPersistentSessionBody(in: Self.surfaceViewSource)

    // No discount for the log line, deliberately: the diff removed the only prose use, so any
    // occurrence at all is a fresh one. A future author who wants the value for diagnostics should
    // read this and decide consciously rather than have it slip back in as a condition.
    let uses =
      body.components(separatedBy: "PersistentSessionService.shared.isAvailable").count - 1

    XCTAssertEqual(
      uses, 0,
      """
      applyPersistentSession references PersistentSessionService.isAvailable again. That answers \
      for the backend a NEW session would go to, so an unhealthy agent makes it false and strands \
      every session the retired Swift daemon is still holding — the exact case the attach-only \
      client exists to serve. Route per session through attachCommand(forSession:) instead. \
      See docs/designs/remote-workrooms.md.
      """)
  }

  /// The complement: the attach really is routed per session, so the test above is asserting the
  /// absence of a guard from a function that still does the right thing rather than from one that
  /// has stopped attaching altogether.
  ///
  /// Scoped to the body. Searching the whole 2000-line file passed as long as the call appeared
  /// anywhere in it, which is exactly the regression it exists to catch.
  func testTheAttachGuardRoutesPerSession() throws {
    let body = try Self.applyPersistentSessionBody(in: Self.surfaceViewSource)
    XCTAssertTrue(
      body.contains("attachCommand("), "applyPersistentSession no longer resolves an attach command"
    )
    XCTAssertTrue(
      body.contains("forSession:"), "applyPersistentSession no longer routes per session")
  }

  /// The other call site this commit added, and the one with the same blind spot.
  ///
  /// `DaemonSessionSubstitutionTests` drives `confirmBeforeAttach` through the service and proves
  /// the rule; none of it reaches the view. Deleting the call from `applyPersistentSession` leaves
  /// every one of those tests green while restoring the bug in full: a reattach to a session the
  /// v2.0.0 daemon has lost, which it answers by forking a new shell and passing it off as the
  /// user's. Same "cover the wiring, not just the writer" failure this file was written for.
  ///
  /// Order is asserted too. A confirmation made AFTER the attach command is resolved is not a
  /// confirmation — the routing it is supposed to veto has already happened.
  func testTheAttachIsConfirmedWithTheDaemonBeforeItIsRouted() throws {
    let body = try Self.applyPersistentSessionBody(in: Self.surfaceViewSource)

    guard let confirm = body.range(of: "confirmBeforeAttach(sessionID:") else {
      return XCTFail(
        """
        applyPersistentSession no longer asks the daemon whether it still holds this session. The \
        shipped v2.0.0 daemon CREATES a session on attach for an id it does not hold, so a cached \
        ownership answer that has outlived its session turns a reattach into a brand new shell \
        with nothing to mark it as one. See PersistentSessionService.confirmBeforeAttach.
        """)
    }
    XCTAssertTrue(
      body.contains(".gone"),
      "the confirmation's answer is no longer acted on; only `.gone` must stop the attach")

    guard let attach = body.range(of: "attachCommand(") else {
      return XCTFail("applyPersistentSession no longer resolves an attach command")
    }
    XCTAssertTrue(
      confirm.lowerBound < attach.lowerBound,
      """
      the daemon is asked whether it still holds the session AFTER the attach command has been \
      resolved, which vetoes nothing. Confirm first, then route.
      """)
  }

  /// FINDING 1 from the adversarial pass. The availability gate is asked at TWO layers, and pinning
  /// only the view left the other one unpinned — which is the same defect one level up.
  ///
  /// Every test in `TerminalPersistentSessionPolicyTests` calls `usesPersistentSession` directly
  /// with literal arguments, so changing the CALLER to `hasExistingSession: false` restores the
  /// original bug — an unhealthy agent strands every daemon-held terminal — with all eight of them
  /// still green. The argument-passing half is what this commit added, and it needs its own pin.
  func testAssignedSessionIDReportsWhetherTheSessionAlreadyExists() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("WorkroomApp/Core/TerminalSessions.swift")
    let source = try String(contentsOf: url, encoding: .utf8)

    guard let start = source.range(of: "private func assignedSessionID") else {
      throw XCTSkip("assignedSessionID has been renamed; update this test deliberately")
    }
    let rest = source[start.upperBound...]
    let body =
      rest.range(
        of: "\n  (?:private |fileprivate |internal )?(?:static )?func ",
        options: .regularExpression
      ).map { String(rest[rest.startIndex..<$0.lowerBound]) } ?? String(rest)

    XCTAssertTrue(
      body.contains("hasExistingSession: persisted != nil"),
      """
      assignedSessionID no longer tells the policy whether the pane already has a session. Passing \
      a constant there re-strands every session the retired Swift daemon holds whenever the agent \
      is unhealthy, and TerminalPersistentSessionPolicyTests cannot see it: those tests call the \
      policy directly with literals, so they stay green. See docs/designs/remote-workrooms.md.
      """)
  }
}

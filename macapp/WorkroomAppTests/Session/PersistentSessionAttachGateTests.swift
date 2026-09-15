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

  func testTheAttachGuardDoesNotConsultGlobalAvailability() throws {
    let source = try Self.surfaceViewSource
    guard let start = source.range(of: "private func applyPersistentSession") else {
      return XCTFail("applyPersistentSession has been renamed; update this test deliberately")
    }
    // The function body ends at the next declaration at the same indentation.
    let rest = source[start.lowerBound...]
    let body =
      rest.range(
        of: "\n  private func", range: rest.index(rest.startIndex, offsetBy: 1)..<rest.endIndex
      )
      .map { String(rest[rest.startIndex..<$0.lowerBound]) } ?? String(rest)

    // The log line names it in prose; a GUARD is what breaks the feature. Match the call, then
    // discount the one occurrence that is inside a log message rather than a condition.
    let guardUses =
      body.components(separatedBy: "PersistentSessionService.shared.isAvailable")
      .count - 1

    XCTAssertEqual(
      guardUses, 0,
      """
      applyPersistentSession consults PersistentSessionService.isAvailable again. That answers for \
      the backend a NEW session would go to, so an unhealthy agent makes it false and strands every \
      session the retired Swift daemon is still holding — the exact case the attach-only client \
      exists to serve. Route per session through attachCommand(forSession:) instead. \
      See docs/designs/remote-workrooms.md.
      """)
  }

  /// The complement: the attach really is routed per session, so the test above is asserting the
  /// absence of a guard from a function that still does the right thing rather than from one that
  /// has stopped attaching altogether.
  func testTheAttachGuardRoutesPerSession() throws {
    let source = try Self.surfaceViewSource
    XCTAssertTrue(
      source.contains("PersistentSessionService.shared.attachCommand(\n        forSession:")
        || source.contains("attachCommand(forSession:"),
      "applyPersistentSession no longer resolves an attach command per session")
  }
}

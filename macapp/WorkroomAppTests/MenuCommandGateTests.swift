import XCTest

@testable import Workroom

/// Menu items that act on the ORIGIN window must not fire while a popped-out pane holds key
/// (issue #172).
///
/// A detached pane is not a SwiftUI scene, so `@FocusedValue` keeps reporting the last scene's store
/// — every workroom-scoped `Commands` item stays enabled and aimed at a window the user is not
/// looking at. ⇧⌘P is the sharp end (Push against the origin's selected workroom, which can be a
/// different repository entirely), but Back/Forward, Open in Editor, Close Other Tabs and the tab
/// cyclers all move a window that is not in front of the user.
///
/// The fix is `workroomCommandEnabled`, and the failure mode is that it gets applied to *most* items:
/// it shipped on 14 of them and missed 21, which is exactly what a reviewer caught. So this parses
/// the `Commands` source and fails on a bare `<flag> != true`, the shape of an ungated item. Same
/// idiom as `DetachedPaneEnvironmentTests` and
/// `DefaultsIsolationTests.testEveryShippedKeyDeclaresTheAppSuite`: the rule is enforced, not
/// documented and forgotten.
final class MenuCommandGateTests: XCTestCase {
  /// The only flags allowed to gate a menu item WITHOUT the detached check, because they are not
  /// workroom-scoped: `hasProjects` asks whether the app knows about any project at all, which means
  /// the same thing whichever window is key. Adding to this list is how you declare a new item
  /// app-level — deliberately, rather than by a test quietly going green.
  private let appLevelFlags: Set<String> = ["hasProjects"]

  private var source: String {
    get throws {
      let url =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // WorkroomAppTests
        .deletingLastPathComponent()  // macapp
        .appendingPathComponent("WorkroomApp/WorkroomApp.swift")
      return try String(contentsOf: url, encoding: .utf8)
    }
  }

  func testEveryWorkroomScopedMenuItemGatesOnTheDetachedWindow() throws {
    let source = try source

    // `.disabled(` ... up to the end of the line: every gate in this file is written on one line.
    let pattern = try NSRegularExpression(pattern: #"\.disabled\(([^\n]*)\)"#)
    let range = NSRange(source.startIndex..., in: source)
    var gates: [String] = []
    for match in pattern.matches(in: source, range: range) {
      guard let r = Range(match.range(at: 1), in: source) else { continue }
      gates.append(String(source[r]))
    }
    XCTAssertGreaterThan(
      gates.count, 30, "parse looks wrong — the Commands body has more `.disabled(` than this")

    // A `<flag> != true` is a `@FocusedValue` read: it resolves through the origin window's scene, so
    // the item is workroom-scoped by construction.
    let flagPattern = try NSRegularExpression(pattern: #"(\w+)\s*!=\s*true"#)
    var ungated: [String] = []
    for gate in gates {
      let gateRange = NSRange(gate.startIndex..., in: gate)
      for match in flagPattern.matches(in: gate, range: gateRange) {
        guard let r = Range(match.range(at: 1), in: gate) else { continue }
        let flag = String(gate[r])
        if !appLevelFlags.contains(flag) { ungated.append("\(flag) — in `.disabled(\(gate))`") }
      }
    }
    XCTAssertEqual(
      ungated, [],
      """
      these menu items act on the origin window but stay enabled while a popped-out pane is key \
      (issue #172) — wrap the flag in `workroomCommandEnabled(…)`, or add it to `appLevelFlags` \
      here if the command really does mean the same thing in every window:
      \(ungated.joined(separator: "\n"))
      """)

    // Pins the parser: these are known to be gated, so if they stop matching the scan has drifted off
    // the Commands body and the test is guarding nothing.
    for flag in ["vcsCanPush", "canNavigateBack", "hasNotifications"] {
      XCTAssertTrue(
        source.contains("!workroomCommandEnabled(\(flag))"),
        "parser or source regressed — `\(flag)` should be gated")
    }
  }

  /// The gate itself, rather than its call sites: enabled needs BOTH the item's own precondition and
  /// a non-detached key window. Cheap, and it stops the guard test above passing against a
  /// `workroomCommandEnabled` that was quietly reduced to `flag == true`.
  func testTheGateRequiresBothHalves() throws {
    let source = try source
    guard let start = source.range(of: "private func workroomCommandEnabled") else {
      return XCTFail("the gate is gone — every menu item is aimed at the origin window again")
    }
    let body = String(source[start.lowerBound...].prefix(200))
    XCTAssertTrue(
      body.contains("flag == true") && body.contains("!detachedWindowKey"),
      "the gate no longer ANDs the item's precondition with the detached-window check: \(body)")
  }
}

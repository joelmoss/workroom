import XCTest

@testable import Workroom

/// A detached pane's window (issue #172) hosts SwiftUI in a bare `NSHostingView`, and environment
/// objects do NOT cross that boundary — they have to be injected by hand.
///
/// `@EnvironmentObject` traps when it is missing, so the cost of forgetting one is a hard crash, and
/// the crash only fires when the exact view that wants it renders. That is what happened:
/// `TerminalStatusBar` reads `claudeUsageBridge` inside a `TimelineView` closure, so a detached pane
/// ran fine until the agent-usage segment ticked, then took the app down.
///
/// This parses the sources rather than rendering anything, because rendering cannot reach the lazy
/// branches where the misses hide. Same shape as
/// `DefaultsIsolationTests.testEveryShippedKeyDeclaresTheAppSuite`: the rule is enforced, not just
/// documented.
final class DetachedPaneEnvironmentTests: XCTestCase {
  /// The two the pane subtree genuinely cannot reach: `RootView` chrome only (the update pill and the
  /// What's New dialog). If a pane ever needs one, it goes into `detachedPaneEnvironment` and comes
  /// out of here — deliberately, rather than by a test quietly going green.
  private let sceneOnly: Set<String> = ["Updater", "WhatsNewService"]

  /// How each type is supplied, since several arrive through an owner rather than by their own name
  /// (`store.notifications`, `sessions.agentManager`) — matching on the type alone would report those
  /// as missing while they are injected.
  ///
  /// A NEW environment object has no entry here, which fails the test rather than passing silently:
  /// that is the direction that matters, because the alternative is a crash in the field.
  private let supplier: [String: String] = [
    "AppStore": ".environmentObject(store)",
    "NotificationCenterStore": "store.notifications",
    "TerminalSessions": ".environmentObject(sessions)",
    "TerminalAgentManager": "sessions.agentManager",
    "AgentUsageMonitor": "AgentUsageMonitor.shared",
    "ClaudeUsageBridge": "ClaudeUsageBridge.shared",
  ]

  private var macappRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // WorkroomAppTests
      .deletingLastPathComponent()  // macapp
  }

  func testEveryEnvironmentObjectAPaneCanReachIsInjectedIntoDetachedWindows() throws {
    let appRoot = macappRoot.appendingPathComponent("WorkroomApp")
    let files =
      FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter { $0.pathExtension == "swift" } ?? []
    XCTAssertGreaterThan(files.count, 50, "parse looks wrong — the app has more sources than this")

    // `@EnvironmentObject var name: Type` — collect every Type the app declares a dependency on.
    var required: Set<String> = []
    for file in files {
      let source = try String(contentsOf: file, encoding: .utf8)
      for declaration in source.components(separatedBy: "@EnvironmentObject var ").dropFirst() {
        guard let colon = declaration.firstIndex(of: ":") else { continue }
        let type = declaration[declaration.index(after: colon)...]
          .prefix { $0 != "\n" }
          .trimmingCharacters(in: .whitespaces)
        if !type.isEmpty { required.insert(type) }
      }
    }
    XCTAssertTrue(
      required.contains("AppStore") && required.contains("ClaudeUsageBridge"),
      "parse looks wrong — these are known to be declared (found: \(required.sorted()))")

    let injected = try String(
      contentsOf: macappRoot.appendingPathComponent("WorkroomApp/Views/DetachedPaneView.swift"),
      encoding: .utf8)
    // The modifier body: everything between the function and the end of its chain.
    guard let modifier = injected.range(of: "func detachedPaneEnvironment") else {
      return XCTFail("detachedPaneEnvironment is gone — detached windows inject nothing")
    }
    let body = String(injected[modifier.lowerBound...])

    for type in required.subtracting(sceneOnly).sorted() {
      guard let expression = supplier[type] else {
        XCTFail(
          """
          `\(type)` is a new @EnvironmentObject and this test does not know how it is supplied. \
          Inject it in `detachedPaneEnvironment` and add it to `supplier`, or add it to `sceneOnly` \
          if a pane genuinely cannot reach it.
          """)
        continue
      }
      XCTAssertTrue(
        body.contains(expression),
        """
        `\(type)` is an @EnvironmentObject some view reaches, but `detachedPaneEnvironment` does not \
        inject it (expected `\(expression)`). A detached pane that renders that view will TRAP, not \
        degrade.
        """)
    }
  }
}

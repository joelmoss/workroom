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
  /// The ones the pane subtree genuinely cannot reach: `RootView` chrome only (the update pill, the
  /// What's New dialog, the Room menu state, the project list and VCS status the sidebar, tab bar,
  /// inspector and commit sheet read, and the run config the workroom pane's Run button and the delete warnings
  /// read). If a pane ever needs one, it goes into `detachedPaneEnvironment` and comes out of
  /// here — deliberately, rather than by a test quietly going green.
  ///
  /// `AppStore` is among them: the pane views ask their window through the pane host instead
  /// (`testOnlyMainWindowViewsTakeTheStoreFromTheEnvironment` below), and only the main window's
  /// chrome and composition still take the store from the environment.
  private let sceneOnly: Set<String> = [
    "Updater", "WhatsNewService", "RemoteStateModel", "ProjectStore", "VCSStatusService",
    "RunCommands", "AppStore",
  ]

  /// How each type is supplied, since several arrive through an owner rather than by their own name
  /// (`store.notifications`, `sessions.codingAgentManager`) — matching on the type alone would report those
  /// as missing while they are injected.
  ///
  /// A NEW environment object has no entry here, which fails the test rather than passing silently:
  /// that is the direction that matters, because the alternative is a crash in the field.
  private let supplier: [String: String] = [
    "ModalState": "store.modals",
    "RunCommandController": "store.runCommand",
    "WorkroomLifecycle": "store.lifecycle",
    "NotificationCenterStore": "store.notifications",
    "TerminalCodingAgentManager": "sessions.codingAgentManager",
    "CodingAgentUsageMonitor": "CodingAgentUsageMonitor.shared",
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

    // Collect every type the app declares an `@EnvironmentObject` dependency on.
    //
    // A regex, not `components(separatedBy: "@EnvironmentObject var ")`: that split silently misses
    // every `@EnvironmentObject private var` declaration, which is the form six of them use. It
    // passed anyway, purely because the private-var types happened to be a subset of the plain-var
    // ones — so the guarantee this test exists for ("a NEW environment object fails the test") did
    // not hold for the codebase's more common declaration style.
    let pattern = try NSRegularExpression(
      pattern:
        #"@EnvironmentObject\s+(?:private\s+|fileprivate\s+|internal\s+|public\s+)?var\s+\w+\s*:\s*(\w+)"#
    )
    var required: Set<String> = []
    for file in files {
      let source = try String(contentsOf: file, encoding: .utf8)
      let range = NSRange(source.startIndex..., in: source)
      for match in pattern.matches(in: source, range: range) {
        guard let r = Range(match.range(at: 1), in: source) else { continue }
        required.insert(String(source[r]))
      }
    }
    XCTAssertTrue(
      required.contains("AppStore") && required.contains("ClaudeUsageBridge"),
      "parse looks wrong — these are known to be declared (found: \(required.sorted()))")
    // Pins the parser itself: `Updater` is declared ONLY as `@EnvironmentObject private var`, so if
    // this drops out, the private-var blind spot is back and the test is quietly guarding nothing.
    XCTAssertTrue(
      required.contains("Updater"),
      "parser regressed — `Updater` is declared only as `@EnvironmentObject private var`")

    let injected = try String(
      contentsOf: macappRoot.appendingPathComponent(
        "WorkroomApp/Views/Terminal/DetachedPaneView.swift"),
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
    XCTAssertTrue(
      body.contains(".paneHost(store)"),
      "`detachedPaneEnvironment` must inject the pane host: every pane view reads `\\.paneHost`")
  }

  /// The views that may take the store from the environment: the main window's chrome, inspector,
  /// sheets and composition, which neither the Quick Terminal's window nor a detached pane's renders.
  /// Every other view under `Views/` can be in those two windows' trees (the pane views, the content
  /// panes, the coding-agent views, the title bar's controls, the toasts), and those windows inject
  /// no store, so one of them declaring it would crash the app the moment it renders there.
  ///
  /// Adding a type here is a claim that it never renders in those windows: check that first.
  private let mainWindowOnly: Set<String> = [
    // The window root and its composition.
    "RootView", "TargetTerminalDetail", "SidebarColumn", "InspectorColumn", "EdgeRevealSidebar",
    "EdgeRevealSidebars",
    // The title bar accessory and the workroom tab bar.
    "LeadingTitlebarBar", "TrailingTitlebarBar", "WorkroomTabBar", "WorkroomTabChip", "RunControls",
    // The sidebar and activity bar.
    "ProjectSidebar", "SidebarAddProjectButton", "RowRunButton", "ActivityBar",
    "NotificationsBarButton",
    // The inspector and its panels.
    "RightInspector", "DetailsPanel", "InspectorWorkroomHeader", "ChangesPanelAdapter",
    "HistoryPanelAdapter", "FilesPanel", "PullRequestPanel", "ReadyForReviewButton", "MergeButton",
    "VCSToolbar",
    // Sheets the main window presents, and its creation pane.
    "CommitSheet", "HostOptionsPanel", "CreationPaneAdapter",
  ]

  /// Every view under `Views/` asks its window through `\.paneHost` unless it is main-window only, so
  /// the detached and Quick Terminal windows, which inject no store, can render any of them. Scanned
  /// per type, not per file: `TitlebarBars.swift` and `TargetDetailToolbar.swift` hold both chrome
  /// that reads the store and controls the pane title bar uses (`TitlebarDivider`, `OpenInControl`).
  func testOnlyMainWindowViewsTakeTheStoreFromTheEnvironment() throws {
    let views = macappRoot.appendingPathComponent("WorkroomApp/Views")
    let files =
      FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter { $0.pathExtension == "swift" } ?? []
    XCTAssertGreaterThan(files.count, 50, "parse looks wrong — Views has more sources than this")
    var holders: [String: String] = [:]
    for file in files {
      let source = try String(contentsOf: file, encoding: .utf8)
      for type in try Self.typesTakingTheStoreFromTheEnvironment(in: source) {
        holders[type] = file.lastPathComponent
      }
    }
    // Pins the parser: these are known holders, one of them generic and holding a nested type
    // declared before its store, which a "last declaration above" rule would get wrong.
    for known in ["RootView", "EdgeRevealSidebar", "TrailingTitlebarBar", "RunControls"] {
      XCTAssertNotNil(holders[known], "parser regressed — \(known) holds the store")
    }
    for (type, file) in holders.sorted(by: { $0.key < $1.key }) where !mainWindowOnly.contains(type)
    {
      XCTFail(
        """
        `\(type)` (\(file)) takes the store from the environment, but it is not main-window only. \
        The Quick Terminal and detached-pane windows inject no store, so it traps there: read \
        `\\.paneHost` or take values and actions instead.
        """)
    }
  }

  /// The menu bar's popover lists the app-wide notifications with no window or Quick Terminal open,
  /// so it must not borrow a window's store to show them: with none open it would list nothing.
  func testTheMenuBarListsNotificationsWithoutAWindowsStore() throws {
    let source = try String(
      contentsOf: macappRoot.appendingPathComponent(
        "WorkroomApp/Views/AppShell/MenuBarNotificationsView.swift"),
      encoding: .utf8)
    XCTAssertTrue(
      source.contains("ProjectStore.shared") && source.contains("registry.notifications"),
      "parse looks wrong — the popover lists the shared notifications with the shared projects")
    for borrowed in ["quickTerminal?.store", "lastActiveStore"] {
      XCTAssertFalse(
        source.contains(borrowed),
        "MenuBarNotificationsView reads `\(borrowed)`: list the shared notifications instead")
    }
  }

  /// The types in `source` that declare `@EnvironmentObject … : AppStore`, each attributed to the
  /// innermost type whose braces enclose it. Line-based brace counting, with `//` comments dropped:
  /// enough for the app's sources, and a wrong attribution shows up as a failure above.
  static func typesTakingTheStoreFromTheEnvironment(in source: String) throws -> [String] {
    let declaration = try NSRegularExpression(
      pattern:
        #"^\s*(?:(?:private|fileprivate|internal|public|final)\s+)*(?:struct|class|enum|extension)\s+(\w+)"#
    )
    let holder = try NSRegularExpression(
      pattern:
        #"@EnvironmentObject\s+(?:private\s+|fileprivate\s+|internal\s+|public\s+)?var\s+\w+\s*:\s*AppStore\b"#
    )
    var open: [(name: String, depth: Int)] = []
    var depth = 0
    var pending: String?
    var found: [String] = []
    for rawLine in source.components(separatedBy: "\n") {
      let line = rawLine.components(separatedBy: "//").first ?? ""
      let range = NSRange(line.startIndex..., in: line)
      if let match = declaration.firstMatch(in: line, range: range),
        let name = Range(match.range(at: 1), in: line)
      {
        pending = String(line[name])
      }
      if holder.firstMatch(in: line, range: range) != nil, let owner = open.last?.name {
        found.append(owner)
      }
      for character in line {
        if character == "{" {
          depth += 1
          if let name = pending {
            open.append((name, depth))
            pending = nil
          }
        } else if character == "}" {
          while let last = open.last, last.depth >= depth { open.removeLast() }
          depth -= 1
        }
      }
    }
    return found
  }
}

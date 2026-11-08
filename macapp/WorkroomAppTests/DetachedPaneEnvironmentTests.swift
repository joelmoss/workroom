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
  ///
  /// So is `WorkroomLifecycle`: its readers are `RootView`, `TargetTerminalDetail`, the workroom tab
  /// bar (`WorkroomTabBar`) and `ProjectSidebar`, all main-window only (`mainWindowOnly` below).
  private let sceneOnly: Set<String> = [
    "Updater", "WhatsNewService", "RemoteStateModel", "ProjectStore", "VCSStatusService",
    "RunCommands", "AppStore", "WorkroomLifecycle",
  ]

  /// How each type is supplied, since several arrive through an owner rather than by their own name
  /// (`store.notifications`, `panes.codingAgentManager`) — matching on the type alone would report those
  /// as missing while they are injected. One map per window that hosts panes outside the main one.
  ///
  /// A NEW environment object has no entry here, which fails the test rather than passing silently:
  /// that is the direction that matters, because the alternative is a crash in the field.
  private let detachedSupplier: [String: String] = [
    "ModalState": "store.modals",
    "RunCommandController": "store.runCommand",
    "NotificationCenterStore": "store.notifications",
    "TerminalCodingAgentManager": "panes.codingAgentManager",
    "CodingAgentUsageMonitor": "CodingAgentUsageMonitor.shared",
    "ClaudeUsageBridge": "ClaudeUsageBridge.shared",
  ]

  /// The same for the Quick Terminal's window, whose owners are its host's.
  private let quickTerminalSupplier: [String: String] = [
    "ModalState": "host.modals",
    "RunCommandController": "host.runCommand",
    "NotificationCenterStore": "host.notifications",
    "TerminalCodingAgentManager": "host.terminals.codingAgentManager",
    "CodingAgentUsageMonitor": "CodingAgentUsageMonitor.shared",
    "ClaudeUsageBridge": "ClaudeUsageBridge.shared",
  ]

  private var macappRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // WorkroomAppTests
      .deletingLastPathComponent()  // macapp
  }

  func testEveryEnvironmentObjectAPaneCanReachIsInjectedIntoDetachedWindows() throws {
    try assertInjectsEveryEnvironmentObjectAPaneCanReach(
      file: "WorkroomApp/Views/Terminal/DetachedPaneView.swift",
      function: "detachedPaneEnvironment", supplier: detachedSupplier,
      paneHost: ".paneHost(store)")
  }

  /// The Quick Terminal's window renders the same pane views, so it owes them the same.
  func testEveryEnvironmentObjectAPaneCanReachIsInjectedIntoTheQuickTerminal() throws {
    try assertInjectsEveryEnvironmentObjectAPaneCanReach(
      file: "WorkroomApp/Views/Terminal/QuickTerminalContent.swift",
      function: "quickTerminalEnvironment", supplier: quickTerminalSupplier,
      paneHost: ".paneHost(host)")
  }

  /// `function` in `file` (everything from it to the file's end) injects, as its `supplier` entry
  /// names, every environment object a view declares and a pane can reach, and the pane host.
  private func assertInjectsEveryEnvironmentObjectAPaneCanReach(
    file: String, function: String, supplier: [String: String], paneHost: String
  ) throws {
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
      contentsOf: macappRoot.appendingPathComponent(file), encoding: .utf8)
    // The modifier body: everything between the function and the end of its chain.
    guard let modifier = injected.range(of: "func \(function)") else {
      return XCTFail("\(function) is gone — its window injects nothing")
    }
    let body = String(injected[modifier.lowerBound...])

    for type in required.subtracting(sceneOnly).sorted() {
      guard let expression = supplier[type] else {
        XCTFail(
          """
          `\(type)` is a new @EnvironmentObject and this test does not know how it is supplied. \
          Inject it in `\(function)` and add it to its supplier map, or add it to `sceneOnly` \
          if a pane genuinely cannot reach it.
          """)
        continue
      }
      XCTAssertTrue(
        body.contains(expression),
        """
        `\(type)` is an @EnvironmentObject some view reaches, but `\(function)` does not \
        inject it (expected `\(expression)`). A pane there that renders that view will TRAP, not \
        degrade.
        """)
    }
    XCTAssertTrue(
      body.contains(paneHost),
      "`\(function)` must inject the pane host: every pane view reads `\\.paneHost`")
  }

  /// The Quick Terminal's panes are hosted by its `QuickTerminalHost`, not a window's store, so its
  /// files build no store and keep none: a store built there would bring fresh owners of its own,
  /// whose project lookups never see the app's projects. A `windows: [AppStore]` destination is the
  /// windows its panes move into, and allowed.
  func testTheQuickTerminalBuildsNoStore() throws {
    let construction = try NSRegularExpression(pattern: #"\bAppStore\s*\("#)
    let stored = try NSRegularExpression(
      pattern:
        #"\b(?:var|let)\s+\w+\s*:\s*(?:AppStore|Optional<AppStore>|AppStore\?|AppStore!)(?![\w\]])"#
    )
    let files = [
      "WorkroomApp/Core/AppShell/QuickTerminalController.swift",
      "WorkroomApp/Core/AppShell/QuickTerminalHost.swift",
      "WorkroomApp/Views/Terminal/QuickTerminalContent.swift",
      "WorkroomApp/Views/Terminal/QuickTerminalDragHandle.swift",
    ]
    for file in files {
      let source = try String(
        contentsOf: macappRoot.appendingPathComponent(file), encoding: .utf8)
      // Comments may name the store; only code counts.
      let code = Self.code(in: source)
      let range = NSRange(code.startIndex..., in: code)
      XCTAssertNil(
        construction.firstMatch(in: code, range: range), "\(file) builds an AppStore")
      XCTAssertNil(stored.firstMatch(in: code, range: range), "\(file) keeps an AppStore")
    }
    // Pins the patterns: they catch what they exist to catch, and let the destination parameter by.
    let built = "let store = AppStore(notifications: list)"
    let kept = "  private(set) var store: AppStore?"
    let destination = "windows: [AppStore] = WindowRegistry.shared.allStores"
    XCTAssertNotNil(
      construction.firstMatch(in: built, range: NSRange(built.startIndex..., in: built)))
    XCTAssertNotNil(stored.firstMatch(in: kept, range: NSRange(kept.startIndex..., in: kept)))
    XCTAssertNil(
      stored.firstMatch(
        in: destination, range: NSRange(destination.startIndex..., in: destination)))
  }

  /// Pins the comment scan the source guards here read through: a `//` or `/*` inside a string
  /// literal (a URL) hides none of the code after it, and real comments still go.
  func testTheCommentScanKeepsCodeAfterASlashInAString() throws {
    let source = """
      let url = "https://example.com/*"; let built = AppStore(notifications: list)
      let quote = "a \\" // still a string"; let kept = AppStore()
      // let commented = AppStore()
      let inline = 1 /* AppStore() */ + 2 // AppStore()
      """
    let code = Self.code(in: source)
    let construction = try NSRegularExpression(pattern: #"\bAppStore\s*\("#)
    let found = construction.matches(in: code, range: NSRange(code.startIndex..., in: code))
    XCTAssertEqual(found.count, 2, "the two after a string, neither in a comment: \(code)")
    XCTAssertTrue(code.contains(#""https://example.com/*""#), "the string is kept whole")
    XCTAssertTrue(code.contains(#""a \" // still a string""#), "an escaped quote ends nothing")
    XCTAssertTrue(code.contains("let inline = 1  + 2"), "code around a block comment is kept")
    XCTAssertFalse(code.contains("commented"), "a line comment goes")
  }

  /// `source` without its `//` and `/* */` comments, keeping every string literal whole, so a
  /// comment marker inside one (a URL) is not taken for a comment. Knows `"…"` literals and their
  /// escapes; a `"""` literal reads as an empty one, then its body as a literal, so it stays whole.
  private static func code(in source: String) -> String {
    let characters = Array(source)
    var code = ""
    var index = 0
    func next(is text: String) -> Bool {
      let marker = Array(text)
      return index + marker.count <= characters.count
        && Array(characters[index..<index + marker.count]) == marker
    }
    while index < characters.count {
      if next(is: "//") {
        while index < characters.count, characters[index] != "\n" { index += 1 }
      } else if next(is: "/*") {
        index += 2
        while index < characters.count, !next(is: "*/") { index += 1 }
        index += 2
      } else if characters[index] == "\"" {
        // The literal, up to its closing quote; an escape keeps the character after it.
        repeat {
          if characters[index] == "\\", index + 1 < characters.count {
            code.append(characters[index])
            index += 1
          }
          code.append(characters[index])
          index += 1
        } while index < characters.count && characters[index] != "\""
        if index < characters.count {
          code.append(characters[index])
          index += 1
        }
      } else {
        code.append(characters[index])
        index += 1
      }
    }
    return code
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
    // The workroom menu of the tab chip, split title bar, sidebar row and inspector header.
    "WorkroomMenuAdapter",
    // The sidebar and activity bar.
    "ProjectSidebar", "SidebarAddProjectButton", "RowRunButton", "RowRunToggle", "ActivityBar",
    "NotificationsBarButton",
    // The sidebar's row adapters, terminal subtrees and row menus.
    "SidebarProjectRowAdapter", "SidebarRootRowAdapter", "SidebarWorkroomRowAdapter",
    "SidebarTerminalRowAdapter", "SidebarTerminalSubtree", "SidebarProjectMenu", "SidebarRunMenu",
    "SidebarTerminalMenu", "NewWorkroomPlacesMenu",
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
  /// innermost type whose braces enclose it. Line-based brace counting over `code(in:)`: enough for
  /// the app's sources, and a wrong attribution shows up as a failure above.
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
    for line in Self.code(in: source).components(separatedBy: "\n") {
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

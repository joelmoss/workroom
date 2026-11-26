import XCTest

/// A standalone terminal's inspector follows its shell's folder (#803), end to end in the real
/// window: `cd` into a repository and the header names the repository, its branch and its path,
/// and Files' breadcrumb runs from the repository's root to the folder; `cd` out of it and Files
/// lists the plain folder while Changes says it is not a git repository.
///
/// The repository is made by the terminal's own shell under a fresh `mktemp -d`, so nothing of the
/// developer's (projects, config, git identity) is read or written: the commit passes its identity
/// with `-c`. Every step waits for the status bar's live cwd (OSC 7, as `StatusBarCwdUITests`
/// does) before it looks at the inspector, which follows that same cwd.
///
/// Rendered `Text`s in the inspector expose empty accessibility labels, so the assertions read the
/// header's, breadcrumb's, rows' and message's identifiers and the labels set on them.
final class FollowedFolderInspectorUITests: XCTestCase {
  private var app: XCUIApplication!

  /// The fixture's first standalone terminal (`UITestFixture.standaloneTerminalIDs`).
  private let standalone = "standalone:00000000-0000-0000-0000-000000000651"

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    app?.terminate()
    super.tearDown()
  }

  private func launchedApp(extraArgs: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestStandaloneTerminals", "1"]
    app.launchArguments += extraArgs
    app.launchArguments += ["-WorkroomUITestNoRunCommand", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    return app
  }

  private func element(_ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// The first element whose identifier starts with `prefix` and ends with `suffix`.
  private func element(prefix: String, suffix: String) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", prefix, suffix)
    ).firstMatch
  }

  private func poll(timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return condition()
  }

  /// Types `line` and presses Return in its own call (see `GhosttyOrphanShellUITests.run`).
  private func run(_ line: String) {
    app.typeText(line)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    app.typeText("\r")
  }

  /// The status bar's live cwd: its label is `Working directory <absolute path>`.
  private var liveCwd: String {
    let cwd = element("terminal.statusBar.cwd")
    guard cwd.exists else { return "" }
    return String(cwd.label.dropFirst("Working directory ".count))
  }

  /// Waits until the shell reports a cwd ending in `suffix`, and returns it.
  private func waitForCwd(endingWith suffix: String) -> String {
    XCTAssertTrue(
      poll(timeout: 30) { self.liveCwd.hasSuffix(suffix) },
      "the shell's live cwd never reached …\(suffix) (last: \(liveCwd))")
    return liveCwd
  }

  private func waitForLabel(_ element: XCUIElement, _ test: @escaping (String) -> Bool) -> String {
    _ = poll { element.exists && test(element.label) }
    return element.exists ? element.label : "<missing>"
  }

  /// Shows section `raw` in the inspector. The app launches with whatever section and open state
  /// the shared Dev defaults hold, and clicking the active section's icon toggles its pane, so a
  /// click that leaves the pane closed is followed by one more, which opens it.
  private func showSection(_ raw: String, header: String) {
    let shown = element("inspector.header.\(header)")
    for _ in 0..<2 where !shown.exists {
      element("activitySection.\(raw)").click()
      if shown.waitForExistence(timeout: 3) { break }
    }
    XCTAssertTrue(shown.waitForExistence(timeout: 10), "\(header) shows")
  }

  /// Expands section `title` when its header says it is collapsed (the Dev defaults keep it).
  private func expand(_ title: String) {
    let header = element("inspector.header.\(title)")
    XCTAssertTrue(header.waitForExistence(timeout: 10), "\(title)'s header")
    if header.label.contains(", collapsed") { header.click() }
    XCTAssertTrue(
      poll(timeout: 5) { !header.label.contains(", collapsed") }, "\(title) is expanded")
  }

  func testTheInspectorFollowsAStandaloneTerminalIntoARepositoryAndOutOfIt() {
    app = launchedApp()

    let row = element("sidebar.open.workroom.\(standalone)")
    XCTAssertTrue(row.waitForExistence(timeout: 20), "the fixture's standalone terminal")
    row.click()
    XCTAssertTrue(poll { self.element("workroom.tab.\(self.standalone)").isSelected })
    XCTAssertTrue(
      element("terminal.statusBar.cwd").waitForExistence(timeout: 30),
      "the terminal's shell reports its folder")
    XCTAssertTrue(element("activitySection.files").waitForExistence(timeout: 10))
    showSection("files", header: "Files")

    // A repository on its own branch, with a committed file in `src`, and a plain file beside it
    // in the (non-repository) temp folder above.
    run(
      "d=$(mktemp -d) && mkdir -p \"$d/wr811-repo/src\" && echo hi > \"$d/wr811-repo/src/hello.txt\""
        + " && echo n > \"$d/notes.txt\" && cd \"$d/wr811-repo\" && git init -q -b wr811-branch"
        + " && git add -A && git -c user.name=WR -c user.email=wr@example.invalid"
        + " -c commit.gpgsign=false commit -qm 'wr811 first commit'"
        + " && echo edited > src/hello.txt && cd src")
    let src = waitForCwd(endingWith: "/wr811-repo/src")
    let repo = (src as NSString).deletingLastPathComponent

    // The header: the repository's name, its branch and its path.
    let header = element("inspector.workroomHeader")
    let said = waitForLabel(header) { $0.hasPrefix("Following repository") }
    XCTAssertTrue(
      said.hasPrefix("Following repository wr811-repo, on wr811-branch, at "),
      "the header names the repository and its branch, got: \(said)")
    // The path is the shell's spelling, `~`-abbreviated when under home (a temp folder isn't).
    let shown = said.components(separatedBy: " at ").last ?? ""
    XCTAssertTrue(
      shown == repo || (shown.hasPrefix("~/") && repo.hasSuffix(shown.dropFirst())),
      "the header shows the repository's path \(repo), got: \(said)")

    // Files' breadcrumb: the repository's root, then the terminal's folder, which Files shows.
    XCTAssertTrue(element("files.breadcrumb").waitForExistence(timeout: 10), "the breadcrumb")
    let base = element("files.breadcrumb.0")
    let leaf = element("files.breadcrumb.1")
    XCTAssertEqual(waitForLabel(base) { $0 == "wr811-repo" }, "wr811-repo", "based at the root")
    XCTAssertEqual(waitForLabel(leaf) { $0 == "src" }, "src", "ending at the terminal's folder")
    XCTAssertEqual(leaf.value as? String, "the terminal's folder, shown in Files")
    XCTAssertFalse(element("files.breadcrumb.2").exists, "nothing past the terminal's folder")
    XCTAssertTrue(
      element(prefix: "files.file.", suffix: "hello.txt").waitForExistence(timeout: 10),
      "Files lists the folder's file")

    // Changes lists the repository's own edit, and History its own commit, read for real (the
    // fixture's seeded statuses and canned history are for its workrooms only).
    showSection("changes", header: "Changes")
    expand("Changes")
    XCTAssertTrue(
      element("changes.file.src/hello.txt").waitForExistence(timeout: 20),
      "Changes lists the repository's modified file")
    expand("History")
    let rows = app.descendants(matching: .any).matching(identifier: "HistoryRow")
    let ours = rows.matching(NSPredicate(format: "label ENDSWITH %@", ", wr811 first commit"))
    XCTAssertTrue(ours.firstMatch.waitForExistence(timeout: 20), "History shows the repo's commit")
    XCTAssertFalse(
      rows.matching(NSPredicate(format: "label CONTAINS %@", "Fixture commit")).firstMatch.exists,
      "and not the fixture's canned commits")
    // The branch bar names the repository's branch, read for real as a workroom's is, and its
    // sync cell reads the repository rather than saying there is none (QA round 2).
    let branch = element("vcs.toolbar.branch")
    let named = waitForLabel(branch) { $0.hasSuffix(": wr811-branch") }
    XCTAssertTrue(named.hasSuffix(": wr811-branch"), "the branch bar's branch, got: \(named)")
    let sync = element("vcs.toolbar.sync")
    XCTAssertTrue(sync.waitForExistence(timeout: 10), "the sync cell")
    XCTAssertTrue(
      poll(timeout: 10) { !sync.label.contains("No repository") && !sync.label.isEmpty },
      "the sync cell reads the repository, got: \(sync.label)")
    showSection("files", header: "Files")

    // Out of the repository: Files lists the plain folder, and Changes says it isn't a repository.
    run("cd \"$d\"")
    let plain = waitForCwd(endingWith: (repo as NSString).deletingLastPathComponent)
    XCTAssertFalse(plain.hasSuffix("/wr811-repo"))
    let left = waitForLabel(header) { $0.hasPrefix("Following folder") }
    XCTAssertTrue(
      left.hasPrefix("Following folder ") && left.contains("not a git repository"),
      "the header follows the plain folder, got: \(left)")
    XCTAssertTrue(
      element(prefix: "files.file.", suffix: "notes.txt").waitForExistence(timeout: 10),
      "Files lists the plain folder")
    XCTAssertTrue(
      element(prefix: "files.dir.", suffix: "wr811-repo").exists,
      "with the repository's folder in it")

    showSection("changes", header: "Changes")
    // History and Pull Request say it too, under their own headers: the one that counts is in
    // Changes, between its header and History's.
    let messages = app.descendants(matching: .any).matching(identifier: "inspector.notARepository")
    let inChanges = { () -> XCUIElement? in
      let changesTop = self.element("inspector.header.Changes").frame.maxY
      let historyTop = self.element("inspector.header.History").frame.minY
      return messages.allElementsBoundByIndex.first {
        $0.frame.minY >= changesTop && $0.frame.maxY <= historyTop
      }
    }
    XCTAssertTrue(poll(timeout: 10) { inChanges() != nil }, "Changes says it's not a repository")
    let message = inChanges()?.label ?? ""
    XCTAssertTrue(
      message.hasPrefix("Not a git repository"),
      "Changes says \"Not a git repository\", got: \(message)")
  }

  /// A slow repository lookup (`-WorkroomUITestFollowedLookupDelay`): on the terminal's first
  /// folder, which shows at once with its repository pending, the sections show their loader once
  /// it has been pending a moment, and it gives way to the folder's content when the answer lands.
  /// (A `cd` keeps the last folder showing until the new one resolves, so only a first visit has a
  /// pending repository to show a loader for.)
  func testASlowRepositoryLookupShowsTheLoaderThenTheContent() {
    app = launchedApp(extraArgs: ["-WorkroomUITestFollowedLookupDelay", "5"])

    // Files open on the fixture's workroom first, so the terminal's first folder lands in it.
    XCTAssertTrue(element("activitySection.files").waitForExistence(timeout: 20))
    showSection("files", header: "Files")
    let loader = element("inspector.pendingRepository")
    XCTAssertFalse(loader.exists, "a workroom has no followed folder to wait on")

    let row = element("sidebar.open.workroom.\(standalone)")
    XCTAssertTrue(row.waitForExistence(timeout: 20), "the fixture's standalone terminal")
    row.click()
    let clicked = Date()
    XCTAssertTrue(
      loader.waitForExistence(timeout: 5),
      "Files shows its loader while the folder's repository is looked up")
    XCTAssertEqual(loader.label, "Listing files", "the Files section's own loader")
    XCTAssertTrue(element("workroom.tab.\(standalone)").isSelected, "the terminal is selected")

    let header = element("inspector.workroomHeader")
    XCTAssertTrue(
      poll(timeout: 20) { !loader.exists }, "the loader gives way once the 5 s lookup lands")
    // A lower bound only, which a slow runner can't break: the loader held for the lookup.
    let held = Date().timeIntervalSince(clicked)
    XCTAssertGreaterThan(held, 4, "the loader waits out the injected delay, gone after \(held) s")
    let said = waitForLabel(header) { $0.hasPrefix("Following ") }
    XCTAssertTrue(said.hasPrefix("Following "), "the header follows the folder, got: \(said)")
    let listed = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "files.file.", "files.dir.")
    ).firstMatch
    XCTAssertTrue(listed.waitForExistence(timeout: 10), "Files lists the terminal's folder")
    XCTAssertFalse(loader.exists, "and the loader is gone")
  }

  /// A window with no projects, only a terminal: its activity bar shows Details, Changes and Files
  /// as a workroom's does, a click opens the inspector, and View ▸ Inspector is enabled (#803).
  /// Before the terminal opens, with nothing selected, the rail has no panes and the item is off.
  func testAWindowWithOnlyATerminalCanOpenItsInspector() {
    app = launchedApp(extraArgs: [
      "-WorkroomUITestNoProjects", "1", "-WorkroomUITestOnboarding", "hide",
    ])

    let newTerminal = element("EmptyStateNewTerminal")
    XCTAssertTrue(newTerminal.waitForExistence(timeout: 20), "the no-projects empty state")
    XCTAssertTrue(element("activityBar.settings").waitForExistence(timeout: 10), "the rail")
    XCTAssertFalse(element("activitySection.files").exists, "nothing selected: no panes")
    let view = app.menuBars.menuBarItems["View"]
    view.click()
    // View ▸ Inspector is a submenu: it opens on hover.
    view.menuItems["Inspector"].hover()
    let showInspector = view.menuItems["Show Inspector"]
    XCTAssertTrue(showInspector.waitForExistence(timeout: 5), "View ▸ Inspector ▸ Show Inspector")
    XCTAssertFalse(showInspector.isEnabled, "nothing selected to inspect")
    app.typeKey(.escape, modifierFlags: [])
    app.typeKey(.escape, modifierFlags: [])

    newTerminal.click()
    XCTAssertTrue(
      element("terminal.statusBar.cwd").waitForExistence(timeout: 30),
      "the new terminal's shell reports its folder")
    for raw in ["details", "changes", "files"] {
      XCTAssertTrue(
        element("activitySection.\(raw)").waitForExistence(timeout: 10),
        "the rail shows \(raw) for a terminal with no project")
    }
    showSection("files", header: "Files")

    view.click()
    view.menuItems["Inspector"].hover()
    for title in ["Show Inspector", "Details", "Changes", "History", "Pull Request", "Files"] {
      XCTAssertTrue(
        view.menuItems[title].waitForExistence(timeout: 5), "View ▸ Inspector ▸ \(title)")
      XCTAssertTrue(
        view.menuItems[title].isEnabled, "View ▸ Inspector ▸ \(title) is enabled for the terminal")
    }
    app.typeKey(.escape, modifierFlags: [])
    app.typeKey(.escape, modifierFlags: [])
  }
}

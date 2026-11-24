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

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestStandaloneTerminals", "1"]
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

  func testTheInspectorFollowsAStandaloneTerminalIntoARepositoryAndOutOfIt() {
    app = launchedApp()

    let row = element("sidebar.standalone.\(standalone)")
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
        + " -c commit.gpgsign=false commit -qm init && cd src")
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
}

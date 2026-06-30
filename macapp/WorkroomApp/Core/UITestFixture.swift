import Foundation

/// UI-testing fixture seam (issue #3 UI tests). When the app is launched with
/// `-WorkroomUITestFixture 1`, `AppStore` loads this deterministic set of fake projects and
/// workrooms instead of reading the developer's real `~/.config/workroom`. The XCUITests
/// (`WorkroomAppUITests`) pass that flag so they're hermetic — they never touch real projects,
/// never depend on what happens to be configured on the machine, and run the same everywhere.
///
/// The fixture targets point at freshly-created temp directories so their terminals still spawn a
/// real login shell (libghostty needs a valid working directory) — the surface mounts and appears
/// in the accessibility tree exactly as it would for a real workroom, which is what the split-pane
/// tests assert on. The app remains a normal app: a regular user never passes the flag, so this
/// code is inert in production.
enum UITestFixture {
  /// The launch-argument / `UserDefaults` key the tests set (highest-priority argument domain).
  static let defaultsKey = "WorkroomUITestFixture"

  /// Whether the app was launched in UI-test fixture mode.
  static var isActive: Bool {
    UserDefaults.standard.bool(forKey: defaultsKey)
  }

  /// When set (`-WorkroomUITestNoProjects 1`), the fixture loads an EMPTY project list — the
  /// fresh-install / nothing-configured state. Used by `NewWorkroomDialogUITests` to assert File ▸
  /// New Workroom is disabled when there's nothing to pick (issue #81 D3).
  static var noProjects: Bool {
    UserDefaults.standard.bool(forKey: "WorkroomUITestNoProjects")
  }

  /// When set (`-WorkroomUITestManyChanges 1`), the fixture workroom reports a long changed-file
  /// list so the Changes section overflows and fills the inspector — the scenario in which the
  /// inspector's section-disclosure animation misbehaves (the header title swims relative to its
  /// bar). Used by `InspectorAnimationUITests`.
  static var manyChanges: Bool {
    UserDefaults.standard.bool(forKey: "WorkroomUITestManyChanges")
  }

  /// When set (`-WorkroomUITestRunCommand "<cmd>"`), the fixture seeds this as the workroom's run
  /// command instead of the default probe — so the run-status XCUITests (issue #79) can drive a
  /// deterministic failure (`exit 7`), success (`exit 0`), or long-running (`sleep 30`) command and
  /// assert the run icon / Ctrl-C behaviour end-to-end against a real libghostty surface.
  static var runCommand: String? {
    let cmd = UserDefaults.standard.string(forKey: "WorkroomUITestRunCommand")
    return (cmd?.isEmpty == false) ? cmd : nil
  }

  /// When set (`-WorkroomUITestTwoTabs 1`), the fixture seeds a SECOND workroom and the app opens a
  /// terminal for both on launch, so the workroom tab bar (issue #23) shows two chips — the scenario
  /// the drag-to-reorder / window-drag XCUITest (`WindowDragUITests`) needs. Default (unset) keeps the
  /// single-workroom fixture the other tests rely on.
  static var twoTabs: Bool {
    UserDefaults.standard.bool(forKey: "WorkroomUITestTwoTabs")
  }

  /// When set (`-WorkroomUITestGitWorkroom 1`), the fixture workroom reports a **git** working tree
  /// (a flat changed-file list, no jj groups) instead of the default jj change — so the diff-viewer
  /// UI tests can exercise the `.gitWorktree` diff source. Default (unset) keeps the jj scenario the
  /// other tests rely on.
  static var gitWorkroomMode: Bool {
    UserDefaults.standard.bool(forKey: "WorkroomUITestGitWorkroom")
  }

  /// When set (`-WorkroomUITestAgentStub 1`), the inline terminal agent (issue #49) is enabled with
  /// a STUB backend that returns a canned diagnosis — so the XCUITest exercises the REAL capture +
  /// banner end-to-end (failure → `readCommandRegion`/`readFullSurface` → classify → manager →
  /// parse → banner render) with no network and no cost. Pairs with auto-diagnose so no click is
  /// needed to surface the banner.
  static var agentStub: Bool {
    UserDefaults.standard.bool(forKey: "WorkroomUITestAgentStub")
  }

  /// The canned claude `--output-format json` envelope the stub agent returns. Its inner JSON is the
  /// compact diagnosis the XCUITest asserts on (a recognisable `UITEST` summary + a safe fix).
  static let agentStubEnvelope: String = {
    let inner =
      #"{\"summary\":\"UITEST diagnosis: port already in use\",\"fix\":\"kill $(lsof -ti:3000)\"}"#
    return #"{"type":"result","is_error":false,"result":"\#(inner)"}"#
  }()

  /// The summary text the stub produces — queried by the XCUITest as the banner's headline.
  static let agentStubSummary = "UITEST diagnosis: port already in use"

  /// When set (`-WorkroomUITestUpdateAvailable 1`), `Updater` seeds a fake available-update version so
  /// the toolbar "Update" pill renders for visual QA without a live Sparkle update.
  static var updateAvailableVersion: String? {
    UserDefaults.standard.bool(forKey: "WorkroomUITestUpdateAvailable") ? "9.9.9" : nil
  }

  /// When set (`-WorkroomUITestWhatsNew 1`), `WhatsNewService.checkOnLaunch` returns `whatsNewNotes`
  /// so the What's-New dialog renders for visual QA without hitting GitHub.
  static var forceWhatsNew: Bool {
    UserDefaults.standard.bool(forKey: "WorkroomUITestWhatsNew")
  }

  /// Canned release notes for the What's-New dialog under `forceWhatsNew` — a couple of versions with
  /// headings + bullets so the markdown renderer and the multi-release layout both get coverage.
  static var whatsNewNotes: [ReleaseNote] {
    [
      ReleaseNote(
        version: "9.9.9", title: "Workroom 9.9.9",
        bodyMarkdown: """
          ## Highlights
          - Bell opens the **oldest** notification first
          - Quick Terminal gained a `⌥§` shortcut

          A short framing paragraph about this release.
          """,
        date: Date(timeIntervalSince1970: 1_700_000_000),
        url: URL(string: "https://github.com/joelmoss/workroom/releases/tag/v9.9.9")),
      ReleaseNote(
        version: "9.9.8", title: "Workroom 9.9.8",
        bodyMarkdown: "### Fixes\n- Stop the *exited with code 15* dialog on wake from sleep",
        date: Date(timeIntervalSince1970: 1_699_000_000),
        url: URL(string: "https://github.com/joelmoss/workroom/releases/tag/v9.9.8")),
    ]
  }

  /// Stable display name of the fixture project (also its sidebar accessibility id suffix:
  /// `sidebar.project.<name>`). Deliberately obvious so it never reads as a real project in logs.
  static let projectName = "UITestProject"
  /// Stable name of the fixture workroom (`sidebar.workroom.<name>`).
  static let workroomName = "uitest-room"
  /// Stable name of the SECOND fixture workroom, seeded only under `twoTabs` (drag/reorder test).
  static let workroomName2 = "uitest-room-2"

  /// The fake project list. Idempotent within a launch: the backing temp directories are created if
  /// missing so each target's terminal can start a shell. The project is reported as `git` so the
  /// sidebar's root row renders normally; no real VCS call is ever made (loading is short-circuited
  /// in `AppStore`, which also skips branch resolution for these paths).
  static func projects() -> [Project] {
    // Empty list for the no-projects scenario (issue #81 D3) — nothing to create or select.
    if noProjects { return [] }
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("workroom-uitest", isDirectory: true)
    let projectDir = base.appendingPathComponent(projectName, isDirectory: true)
    let workroomsBase = base.appendingPathComponent("workrooms", isDirectory: true)
    let workroomDir = workroomsBase.appendingPathComponent(workroomName, isDirectory: true)
    // A second workroom only for the drag/reorder scenario, so the tab bar has two chips to swap.
    let workroomDir2 = workroomsBase.appendingPathComponent(workroomName2, isDirectory: true)
    var dirs = [projectDir, workroomDir]
    var workrooms = [
      Workroom(name: workroomName, path: workroomDir.path, vcsName: "git", warnings: [])
    ]
    if twoTabs {
      dirs.append(workroomDir2)
      workrooms.append(
        Workroom(name: workroomName2, path: workroomDir2.path, vcsName: "git", warnings: []))
    }
    for dir in dirs {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return [Project(path: projectDir.path, vcs: "git", workrooms: workrooms)]
  }

  // MARK: - Changes-inspector status

  /// Deterministic VCS status for the fixture **workroom** (`uitest-room`): a dirty jj change with a
  /// description, bookmark, and a mix of root-level and nested changed files. Lets the Changes
  /// inspector render its jj-log header and the filename / dimmed-directory file list with no real
  /// repo — visual QA never has to touch (or expose) the developer's actual projects.
  static var workroomStatus: WorkroomStatus {
    gitWorkroomMode ? gitWorkroomStatus : jjWorkroomStatus
  }

  /// The git variant of the fixture workroom (`-WorkroomUITestGitWorkroom 1`): a dirty git working
  /// tree with a flat changed-file list and no jj groups, so the Changes panel renders the git path
  /// and its rows open `.gitWorktree` diffs.
  static var gitWorkroomStatus: WorkroomStatus {
    WorkroomStatus(
      dirty: true, changedFiles: changedFiles, insertions: 411, deletions: 222, ci: .passing,
      branchForCI: "feature/login",
      lastChecked: Self.checkedAt, ciCheckedAt: Self.checkedAt, prCheckedAt: Self.checkedAt)
  }

  private static var jjWorkroomStatus: WorkroomStatus {
    WorkroomStatus(
      dirty: true,
      changedFiles: changedFiles,
      insertions: 411, deletions: 222,
      ci: .passing,
      jjWorkingCopy: JJCommitChanges(
        changeID: "pw", commitID: "7d74470b", refs: ["feature/login"],
        description: "feat: add session login (#42)", files: changedFiles),
      jjParent: .changes(
        JJCommitChanges(
          changeID: "qz", commitID: "a1b2c3d4", refs: [],
          description: "refactor: extract auth service", files: parentChangedFiles)),
      // The many-changes repro scenario pairs a tall Changes list with an empty Pull Request and
      // Notifications (the exact configuration the disclosure-animation glitch was reported in).
      pr: manyChanges
        ? nil
        : PullRequestInfo(
          number: 42, title: "Add session login", state: .open, isDraft: false,
          url: "https://github.com/acme/app/pull/42", reviewDecision: .changesRequested,
          // A spread of reviewer states so the panel renders the aggregate header + every row kind:
          // a bot still generating (pending → no link), and two submitted reviews (approval +
          // changes-requested) that carry permalinks so the rows render as open-on-GitHub links.
          reviewers: [
            Reviewer(identity: .user(login: "copilot-pull-request-reviewer"), state: .requested),
            Reviewer(
              identity: .user(login: "iainad"), state: .approved,
              url: "https://github.com/acme/app/pull/42#pullrequestreview-1001"),
            Reviewer(
              identity: .user(login: "octocat"), state: .changesRequested,
              url: "https://github.com/acme/app/pull/42#pullrequestreview-1002"),
          ]),
      // All three "checked" stamps set so the inspector shows the seeded data, not "Checking…".
      lastChecked: Self.checkedAt, ciCheckedAt: Self.checkedAt, prCheckedAt: Self.checkedAt)
  }

  /// Deterministic status for the fixture **project root**: a clean git branch that's one commit
  /// ahead of upstream with passing CI — so the inspector renders the git header, the sync line,
  /// and the clean empty state.
  static var rootStatus: WorkroomStatus {
    WorkroomStatus(
      dirty: false, ahead: 1, behind: 0, changedFiles: [], ci: .passing,
      branchForCI: "main",
      // No PR seeded here, so a `prCheckedAt` stamp makes the inspector show the "No pull request"
      // empty state (not "Checking…").
      lastChecked: Self.checkedAt, ciCheckedAt: Self.checkedAt, prCheckedAt: Self.checkedAt)
  }

  // MARK: - Notifications

  /// A deterministic notification history for the inspector's Notifications panel. The fixture
  /// otherwise leaves it empty (real entries only arrive when a terminal emits an OSC notification),
  /// so this seeds a representative spread — a coalesced ×N entry, a wrapping two-line body, a
  /// title-only entry, and a body-only (titleless) one — across a range of ages so the panel, every
  /// row variant, and the "time ago" line all get visual + UI-test coverage.
  ///
  /// Each entry carries a *synthetic* tab id, NOT the workroom's live tab: real notifications are
  /// raised for terminals you're NOT looking at, and the app dismisses the visible tab's history on
  /// focus (`dismissFocusedTerminalNotifications`) — keying these to the live tab would wipe them the
  /// instant the window activates. They keep the real `targetID`, so a row click still routes to the
  /// workroom (and dismisses by `notifID`); it just can't re-focus a tab that was never opened —
  /// exactly the graceful path a since-closed terminal already takes.
  static func notifications(targetID: TerminalTarget.ID) -> [WorkroomNotification] {
    let source = "\(projectName) / \(workroomName)"
    func note(_ ago: TimeInterval, _ title: String, _ body: String? = nil, count: Int = 1)
      -> WorkroomNotification
    {
      WorkroomNotification(
        id: UUID(), targetID: targetID, tabID: UUID(), kind: .osc, source: source,
        title: title, body: body, date: Date().addingTimeInterval(-ago), count: count)
    }
    // Oldest first: the store appends chronologically and the panel reverses to newest-first, so the
    // most recent ("Build finished", just now) lands at the top.
    return [
      note(3600, "Tests passed", "All 248 specs green", count: 3),
      note(
        900, "Deploy blocked",
        "Branch protection: 1 required review still missing before this can merge to main."),
      note(120, "", "Background indexing finished"),
      note(45, "Lint clean"),
      note(2, "Build finished", "Workroom Dev compiled in 12.4s"),
    ]
  }

  /// The fixture's changed-file list: a small representative set, or a long one (`manyChanges`) so
  /// the Changes section overflows the inspector for the disclosure-animation repro.
  private static var changedFiles: [ChangedFile] {
    let base = [
      ChangedFile(path: "Gemfile", change: .modified),
      ChangedFile(path: ".env.example", change: .added),
      ChangedFile(path: "app/models/user.rb", change: .modified),
      ChangedFile(path: "app/controllers/sessions_controller.rb", change: .added),
      ChangedFile(path: "config/routes.rb", change: .modified),
      ChangedFile(path: "test/models/user_test.rb", change: .added),
    ]
    guard manyChanges else { return base }
    let extra = (0..<20).map {
      ChangedFile(path: "app/views/layouts/v\($0).html.erb", change: .modified)
    }
    return base + extra
  }

  /// The fixture parent commit's (`@-`) changed files — a small fixed set so the Parent Commit
  /// group renders a header count and list when expanded (the working-copy `changedFiles` above is
  /// the one that grows under `manyChanges`).
  static var parentChangedFiles: [ChangedFile] {
    [
      ChangedFile(path: "app/services/auth_service.rb", change: .added),
      ChangedFile(path: "app/models/account.rb", change: .modified),
      ChangedFile(path: "db/schema.rb", change: .modified),
    ]
  }

  /// A fixed timestamp for the seeded statuses' "last checked" stamps (deterministic; the value
  /// isn't displayed, only its non-nil-ness gates the loading state).
  private static let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)

  // MARK: - Diff content (issue #66)

  /// A deterministic canned diff for the diff viewer in fixture mode — so the UI tests render a real
  /// `DiffViewer` without shelling out to git/jj against the fake temp directory. The content encodes
  /// the file path and the `DiffSource` (git worktree / jj `@` / jj `@-`) so a test can assert it
  /// opened the *right* file's diff from the *right* revision. Two paths get special states for
  /// coverage: `binary.bin` → binary, `clean.txt` → empty.
  ///
  /// Ruby files get a diff whose new-side lines are exactly `rubyFileContent(for:)` (a small Ruby
  /// snippet), so the real highlight pipeline (detect → parse → map) runs against canned content and
  /// the syntax-highlight UI test can assert colour was applied. The tag line is a Ruby comment, so
  /// the existing revision-tag assertions still hold. Non-Ruby paths keep a generic diff with no
  /// matching content, so they exercise the plain (highlight-skipped) fallback.
  static func diff(for descriptor: DiffDescriptor) -> DiffResult {
    let name = (descriptor.path as NSString).lastPathComponent
    if name == "binary.bin" { return .binary }
    if name == "clean.txt" { return .empty }
    let tag = sourceTag(descriptor.source)
    if SyntaxLanguage.grammar(forPath: descriptor.path) == .ruby {
      return .diff(UnifiedDiff.parse(rubyDiffText(tag: tag, path: descriptor.path)))
    }
    let raw = """
      diff --git a/\(descriptor.path) b/\(descriptor.path)
      @@ -1,4 +1,5 @@
       context line one
      -removed old line
      +added line for \(tag)
      +marker \(descriptor.path)
       context line two
       context line three
      """
    return .diff(UnifiedDiff.parse(raw))
  }

  /// Canned new-side file content for highlighting in fixture mode (mirrors `DiffResolver
  /// .fileContent`). Ruby files return a snippet whose lines match the Ruby diff above; everything
  /// else returns `nil` so it renders plain.
  static func fileContent(for descriptor: DiffDescriptor) -> String? {
    guard SyntaxLanguage.grammar(forPath: descriptor.path) == .ruby else { return nil }
    return rubyFileContent(tag: sourceTag(descriptor.source), path: descriptor.path)
  }

  private static func sourceTag(_ source: DiffSource) -> String {
    switch source {
    case .gitWorktree: return "git-worktree"
    case .jjWorkingCopy: return "jj-working-copy"
    case .jjParent: return "jj-parent"
    }
  }

  /// The Ruby snippet that is the new-side file (no trailing newline; matches the diff's new lines).
  private static func rubyFileContent(tag: String, path: String) -> String {
    """
    class SessionsManager
      # added line for \(tag)
      # marker \(path)
      def call
        authenticate
      end
    end
    """
  }

  /// A unified diff whose new side is exactly `rubyFileContent` — line 1 + 4–7 context, lines 2–3
  /// additions (carrying the revision tag + path), plus one deletion (old side only → renders plain,
  /// proving deletions are never highlighted).
  private static func rubyDiffText(tag: String, path: String) -> String {
    """
    diff --git a/\(path) b/\(path)
    @@ -1,6 +1,7 @@
     class SessionsManager
    -  # removed \(tag)
    +  # added line for \(tag)
    +  # marker \(path)
       def call
         authenticate
       end
     end
    """
  }
}

/// The inline agent backend used under `-WorkroomUITestAgentStub`: returns a canned envelope with no
/// network, so the XCUITest exercises the real capture + banner without hitting `claude`/`codex`.
struct StubAgentRunner: AgentRunning {
  let envelope: String

  func diagnoseInline(systemPrompt: String?, prompt: String, cwd: String, timeout: TimeInterval)
    async -> AgentRunOutcome
  {
    .success(stdout: envelope)
  }
}

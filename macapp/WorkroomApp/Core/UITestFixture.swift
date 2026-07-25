import Defaults
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

  /// When set (`-WorkroomUITestNoRunCommand 1`), the fixture skips seeding ANY run command — the
  /// default probe command is otherwise always seeded (`AppStore.loadFixture`), so tests exercising
  /// the "no run command configured" state (issue #127) need this to opt out (found by review: the
  /// no-command XCUITest would otherwise always see a command configured and never see the state it
  /// means to test).
  static var noRunCommand: Bool {
    UserDefaults.standard.bool(forKey: "WorkroomUITestNoRunCommand")
  }

  /// When set (`-WorkroomUITestTwoTabs 1`), the fixture seeds a SECOND workroom and the app opens a
  /// terminal for both on launch, so the workroom tab bar (issue #23) shows two chips — the scenario
  /// the drag-to-reorder / window-drag XCUITest (`WindowDragUITests`) needs. Default (unset) keeps the
  /// single-workroom fixture the other tests rely on.
  static var twoTabs: Bool {
    UserDefaults.standard.bool(forKey: "WorkroomUITestTwoTabs")
  }

  /// When set (`-WorkroomUITestWorkroomSplit 1`), the fixture starts already in a workroom-into-
  /// workroom split of the project ROOT + the first workroom, so the split group title bar (issue
  /// #112) renders on launch WITHOUT an XCUITest drag (which is flaky). One split covers both menu
  /// branches: the workroom member gets the full menu, the root member gets none. Default (unset)
  /// keeps the single-pane fixture the other tests rely on.
  static var workroomSplit: Bool {
    UserDefaults.standard.bool(forKey: "WorkroomUITestWorkroomSplit")
  }

  /// When set (`-WorkroomUITestConflict 1`), the fixture workroom is **conflicted**: its changed-file
  /// list gains a `.conflicted` entry (`conflictedFilePath`) and the status carries the top-level
  /// `conflicted` flag. Covers the jj per-file conflict status end-to-end in the UI — the Changes row
  /// for a conflicted file must read as conflicted (its own badge, not deletion's or modification's)
  /// and the project status badge must report the conflict. Applies to both the jj and git variants,
  /// since both backends produce per-file conflicts.
  static var conflicted: Bool {
    UserDefaults.standard.bool(forKey: "WorkroomUITestConflict")
  }

  /// The path seeded as conflicted under `-WorkroomUITestConflict 1`. Distinct from every other
  /// fixture path so a test can address its row by id without matching a neighbour.
  static let conflictedFilePath = "app/models/merge_me.rb"

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

  /// A real working-tree file seeded into the fixture workroom (matches the `Gemfile` entry in
  /// `changedFiles`), so the in-app file viewer has genuine content to render (issue #117 XCUITest).
  static let seededFileName = "Gemfile"
  /// The seeded file's contents. The marker is a single contiguous token so a UITest can assert it
  /// appears in the viewer's text regardless of syntax-token splitting.
  static let seededFileContent = """
    # UITEST_FILE_MARKER
    source "https://rubygems.org"
    gem "rails"
    """
  /// The distinctive token the XCUITest looks for in the rendered file viewer.
  static let seededFileMarker = "UITEST_FILE_MARKER"

  /// A seeded **Markdown** file, so `MarkdownPreviewUITests` can drive the rendered preview
  /// (`MarkdownWebView`) rather than the `NSTextView` source path the `Gemfile` covers.
  static let seededMarkdownFileName = "NOTES.md"
  /// Deliberately mentions a raw `<title>` in prose *before* the tail marker. That is the exact shape
  /// that used to make the preview render only the head of the file: the HTML parser adopted the rest
  /// of the document as the tag's text and DOMPurify deleted it. So asserting the tail marker in the
  /// rendered web view proves both that the preview rendered at all and that it rendered *completely*.
  static let seededMarkdownContent = """
    # UITEST_MARKDOWN_HEAD

    A pane label ("Terminal <title>, pane N of M") mentioned in prose.

    ## Later section

    UITEST_MARKDOWN_TAIL
    """
  /// Tokens the XCUITest looks for: the first heading, and the tail that only survives the raw-HTML
  /// escaping. Single contiguous tokens so no syntax/word splitting can break the match.
  static let seededMarkdownHeadMarker = "UITEST_MARKDOWN_HEAD"
  static let seededMarkdownTailMarker = "UITEST_MARKDOWN_TAIL"

  /// When set (`-WorkroomUITestHoldPreviewLoader 1`), `PlainFileViewer` ignores the Markdown preview's
  /// first-render signal, so the loading state stays on screen. The real loader lives for only a few
  /// hundred milliseconds (WebContent process spawn + ~3.5 MB of bundled script), which is far too
  /// racy for an XCUITest to catch — this pins it so the loading state can be asserted deterministically
  /// instead of being left to manual QA.
  static var holdPreviewLoader: Bool {
    UserDefaults.standard.bool(forKey: "WorkroomUITestHoldPreviewLoader")
  }

  /// Which inspector section the fixture parks on
  /// (`-WorkroomUITestInspectorSection changes|history|files`). Unset (or unrecognised) = `.changes`.
  static var inspectorSection: ActivitySection {
    let raw = UserDefaults.standard.string(forKey: "WorkroomUITestInspectorSection") ?? ""
    return ActivitySection(rawValue: raw) ?? .changes
  }

  /// Force a deterministic **inspector** state in fixture mode: pane open, parked on
  /// `inspectorSection`. Must be called before any `AppStore` is built (`WorkroomApp.init`), because
  /// `activeInspectorSection` seeds itself from `Defaults` at construction.
  ///
  /// The inspector's visibility and active section are `Defaults` keys in the app's real (Dev)
  /// UserDefaults domain, so without this every test that opens something *inside* the inspector
  /// inherits whatever pane the developer last left behind — a machine sitting on History has no
  /// Changes rows, and a closed inspector has nothing at all.
  ///
  /// A launch argument can't do this job. Argument-domain values arrive as **strings**
  /// (`-showNotificationsInspector 1` stores `"1"`, not `true`), and `Defaults` reads a natively
  /// supported type with `as? Bool`, which fails on a string and hands back the key's default
  /// (`false`) — so the argument doesn't just fail to force the pane open, it *pins it shut*: the
  /// argument domain outranks the app domain, so it also shadows the persisted value AND every
  /// later write (`AppStore.apply(.iconClick)`), leaving the pane unopenable for the whole run.
  /// `UITestFixture`'s own flags survive that only because `UserDefaults.bool(forKey:)` coerces
  /// strings. Hence a fixture-namespaced argument mirrored into `Defaults` here instead.
  static func applyInspectorDefaults() {
    guard isActive else { return }
    Defaults[.showInspector] = true
    Defaults[.activeInspectorSection] = inspectorSection
  }

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
    // Seed one real working-tree file matching a `changedFiles` entry (`Gemfile`), so the in-app
    // "Open File" (issue #117) renders actual content instead of `PlainFileViewer`'s "File
    // unavailable" placeholder — `ChangesPanelUITests` asserts the marker below is on screen. Written
    // only if absent, so it stays idempotent within a launch.
    let seededGemfile = workroomDir.appendingPathComponent(seededFileName)
    if !FileManager.default.fileExists(atPath: seededGemfile.path) {
      try? seededFileContent.write(to: seededGemfile, atomically: true, encoding: .utf8)
    }
    // Rewritten every launch, not written-if-absent: this content is an assertion fixture, so a stale
    // copy left in the temp dir by an older build must not silently outlive a change to it.
    let seededMarkdown = workroomDir.appendingPathComponent(seededMarkdownFileName)
    try? seededMarkdownContent.write(to: seededMarkdown, atomically: true, encoding: .utf8)
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
      dirty: true, conflicted: conflicted, changedFiles: changedFiles, insertions: 411,
      deletions: 222, ci: .passing,
      branchForCI: "feature/login",
      lastChecked: Self.checkedAt, ciCheckedAt: Self.checkedAt, prCheckedAt: Self.checkedAt)
  }

  private static var jjWorkroomStatus: WorkroomStatus {
    WorkroomStatus(
      dirty: true,
      conflicted: conflicted,
      changedFiles: changedFiles,
      insertions: 411, deletions: 222,
      ci: .passing,
      jjWorkingCopy: JJCommitChanges(
        changeID: "pw", commitID: "7d74470b", refs: ["feature/login"],
        description: "feat: add session login (#42)", files: changedFiles),
      // The many-changes repro scenario pairs a tall Changes list with an empty Pull Request.
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
          ],
          // Mergeable + clean (issue #88) so the split "Merge" button renders in the fixture for
          // visual QA of its default/dropdown states.
          mergeable: true, mergeState: .clean),
      // All three "checked" stamps set so the inspector shows the seeded data, not "Checking…".
      lastChecked: Self.checkedAt, ciCheckedAt: Self.checkedAt, prCheckedAt: Self.checkedAt)
  }

  /// Deterministic status for the fixture **project root**: a clean git branch with passing CI — so
  /// the inspector renders the git header and the clean empty state.
  static var rootStatus: WorkroomStatus {
    WorkroomStatus(
      dirty: false, changedFiles: [], ci: .passing,
      branchForCI: "main",
      // No PR seeded here, so a `prCheckedAt` stamp makes the inspector show the "No pull request"
      // empty state (not "Checking…").
      lastChecked: Self.checkedAt, ciCheckedAt: Self.checkedAt, prCheckedAt: Self.checkedAt)
  }

  // MARK: - Notifications

  /// A deterministic notification history for the notification surfaces (the left-sidebar strip + the
  /// bell/`+N` popovers, issue #118). The fixture otherwise leaves it empty (real entries only arrive
  /// when a terminal emits an OSC notification), so this seeds a representative spread — a coalesced
  /// ×N entry, a wrapping two-line body, a title-only entry, and a body-only (titleless) one — across
  /// a range of ages so every row variant and the "time ago" line all get visual + UI-test coverage.
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
  /// the Changes section overflows the inspector for the disclosure-animation repro. Under
  /// `conflicted` it also carries one `.conflicted` entry so the conflict badge has something to
  /// render (the other kinds stay, so a test can contrast conflicted against modified/added).
  private static var changedFiles: [ChangedFile] {
    var base = [
      ChangedFile(path: "Gemfile", change: .modified),
      ChangedFile(path: seededMarkdownFileName, change: .modified),  // drives the preview UI test
      ChangedFile(path: ".env.example", change: .added),
      ChangedFile(path: "app/models/user.rb", change: .modified),
      ChangedFile(path: "app/controllers/sessions_controller.rb", change: .added),
      ChangedFile(path: "config/routes.rb", change: .modified),
      ChangedFile(path: "test/models/user_test.rb", change: .added),
    ]
    if conflicted {
      base.append(ChangedFile(path: conflictedFilePath, change: .conflicted))
    }
    guard manyChanges else { return base }
    let extra = (0..<20).map {
      ChangedFile(path: "app/views/layouts/v\($0).html.erb", change: .modified)
    }
    return base + extra
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
    case .commit(let id): return "commit-\(id)"
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

  /// The canned VCS backend for History + changeset detail in fixture mode (issue #59). The fake
  /// workroom dirs aren't real repos, so `HistoryModel` / `ChangesetDetailView` read from this instead
  /// of `VCS.provider(for:)` — the History → changeset click-through then runs hermetically.
  static let vcsProvider: VCSProviding = FixtureVCSProvider()
}

/// Deterministic `VCSProviding` for UI-test fixture mode (see `UITestFixture.vcsProvider`). Per-file
/// diffs are NOT sourced here: `DiffViewer` serves `UITestFixture.diff(for:)` directly in fixture
/// mode, so `fileDiff` is only a protocol stub.
struct FixtureVCSProvider: VCSProviding {
  /// Four newest-first commits; the first is the working copy (`@`) and carries the `main` ref, so the
  /// History rows exercise the ref chip + `@` marker.
  /// The two divergent copies of commit 2's change (`wqp`) — off the `::@` line, so they only appear
  /// when the History row's "diverges" disclosure is expanded. Each carries its own `/N` offset.
  static let divergentSiblings: [VCSCommit] = {
    let author = VCSAuthor(name: "Ada Fixture", email: "ada@example.com")
    return [
      VCSCommit(
        commitID: "fixturediv1", shortID: "fixdiv01", changeID: "wqp",
        summary: "Divergent copy A", body: "", authors: [author],
        timestamp: Date(timeIntervalSince1970: 1_699_990_000), refs: [], parentIDs: [],
        isWorkingCopy: false, changeOffset: 1, pushState: .unpushed),
      VCSCommit(
        commitID: "fixturediv2", shortID: "fixdiv02", changeID: "wqp",
        summary: "Divergent copy B", body: "", authors: [author],
        timestamp: Date(timeIntervalSince1970: 1_699_980_000), refs: [], parentIDs: [],
        isWorkingCopy: false, changeOffset: 5),
    ]
  }()

  static let commits: [VCSCommit] = {
    let author = VCSAuthor(name: "Ada Fixture", email: "ada@example.com")
    return (1...4).map { (n: Int) -> VCSCommit in
      let base: TimeInterval = 1_700_000_000
      let ts = Date(timeIntervalSince1970: base - TimeInterval(n * 3600))
      let refs: [String] = n == 1 ? ["main"] : []
      let parents: [String] = n < 4 ? ["fixturecommit\(n + 1)"] : []
      // Commit 2's change-id (`wqp`) is divergent: it resolves to more than one visible commit, so
      // its row exercises the "diverges (2)" disclosure and its expanded sibling list.
      let changeID: String? = n == 1 ? "zqxyparent" : (n == 2 ? "wqp" : nil)
      // Push state covers all three cases plus both suppression rules, so the History pane shows
      // EXACTLY ONE badge: commit 1 is `.unpushed` but is the working copy `@` (suppressed), commit 2
      // is the only badged row (and proves the badge coexists with the "diverges" toggle), commit 3 is
      // pushed, commit 4 is unknown. The divergent siblings are `.unpushed` too and must still never
      // badge once the expander is open.
      let push: VCSPushState = n <= 2 ? .unpushed : (n == 3 ? .pushed : .unknown)
      return VCSCommit(
        commitID: "fixturecommit\(n)", shortID: "fixc000\(n)",
        changeID: changeID, summary: "Fixture commit \(n)",
        body: n == 1 ? "Extended fixture description.\nA second line of detail." : "",
        authors: [author], timestamp: ts, refs: refs, parentIDs: parents, isWorkingCopy: n == 1,
        divergentSiblings: n == 2 ? divergentSiblings : [], pushState: push)
    }
  }()

  /// One origin branch, so the badge tooltips name it rather than counting.
  static let pushScope = VCSPushScope(refName: "origin/main", count: 1)

  func log(root: URL, limit: Int) throws -> VCSHistoryPage {
    let slice = Array(Self.commits.prefix(limit))
    return VCSHistoryPage(
      commits: slice, reachedEnd: slice.count >= Self.commits.count, pushScope: Self.pushScope)
  }

  func changeset(root: URL, commitID: String) async throws -> VCSChangeset {
    // Divergent siblings live off the main list; resolve them too so clicking one opens its detail.
    let all = Self.commits + Self.divergentSiblings
    let commit = all.first { $0.commitID == commitID } ?? Self.commits[0]
    let files = [
      VCSChangedFile(path: "src/session.rb", oldPath: nil, kind: .modified),
      VCSChangedFile(path: "docs/notes.txt", oldPath: nil, kind: .added),
      // A moved file, so the `old → new` path line has something to render.
      VCSChangedFile(path: "lib/moved.rb", oldPath: "src/moved.rb", kind: .renamed),
    ]
    return VCSChangeset(
      commit: commit, fullMessage: commit.summary + "\n\nFixture commit body.", files: files,
      isMerge: false, insertions: 24, deletions: 8, pushScope: Self.pushScope)
  }

  func fileDiff(root: URL, commitID: String, path: String) async throws -> String {
    "diff --git a/\(path) b/\(path)\n@@ -1 +1 @@\n-old\n+new\n"
  }

  func workingFileDiff(root: URL, path: String, base: VCSWorkingDiffBase) async throws -> String {
    "diff --git a/\(path) b/\(path)\n@@ -1 +1 @@\n-old\n+new\n"
  }

  // Highlighting content is served by `UITestFixture.fileContent` in fixture mode, not the provider.
  func fileContent(root: URL, rev: String, path: String) async throws -> String? { nil }
  func commitParentFileContent(root: URL, commitID: String, path: String) async throws -> String? {
    nil
  }
  func workingBaseFileContent(root: URL, base: VCSWorkingDiffBase, path: String) async throws
    -> String?
  { nil }

  func currentRef(root: URL) async throws -> VCSRef {
    VCSRef(name: "main", kind: .branch)
  }
}

/// The inline agent backend used under `-WorkroomUITestAgentStub`: returns a canned envelope with no
/// network, so the XCUITest exercises the real capture + banner without hitting `claude`/`codex`.
struct StubAgentRunner: AgentRunning {
  let envelope: String

  func diagnoseInline(
    systemPrompt: String?, model: String?, prompt: String, cwd: String, timeout: TimeInterval
  ) async -> AgentRunOutcome {
    .success(stdout: envelope)
  }
}

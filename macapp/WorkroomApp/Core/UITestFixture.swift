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

  /// Stable display name of the fixture project (also its sidebar accessibility id suffix:
  /// `sidebar.project.<name>`). Deliberately obvious so it never reads as a real project in logs.
  static let projectName = "UITestProject"
  /// Stable name of the fixture workroom (`sidebar.workroom.<name>`).
  static let workroomName = "uitest-room"

  /// The fake project list. Idempotent within a launch: the backing temp directories are created if
  /// missing so each target's terminal can start a shell. The project is reported as `git` so the
  /// sidebar's root row renders normally; no real VCS call is ever made (loading is short-circuited
  /// in `AppStore`, which also skips branch resolution for these paths).
  static func projects() -> [Project] {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("workroom-uitest", isDirectory: true)
    let projectDir = base.appendingPathComponent(projectName, isDirectory: true)
    let workroomDir = base.appendingPathComponent("workrooms", isDirectory: true)
      .appendingPathComponent(workroomName, isDirectory: true)
    for dir in [projectDir, workroomDir] {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return [
      Project(
        path: projectDir.path,
        vcs: "git",
        workrooms: [
          Workroom(name: workroomName, path: workroomDir.path, vcsName: "git", warnings: [])
        ])
    ]
  }

  // MARK: - Changes-inspector status

  /// Deterministic VCS status for the fixture **workroom** (`uitest-room`): a dirty jj change with a
  /// description, bookmark, and a mix of root-level and nested changed files. Lets the Changes
  /// inspector render its jj-log header and the filename / dimmed-directory file list with no real
  /// repo — visual QA never has to touch (or expose) the developer's actual projects.
  static var workroomStatus: WorkroomStatus {
    WorkroomStatus(
      dirty: true,
      changedFiles: [
        ChangedFile(path: "Gemfile", change: .modified),
        ChangedFile(path: ".env.example", change: .added),
        ChangedFile(path: "app/models/user.rb", change: .modified),
        ChangedFile(path: "app/controllers/sessions_controller.rb", change: .added),
        ChangedFile(path: "config/routes.rb", change: .modified),
        ChangedFile(path: "test/models/user_test.rb", change: .added),
      ],
      ci: .passing,
      jjRefs: ["feature/login"],
      jjDescription: "feat: add session login (#42)",
      jjChangeID: "pw", jjCommitID: "7d74470b",
      pr: PullRequestInfo(
        number: 42, title: "Add session login", state: .open, isDraft: false,
        url: "https://github.com/acme/app/pull/42", reviewDecision: .approved),
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

  /// A fixed timestamp for the seeded statuses' "last checked" stamps (deterministic; the value
  /// isn't displayed, only its non-nil-ness gates the loading state).
  private static let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
}

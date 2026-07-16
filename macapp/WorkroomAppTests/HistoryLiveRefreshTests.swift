import Defaults
import XCTest

@testable import Workroom

/// Live History refresh (issue #59 follow-up): a commit / bookmark / ref move in a project's VCS
/// metadata dir trips the per-project watcher → `handleRootBranchChange`, which now repaints the
/// History log **when the inspector is visible, on History, and its target belongs to that project** —
/// independent of whether the branch label changed (a plain commit usually leaves it unchanged). Also
/// covers the app-refocus safety net `refreshHistoryIfActive`.
///
/// The commit log itself is driven through an injected `HistoryModel` backed by a counting provider,
/// so "did a refresh fire?" is observable as a `log` call count — no real repo needed for the gating
/// logic. `runBlocking` reads run off-main, so each assertion awaits `commitHistory.awaitCurrentLoad`.
@MainActor
final class HistoryLiveRefreshTests: XCTestCase {
  private var savedShow: Any?
  private var savedSection: Any?
  private let showKey = "showNotificationsInspector"
  private let sectionKey = "activeInspectorSection"

  override func setUp() {
    super.setUp()
    savedShow = UserDefaults.standard.object(forKey: showKey)
    savedSection = UserDefaults.standard.object(forKey: sectionKey)
  }

  override func tearDown() {
    restore(showKey, savedShow)
    restore(sectionKey, savedSection)
    super.tearDown()
  }

  private func restore(_ key: String, _ value: Any?) {
    if let value {
      UserDefaults.standard.set(value, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }

  // MARK: harness

  /// Counts `log` calls (the observable "a load fired" signal). Lock-guarded + `@unchecked Sendable`
  /// because `log` runs off-main via `runBlocking`; tests serialize with `awaitCurrentLoad`.
  private final class CountingProvider: VCSProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var logCount: Int { lock.withLock { _count } }
    func log(root: URL, limit: Int) throws -> VCSHistoryPage {
      lock.withLock { _count += 1 }
      return VCSHistoryPage(commits: [], reachedEnd: true)
    }
    func changeset(root: URL, commitID: String) async throws -> VCSChangeset {
      throw VCSError.io("x")
    }
    func fileDiff(root: URL, commitID: String, path: String) async throws -> String {
      throw VCSError.io("x")
    }
    func workingFileDiff(root: URL, path: String, base: VCSWorkingDiffBase) async throws -> String {
      throw VCSError.io("x")
    }
    func fileContent(root: URL, rev: String, path: String) async throws -> String? { nil }
    func currentRef(root: URL) async throws -> VCSRef { .none }
  }

  private func project(_ path: String, workrooms: [String]) -> Project {
    Project(
      path: path, vcs: "git",
      workrooms: workrooms.map {
        Workroom(name: $0, path: "\(path)/\($0)", vcsName: "workroom/\($0)", warnings: [])
      })
  }

  private func wr(_ name: String, in path: String) -> SidebarID {
    .workroom(project: path, name: name)
  }

  /// A store with a counting `commitHistory`, one workroom-with-a-tab selected, the inspector visible
  /// and on History (so `inspectorTargetID` is non-nil and the model is focused → `root != nil`, the
  /// precondition for `refresh` to actually load). Returns the store + the counting provider.
  private func activeHistoryStore(
    projects: [Project], select path: String, workroom name: String
  ) async -> (AppStore, CountingProvider) {
    let provider = CountingProvider()
    let store = AppStore(commitHistory: HistoryModel(resolve: { _ in provider }))
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.projects = projects
    Defaults[.showInspector] = true
    store.activeInspectorSection = .history
    // Give the selection a tab so `selectionHasTabs` (and thus `inspectorTargetID`) is non-nil.
    store.terminals.addTab(for: store.target(for: wr(name, in: path))!)
    // Selecting fires the didSet that focuses `commitHistory` (section == .history) → the first load.
    store.selectedTargetID = wr(name, in: path)
    await store.commitHistory.awaitCurrentLoad()
    return (store, provider)
  }

  // MARK: live watcher path

  func testMetadataChangeRefreshesHistoryEvenWhenLabelUnchanged() async {
    let (store, provider) = await activeHistoryStore(
      projects: [project("/a", workrooms: ["solo"])], select: "/a", workroom: "solo")
    XCTAssertEqual(store.inspectorTargetID, wr("solo", in: "/a"))
    let before = provider.logCount

    store.handleRootBranchChange(projectID: store.projects[0].id)
    await store.commitHistory.awaitCurrentLoad()

    XCTAssertEqual(
      provider.logCount, before + 1,
      "a metadata change for the shown workroom's project must refresh History, even though a normal "
        + "commit leaves the branch label unchanged (the placement-before-the-label-return guard)")
  }

  func testMetadataChangeInOtherProjectDoesNotRefresh() async {
    let (store, provider) = await activeHistoryStore(
      projects: [project("/a", workrooms: ["solo"]), project("/b", workrooms: ["other"])],
      select: "/a", workroom: "solo")
    let before = provider.logCount
    let otherProject = store.projects.first { $0.path == "/b" }!

    store.handleRootBranchChange(projectID: otherProject.id)
    await store.commitHistory.awaitCurrentLoad()

    XCTAssertEqual(
      provider.logCount, before, "a change in a DIFFERENT project must not refresh this History")
  }

  func testMetadataChangeWhileInspectorHiddenDoesNotRefresh() async {
    let (store, provider) = await activeHistoryStore(
      projects: [project("/a", workrooms: ["solo"])], select: "/a", workroom: "solo")
    Defaults[.showInspector] = false  // section is still .history, but the pane is hidden
    let before = provider.logCount

    store.handleRootBranchChange(projectID: store.projects[0].id)
    await store.commitHistory.awaitCurrentLoad()

    XCTAssertEqual(
      provider.logCount, before, "a hidden inspector must not run background History reads")
  }

  func testMetadataChangeWhileNotOnHistoryDoesNotRefresh() async {
    let (store, provider) = await activeHistoryStore(
      projects: [project("/a", workrooms: ["solo"])], select: "/a", workroom: "solo")
    store.activeInspectorSection = .changes  // switched off History
    let before = provider.logCount

    store.handleRootBranchChange(projectID: store.projects[0].id)
    await store.commitHistory.awaitCurrentLoad()

    XCTAssertEqual(provider.logCount, before, "off-History must not refresh the log")
  }

  // MARK: app-refocus safety net

  func testRefreshHistoryIfActiveRefreshesOnlyWhenVisibleAndHistory() async {
    let (store, provider) = await activeHistoryStore(
      projects: [project("/a", workrooms: ["solo"])], select: "/a", workroom: "solo")

    let before = provider.logCount
    store.refreshHistoryIfActive()  // visible + History → refreshes
    await store.commitHistory.awaitCurrentLoad()
    XCTAssertEqual(provider.logCount, before + 1)

    Defaults[.showInspector] = false
    store.refreshHistoryIfActive()  // hidden → no-op
    await store.commitHistory.awaitCurrentLoad()
    XCTAssertEqual(
      provider.logCount, before + 1, "hidden inspector → refreshHistoryIfActive no-ops")
  }
}

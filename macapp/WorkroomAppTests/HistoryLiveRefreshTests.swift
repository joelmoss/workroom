import XCTest

@testable import Workroom

/// Live History refresh (issue #59 follow-up): a commit / bookmark / ref move in a project's VCS
/// metadata dir trips the per-project watcher → `handleRootBranchChange`, which now repaints the
/// History log **when the inspector is visible, showing History, and its target is in that project** —
/// independent of whether the branch label changed (a plain commit usually leaves it unchanged). Also
/// covers the app-refocus safety net `refreshHistoryIfActive`.
///
/// The commit log itself is driven through an injected `HistoryModel` backed by a counting provider,
/// so "did a refresh fire?" is observable as a `log` call count — no real repo needed for the gating
/// logic. `runBlocking` reads run off-main, so each assertion awaits `commitHistory.awaitCurrentLoad`.
///
/// All three halves of the gate are pinned **per store** — `inspectorVisibleOverrideForTesting`,
/// `isolatesInspectorSectionForTesting` and `isolatesInspectorLayoutForTesting` (the collapse flag,
/// added when History joined the Changes stack) — never by writing the shared inspector settings: the parallel
/// workers share one UserDefaults domain, so this class used to leave its `showInspector` /
/// `inspector.activeSection` values inside whatever unrelated class ran beside it. (The old
/// save/restore here couldn't have helped even in serial: it restored `"activeInspectorSection"`,
/// which is not the key — the real one is `"inspector.activeSection"`.)
@MainActor
final class HistoryLiveRefreshTests: XCTestCase {

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
  /// and showing History (so `inspectorTargetID` is non-nil and the model is focused → `root != nil`,
  /// the precondition for `refresh` to actually load). History is a sub-section of the **Changes**
  /// pane, so "showing" is that pane being active AND the section expanded — the collapse flag is
  /// pinned here rather than trusted, because it hydrates from the shared `inspectorLayout` pref that
  /// any other class (or worker) may have left collapsed. Returns the store + the counting provider.
  private func activeHistoryStore(
    projects: [Project], select path: String, workroom name: String
  ) async -> (AppStore, CountingProvider) {
    let provider = CountingProvider()
    let store = AppStore(commitHistory: HistoryModel(resolve: { _ in provider }))
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.projects = projects
    store.inspectorVisibleOverrideForTesting = true
    store.isolatesInspectorSectionForTesting = true
    store.isolatesInspectorLayoutForTesting = true
    store.activeInspectorSection = .changes
    store.historySectionCollapsed = false
    // Give the selection a tab so `selectionHasTabs` (and thus `inspectorTargetID`) is non-nil.
    store.terminals.addTab(for: store.target(for: wr(name, in: path))!)
    // Selecting fires the didSet that focuses `commitHistory` (History showing) → the first load.
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
    store.inspectorVisibleOverrideForTesting = false  // still on .history, but the pane is hidden
    let before = provider.logCount

    store.handleRootBranchChange(projectID: store.projects[0].id)
    await store.commitHistory.awaitCurrentLoad()

    XCTAssertEqual(
      provider.logCount, before, "a hidden inspector must not run background History reads")
  }

  /// Off-History has two shapes now that History is a section of the Changes stack: a pane that
  /// doesn't stack it at all (Files), and its own collapsed disclosure. Neither may read VCS.
  func testMetadataChangeWhileNotShowingHistoryDoesNotRefresh() async {
    let (store, provider) = await activeHistoryStore(
      projects: [project("/a", workrooms: ["solo"])], select: "/a", workroom: "solo")
    store.activeInspectorSection = .files  // a pane that doesn't stack History
    let before = provider.logCount

    store.handleRootBranchChange(projectID: store.projects[0].id)
    await store.commitHistory.awaitCurrentLoad()

    XCTAssertEqual(provider.logCount, before, "a pane without History must not refresh the log")

    store.activeInspectorSection = .changes  // back on the pane, but collapse the section
    store.historySectionCollapsed = true
    await store.commitHistory.awaitCurrentLoad()
    let beforeCollapsed = provider.logCount

    store.handleRootBranchChange(projectID: store.projects[0].id)
    await store.commitHistory.awaitCurrentLoad()

    XCTAssertEqual(
      provider.logCount, beforeCollapsed, "a collapsed History section must not refresh the log")
  }

  // MARK: re-expanding the section

  /// Why `historySectionCollapsed`'s `didSet` eagerly focuses: while the section is collapsed the
  /// selection didSet skips its focus (correctly — no VCS reads for a hidden log), so the model is
  /// left pointing at the workroom the user was on BEFORE the switch. Without the eager focus,
  /// re-expanding would show that stale workroom's commits until `HistoryPanel`'s `.task` caught up.
  ///
  /// The collapse-then-re-expand-on-the-SAME-workroom case is deliberately not asserted here: `focus`
  /// no-ops on an unchanged root, so it would pass with the `didSet` deleted. The root has to move
  /// while the section is shut for the assertion to mean anything.
  func testReExpandingHistoryAfterAWorkroomSwitchRepointsTheModel() async {
    let (store, provider) = await activeHistoryStore(
      projects: [project("/a", workrooms: ["solo", "other"])], select: "/a", workroom: "solo")
    XCTAssertEqual(store.commitHistory.root, URL(fileURLWithPath: "/a/solo"))

    store.historySectionCollapsed = true
    let other = wr("other", in: "/a")
    store.terminals.addTab(for: store.target(for: other)!)
    store.selectedTargetID = other
    await store.commitHistory.awaitCurrentLoad()
    XCTAssertEqual(
      store.commitHistory.root, URL(fileURLWithPath: "/a/solo"),
      "a collapsed section must not read the newly selected workroom's log")
    let before = provider.logCount

    store.historySectionCollapsed = false
    await store.commitHistory.awaitCurrentLoad()

    XCTAssertEqual(
      store.commitHistory.root, URL(fileURLWithPath: "/a/other"),
      "re-expanding must re-point the model at the workroom selected meanwhile")
    XCTAssertEqual(provider.logCount, before + 1, "…and load it, rather than show stale commits")
  }

  // MARK: app-refocus safety net

  func testRefreshHistoryIfActiveRefreshesOnlyWhenVisibleAndHistory() async {
    let (store, provider) = await activeHistoryStore(
      projects: [project("/a", workrooms: ["solo"])], select: "/a", workroom: "solo")

    let before = provider.logCount
    store.refreshHistoryIfActive()  // visible + History → refreshes
    await store.commitHistory.awaitCurrentLoad()
    XCTAssertEqual(provider.logCount, before + 1)

    store.inspectorVisibleOverrideForTesting = false
    store.refreshHistoryIfActive()  // hidden → no-op
    await store.commitHistory.awaitCurrentLoad()
    XCTAssertEqual(
      provider.logCount, before + 1, "hidden inspector → refreshHistoryIfActive no-ops")
  }
}
